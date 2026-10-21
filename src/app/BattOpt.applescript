-- BattOpt.app entry point
-- This applet binary handles the LaunchServices "open" Apple event,
-- which is what Finder requires from an APPL bundle. It delegates all
-- real work to BattOpt-launcher.sh in the bundle's Resources folder.

on run
    try
        set launcherPath to POSIX path of (path to resource "BattOpt-launcher.sh" in bundle (path to me))
        do shell script "/bin/bash " & quoted form of launcherPath & " >/dev/null 2>&1 &"
    on error errMsg number errNum
        do shell script "/usr/bin/osascript -e 'display dialog \"BattOpt launcher failed (error " & errNum & "): " & errMsg & "\" buttons {\"OK\"} with title \"BattOpt\" with icon caution' >/dev/null 2>&1"
    end try
    quit
end run
