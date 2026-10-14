// PowerWatch v3 - IOKit sleep/wake notifier for BattOpt
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
#include <syslog.h>
#include <signal.h>

#define SHUTDOWN_FILE "/Users/Yousef/.battopt-swiftbar/.user_shutdown"
#define DEFAULT_SCRIPT_DIR "/Users/Yousef/.battopt-swiftbar"
#define DEFAULT_HOME_DIR   "/Users/Yousef"

static char script_dir[PATH_MAX] = DEFAULT_SCRIPT_DIR;
static char home_dir[PATH_MAX]   = DEFAULT_HOME_DIR;
static char arm_sleep[PATH_MAX];
static char pre_sleep[PATH_MAX];
static char post_wake[PATH_MAX];
static char env_home[PATH_MAX + 8];
static char env_path[] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin";

static io_connect_t root_port = 0;
static IONotificationPortRef notifyPort = NULL;
static io_object_t notifier = 0;

static void resolve_paths(void) {
    char exe[PATH_MAX];
    char resolved[PATH_MAX];
    char tmp[PATH_MAX];
    uint32_t sz = sizeof(exe);
    const char *d;

    if (_NSGetExecutablePath(exe, &sz) == 0) {
        if (realpath(exe, resolved) == NULL) {
            strncpy(resolved, exe, sizeof(resolved) - 1);
            resolved[sizeof(resolved) - 1] = '\0';
        }
        d = dirname(resolved);
        strncpy(script_dir, d, sizeof(script_dir) - 1);
        script_dir[sizeof(script_dir) - 1] = '\0';
        strncpy(tmp, script_dir, sizeof(tmp) - 1);
        tmp[sizeof(tmp) - 1] = '\0';
        d = dirname(tmp);
        strncpy(home_dir, d, sizeof(home_dir) - 1);
        home_dir[sizeof(home_dir) - 1] = '\0';
    } else {
        syslog(LOG_ERR, "powerwatch: _NSGetExecutablePath failed - using default %s", script_dir);
    }

    snprintf(arm_sleep, sizeof(arm_sleep), "%s/arm_sleep.sh", script_dir);
    snprintf(pre_sleep, sizeof(pre_sleep), "%s/pre_sleep_cleanup.sh", script_dir);
    snprintf(post_wake, sizeof(post_wake), "%s/post_wake_restore.sh", script_dir);
    snprintf(env_home, sizeof(env_home), "HOME=%s", home_dir);
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
    }
}

static void powerCallback(void *refCon, io_service_t service,
                          natural_t messageType, void *messageArgument) {
    (void)refCon; (void)service;

    switch (messageType) {
        case kIOMessageSystemWillSleep:
            syslog(LOG_INFO, "powerwatch: system will sleep - arming");
                        if (access(SHUTDOWN_FILE, F_OK) == 0) { IOAllowPowerChange(root_port, (long)messageArgument); break; }
run_script(arm_sleep);
            sleep(4);
            run_script(pre_sleep);
            sleep(3);
            syslog(LOG_INFO, "powerwatch: allowing sleep");
            IOAllowPowerChange(root_port, (long)messageArgument);
            break;

        case kIOMessageCanSystemSleep:
            syslog(LOG_INFO, "powerwatch: can system sleep");
            IOAllowPowerChange(root_port, (long)messageArgument);
            break;

        case kIOMessageSystemHasPoweredOn:
            syslog(LOG_INFO, "powerwatch: system woke up");
            run_script(post_wake);
            break;

        default:
            break;
    }
}

int main(int argc, const char *argv[]) {
    signal(SIGCHLD, SIG_IGN);
    (void)argc; (void)argv;
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

    fprintf(stdout, "PowerWatch v3 started (dir=%s)\n", script_dir);
    fflush(stdout);

    CFRunLoopRun();

    IODeregisterForSystemPower(&notifier);
    IOServiceClose(root_port);
    IONotificationPortDestroy(notifyPort);
    closelog();
    return 0;
}
