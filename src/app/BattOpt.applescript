-- BattOpt.app entry point
on run
    try
        set launcherPath to POSIX path of (path to resource "BattOpt-launcher.sh" in bundle (path to me))
        do shell script "/bin/bash " & quoted form of launcherPath & " >/dev/null 2>&1 &"
    end try
end run

on quit
    try
        do shell script "/bin/bash $HOME/.battopt-swiftbar/dispatch.sh shutdown >/dev/null 2>&1 &"
    end try
    continue quit
end quit
