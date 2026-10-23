-- BattOpt Application Wrapper
on run
    try
        set launcherPath to POSIX path of (path to resource "BattOpt-launcher.sh" in bundle (path to me))
        do shell script "/bin/bash " & quoted form of launcherPath & " >/dev/null 2>&1 &"
    end try
end run

on idle
    -- Keep the applet alive so that `on quit` is delivered when the app is closed.
    return 60
end idle

on quit
    try
        do shell script "touch $HOME/.battopt-swiftbar/.user_shutdown"
        do shell script "pkill -f '/Applications/SwiftBar.app/Contents/MacOS/SwiftBar' || true"
        do shell script "pkill -f 'battopt.10s.sh' || true"
        do shell script "pkill -f 'launch_swiftbar.sh' || true"
        do shell script "pkill -f 'swiftbar_watchdog.sh' || true"
        do shell script "sudo -n pkill -9 -f 'battopt discharge' || true"
        do shell script "sudo -n pkill -9 -f 'battopt charge' || true"
        do shell script "sudo -n pkill -9 -f 'battopt calibrate' || true"
        do shell script "sudo -n /usr/local/bin/battopt discharge stop >/dev/null 2>&1 || true"
        do shell script "sudo -n /usr/local/bin/battopt calibrate stop >/dev/null 2>&1 || true"
        do shell script "for plist in $HOME/Library/LaunchAgents/com.battopt.*.plist; do [ -f \"$plist\" ] || continue; launchctl bootout gui/$(id -u) \"$plist\" >/dev/null 2>&1 || launchctl unload -w \"$plist\" >/dev/null 2>&1 || true; done"
        do shell script "sudo -n /usr/local/bin/battopt-daemon-stop >/dev/null 2>&1 || true"
        do shell script "sudo -n launchctl bootout system/com.buddha-path.BattOpt.daemon >/dev/null 2>&1 || true"
        do shell script "sudo -n pkill -9 -f 'Application Support/battopt/battopt daemon' || true"
        do shell script "sudo -n /usr/local/bin/battopt-powerwatch-stop >/dev/null 2>&1 || true"
        do shell script "sudo -n pkill -9 -f 'battopt-swiftbar/powerwatch' || true"
    end try
    continue quit
end quit
