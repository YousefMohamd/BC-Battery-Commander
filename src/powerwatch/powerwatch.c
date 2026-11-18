// PowerWatch v4 - IOKit sleep/wake notifier for Battery Commander
// Replaces the battopt powerwatch (v3). Runs as a USER LaunchAgent
// (com.batterycommander.powerwatch) - it needs no privilege.
// - No hardcoded user/home paths: derived from the executable path,
//   falling back to $HOME, then getpwuid(). No "/Users/Yousef".
// - WillSleep: arm_sleep + pre_sleep run in a child with a BOUNDED wait
//   (10 s max). System sleep is never blocked indefinitely on a hung script.
// - HasPoweredOn: writes $DASH/.last_wake (epoch seconds, atomic) so the
//   watchdog's post-wake delay has a real wake timestamp, then runs
//   post_wake_restore.
// - No battopt, no sudo, no SMC writes. Read-only IOKit notifications only.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <syslog.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <time.h>
#include <errno.h>

// Bounded wait for the WillSleep scripts: never block sleep longer than this.
#define SLEEP_SCRIPT_TIMEOUT_SEC 10
// Grace period after SIGTERM before SIGKILL on a hung sleep-script child.
#define SLEEP_SCRIPT_KILL_GRACE_SEC 1

static char script_dir[PATH_MAX];
static char home_dir[PATH_MAX];
static char arm_sleep[PATH_MAX];
static char pre_sleep[PATH_MAX];
static char post_wake[PATH_MAX];
static char last_wake_path[PATH_MAX];
static char shutdown_path[PATH_MAX];
static char env_home[PATH_MAX + 8];
static char env_path[] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin";

// Home directory, with no hardcoded user: $HOME, else passwd entry.
static void resolve_home(void) {
    const char *h = getenv("HOME");
    if (h != NULL && h[0] != '\0') {
        strncpy(home_dir, h, sizeof(home_dir) - 1);
        home_dir[sizeof(home_dir) - 1] = '\0';
        return;
    }
    struct passwd *pw = getpwuid(getuid());
    if (pw != NULL && pw->pw_dir != NULL && pw->pw_dir[0] != '\0') {
        strncpy(home_dir, pw->pw_dir, sizeof(home_dir) - 1);
        home_dir[sizeof(home_dir) - 1] = '\0';
        return;
    }
    // Last resort: the state dir cannot be located; use /tmp so nothing
    // is written to a wrong user's home. The scripts will not be found
    // and each run logs an error instead of acting on the wrong paths.
    strncpy(home_dir, "/tmp", sizeof(home_dir) - 1);
    home_dir[sizeof(home_dir) - 1] = '\0';
    syslog(LOG_ERR, "powerwatch: no HOME and no passwd entry - using /tmp fallback");
}

static void resolve_paths(void) {
    char exe[PATH_MAX];
    char resolved[PATH_MAX];
    char tmp[PATH_MAX];
    uint32_t sz = sizeof(exe);
    const char *d;

    resolve_home();

    // Default: the state dir under $HOME (new name first, old as
    // fallback until the W6.3 migration runs). Overridden below
    // when the executable path resolves (the binary lives in the
    // state dir).
    snprintf(script_dir, sizeof(script_dir), "%s/.battery-commander", home_dir);
    if (access(script_dir, F_OK) != 0) {
        snprintf(script_dir, sizeof(script_dir), "%s/.battopt-swiftbar", home_dir);
    }

    if (_NSGetExecutablePath(exe, &sz) == 0) {
        if (realpath(exe, resolved) == NULL) {
            strncpy(resolved, exe, sizeof(resolved) - 1);
            resolved[sizeof(resolved) - 1] = '\0';
        }
        d = dirname(resolved);
        strncpy(script_dir, d, sizeof(script_dir) - 1);
        script_dir[sizeof(script_dir) - 1] = '\0';
        // home is the parent of the state dir (exe is $HOME/.battery-commander/powerwatch
        // or the legacy $HOME/.battopt-swiftbar/powerwatch)
        strncpy(tmp, script_dir, sizeof(tmp) - 1);
        tmp[sizeof(tmp) - 1] = '\0';
        d = dirname(tmp);
        strncpy(home_dir, d, sizeof(home_dir) - 1);
        home_dir[sizeof(home_dir) - 1] = '\0';
    } else {
        syslog(LOG_ERR, "powerwatch: _NSGetExecutablePath failed - using %s", script_dir);
    }

    snprintf(arm_sleep, sizeof(arm_sleep), "%s/arm_sleep.sh", script_dir);
    snprintf(pre_sleep, sizeof(pre_sleep), "%s/pre_sleep_cleanup.sh", script_dir);
    snprintf(post_wake, sizeof(post_wake), "%s/post_wake_restore.sh", script_dir);
    snprintf(last_wake_path, sizeof(last_wake_path), "%s/.last_wake", script_dir);
    snprintf(shutdown_path, sizeof(shutdown_path), "%s/.user_shutdown", script_dir);
    snprintf(env_home, sizeof(env_home), "HOME=%s", home_dir);
}

// Write the wake timestamp (epoch seconds) atomically: tmp file + rename.
// The watchdog reads $DASH/.last_wake for its post-wake delay.
static void write_last_wake(void) {
    char tmp_path[PATH_MAX + 8];
    char buf[32];
    FILE *f;

    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", last_wake_path);
    f = fopen(tmp_path, "w");
    if (f == NULL) {
        syslog(LOG_ERR, "powerwatch: cannot write %s: %s", tmp_path, strerror(errno));
        return;
    }
    snprintf(buf, sizeof(buf), "%lld\n", (long long)time(NULL));
    if (fputs(buf, f) == EOF) {
        syslog(LOG_ERR, "powerwatch: cannot write %s: %s", tmp_path, strerror(errno));
        fclose(f);
        unlink(tmp_path);
        return;
    }
    if (fclose(f) != 0) {
        syslog(LOG_ERR, "powerwatch: cannot close %s: %s", tmp_path, strerror(errno));
        unlink(tmp_path);
        return;
    }
    if (rename(tmp_path, last_wake_path) != 0) {
        syslog(LOG_ERR, "powerwatch: cannot rename %s -> %s: %s",
               tmp_path, last_wake_path, strerror(errno));
        unlink(tmp_path);
        return;
    }
    syslog(LOG_INFO, "powerwatch: wrote .last_wake");
}

// Reap fire-and-forget children; log non-zero exits.
static void sigchld_handler(int sig) {
    int status;
    pid_t pid;
    (void)sig;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
            syslog(LOG_WARNING, "powerwatch: child %d exited %d",
                   (int)pid, WEXITSTATUS(status));
        } else if (WIFSIGNALED(status)) {
            syslog(LOG_WARNING, "powerwatch: child %d killed by signal %d",
                   (int)pid, WTERMSIG(status));
        }
    }
}

static void run_script(const char *path) {
    if (access(path, X_OK) != 0) {
        syslog(LOG_ERR, "powerwatch: script not executable: %s", path);
        return;
    }
    syslog(LOG_INFO, "powerwatch: run %s", path);

    pid_t pid = fork();
    if (pid == 0) {
        char *envp[] = { env_home, env_path, NULL };
        execle("/bin/bash", "bash", path, (char *)NULL, envp);
        _exit(127);
    } else if (pid < 0) {
        syslog(LOG_ERR, "powerwatch: fork failed for %s: %s", path, strerror(errno));
    }
}

// Run one script synchronously with a timeout (seconds). Returns the
// script's exit status, or -1 on fork/timeout/kill error.
static int run_script_timeout(const char *path, int timeout_sec) {
    pid_t pid;
    int status = 0;
    int waited_ms = 0;

    if (access(path, X_OK) != 0) {
        syslog(LOG_ERR, "powerwatch: script not executable: %s", path);
        return -1;
    }

    pid = fork();
    if (pid == 0) {
        char *envp[] = { env_home, env_path, NULL };
        execle("/bin/bash", "bash", path, (char *)NULL, envp);
        _exit(127);
    }
    if (pid < 0) {
        syslog(LOG_ERR, "powerwatch: fork failed for %s: %s", path, strerror(errno));
        return -1;
    }

    // Bounded wait: poll every 100 ms. SIGCHLD is blocked by the caller
    // around this call so the handler cannot reap this child first.
    while (waited_ms < timeout_sec * 1000) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
            return -1;
        }
        if (r < 0 && errno != EINTR) {
            syslog(LOG_ERR, "powerwatch: waitpid failed for %s: %s", path, strerror(errno));
            return -1;
        }
        usleep(100 * 1000);
        waited_ms += 100;
    }

    // Timeout: terminate, grace, then kill. Never block sleep indefinitely.
    syslog(LOG_ERR, "powerwatch: %s timed out after %ds - terminating", path, timeout_sec);
    kill(pid, SIGTERM);
    {
        int grace_ms = 0;
        while (grace_ms < SLEEP_SCRIPT_KILL_GRACE_SEC * 1000) {
            pid_t r = waitpid(pid, &status, WNOHANG);
            if (r == pid) return 124; // timeout, terminated
            if (r < 0 && errno != EINTR) break;
            usleep(100 * 1000);
            grace_ms += 100;
        }
    }
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    return 124;
}

// WillSleep: arm_sleep then pre_sleep, sequentially, with a bounded total
// wait. The child runs both scripts; the parent waits at most
// SLEEP_SCRIPT_TIMEOUT_SEC for it, then allows sleep regardless.
static void run_sleep_scripts_bounded(void) {
    sigset_t block, old;
    pid_t pid;
    int status = 0;
    int waited_ms = 0;

    sigemptyset(&block);
    sigaddset(&block, SIGCHLD);
    if (sigprocmask(SIG_BLOCK, &block, &old) != 0) {
        syslog(LOG_ERR, "powerwatch: sigprocmask failed: %s", strerror(errno));
    }

    pid = fork();
    if (pid == 0) {
        // Child: run both scripts sequentially, then exit with the
        // worst status. SIGCHLD stays blocked here too; waitpid on our
        // own children still works (only the handler is deferred).
        int rc1 = run_script_timeout(arm_sleep, SLEEP_SCRIPT_TIMEOUT_SEC);
        int rc2 = 0;
        if (rc1 >= 0 && rc1 != 124) {
            rc2 = run_script_timeout(pre_sleep, SLEEP_SCRIPT_TIMEOUT_SEC);
        } else if (rc1 == 124) {
            syslog(LOG_ERR, "powerwatch: arm_sleep timed out - skipping pre_sleep");
        }
        _exit(rc1 != 0 ? (rc1 < 0 ? 1 : rc1) : (rc2 != 0 ? (rc2 < 0 ? 1 : rc2) : 0));
    }
    if (pid < 0) {
        syslog(LOG_ERR, "powerwatch: fork failed for sleep scripts: %s", strerror(errno));
        sigprocmask(SIG_SETMASK, &old, NULL);
        return;
    }

    while (waited_ms < SLEEP_SCRIPT_TIMEOUT_SEC * 1000) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
                syslog(LOG_WARNING, "powerwatch: sleep scripts exited %d",
                       WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                syslog(LOG_WARNING, "powerwatch: sleep scripts killed by signal %d",
                       WTERMSIG(status));
            } else {
                syslog(LOG_INFO, "powerwatch: sleep scripts done");
            }
            sigprocmask(SIG_SETMASK, &old, NULL);
            return;
        }
        if (r < 0 && errno != EINTR) {
            syslog(LOG_ERR, "powerwatch: waitpid failed: %s", strerror(errno));
            break;
        }
        usleep(100 * 1000);
        waited_ms += 100;
    }

    syslog(LOG_ERR, "powerwatch: sleep scripts timed out after %ds - allowing sleep anyway",
           SLEEP_SCRIPT_TIMEOUT_SEC);
    kill(pid, SIGTERM);
    {
        int grace_ms = 0;
        while (grace_ms < SLEEP_SCRIPT_KILL_GRACE_SEC * 1000) {
            pid_t r = waitpid(pid, &status, WNOHANG);
            if (r == pid) break;
            if (r < 0 && errno != EINTR) break;
            usleep(100 * 1000);
            grace_ms += 100;
        }
    }
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    sigprocmask(SIG_SETMASK, &old, NULL);
}

static io_connect_t root_port = 0;
static IONotificationPortRef notifyPort = NULL;
static io_object_t notifier = 0;

static void powerCallback(void *refCon, io_service_t service,
                          natural_t messageType, void *messageArgument) {
    (void)refCon; (void)service;

    switch (messageType) {
        case kIOMessageSystemWillSleep:
            syslog(LOG_INFO, "powerwatch: system will sleep - arming");
            if (access(shutdown_path, F_OK) == 0) {
                IOAllowPowerChange(root_port, (long)messageArgument);
                break;
            }
            run_sleep_scripts_bounded();
            syslog(LOG_INFO, "powerwatch: allowing sleep");
            IOAllowPowerChange(root_port, (long)messageArgument);
            break;

        case kIOMessageCanSystemSleep:
            syslog(LOG_INFO, "powerwatch: can system sleep");
            IOAllowPowerChange(root_port, (long)messageArgument);
            break;

        case kIOMessageSystemHasPoweredOn:
            syslog(LOG_INFO, "powerwatch: system woke up");
            write_last_wake();
            run_script(post_wake);
            break;

        default:
            break;
    }
}

int main(int argc, const char *argv[]) {
    struct sigaction sa;
    (void)argc; (void)argv;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigchld_handler;
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGCHLD, &sa, NULL) != 0) {
        syslog(LOG_ERR, "powerwatch: sigaction failed: %s", strerror(errno));
        return 1;
    }

    openlog("powerwatch", LOG_PID | LOG_CONS, LOG_DAEMON);

    resolve_paths();

    root_port = IORegisterForSystemPower(NULL, &notifyPort, powerCallback, &notifier);
    if (root_port == 0) {
        syslog(LOG_ERR, "powerwatch: IORegisterForSystemPower failed");
        return 1;
    }

    CFRunLoopSourceRef rls = IONotificationPortGetRunLoopSource(notifyPort);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);

    syslog(LOG_INFO, "powerwatch: started (pid %d)", getpid());
    syslog(LOG_INFO, "powerwatch: script dir=%s", script_dir);
    syslog(LOG_INFO, "powerwatch: home dir=%s", home_dir);

    fprintf(stdout, "PowerWatch v4 started (dir=%s)\n", script_dir);
    fflush(stdout);

    CFRunLoopRun();

    IODeregisterForSystemPower(&notifier);
    IOServiceClose(root_port);
    IONotificationPortDestroy(notifyPort);
    closelog();
    return 0;
}
