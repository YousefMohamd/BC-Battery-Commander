-- BattOpt Application Wrapper

on run
    try
        set launcherPath to POSIX path of (path to resource "BattOpt-launcher.sh" in bundle (path to me))
        do shell script "/usr/bin/nohup /bin/bash " & quoted form of launcherPath & " </dev/null >/dev/null 2>&1 &"
    end try
end run

on idle
    return 60
end idle

on quit
    set homePath to POSIX path of (path to home folder)
    set dispatchPath to homePath & ".battopt-swiftbar/dispatch.sh"
    set logPath to homePath & ".battopt-swiftbar/actions.log"

    set shutdownCommand to "/bin/bash " & ¬
        quoted form of dispatchPath & " shutdown --force >> " & ¬
        quoted form of logPath & " 2>&1 </dev/null"

    try
        do shell script shutdownCommand
    on error errorMessage number errorNumber
        try
            do shell script "printf '%s\n' " & ¬
                quoted form of ("AppleScript shutdown failed (" & errorNumber & "): " & errorMessage) & ¬
                " >> " & quoted form of logPath
        end try
    end try

    continue quit
end quit
