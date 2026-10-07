#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>

int main(void) {
    const char *home = getenv("HOME");
    if (!home) home = "/Users/unknown";
    char disabled_path[512];
    snprintf(disabled_path, sizeof(disabled_path),
             "%s/.battopt-swiftbar/.disabled", home);

    int was_disabled = (access(disabled_path, F_OK) == 0);

    // 1. Send notification IMMEDIATELY (non-blocking)
    char notif[1024];
    if (was_disabled) {
        snprintf(notif, sizeof(notif),
            "/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier "
            "-title BattOpt -message 'Restoring Control Center...' "
            "-appIcon \"%s/.battopt-swiftbar/icons/battopt.png\" "
            "-sound Ping -group battopt >/dev/null 2>&1 &",
            home);
    } else {
        snprintf(notif, sizeof(notif),
            "/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier "
            "-title BattOpt -message 'Control Center is running' "
            "-appIcon \"%s/.battopt-swiftbar/icons/battopt.png\" "
            "-sound Ping -group battopt >/dev/null 2>&1 &",
            home);
    }
    system(notif);

    // 2. Ensure SwiftBar running
    system("if ! /usr/bin/pgrep -x SwiftBar >/dev/null; then /usr/bin/open /Applications/SwiftBar.app; fi");

    // 3. Fork: parent exits immediately, child does the work
    if (fork() == 0) {
        // Child — background work
        if (was_disabled) {
            system("/usr/bin/sudo -n /usr/local/bin/battopt-daemon-start >/dev/null 2>&1");
            char rm_cmd[600];
            snprintf(rm_cmd, sizeof(rm_cmd), "/bin/rm -f '%s'", disabled_path);
            system(rm_cmd);
            // Second notification when actually ready
            sleep(3);
            char ready[1024];
            snprintf(ready, sizeof(ready),
                "/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier "
                "-title BattOpt -message 'Control Center restored' "
                "-appIcon \"%s/.battopt-swiftbar/icons/battopt.png\" "
                "-sound Ping -group battopt >/dev/null 2>&1",
                home);
            system(ready);
        } else {
            system("/usr/bin/sudo -n /usr/local/bin/battopt-daemon-start >/dev/null 2>&1");
        }
        exit(0);
    }

    return 0;  // Parent exits fast
}
