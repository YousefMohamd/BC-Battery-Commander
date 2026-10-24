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
    try
        set homePath to POSIX path of (path to home folder)
        set dispatchPath to homePath & ".battopt-swiftbar/dispatch.sh"
        set logPath to homePath & ".battopt-swiftbar/actions.log"
        
        -- Detach shutdown from the applet before allowing the applet to quit.
        set shutdownCommand to "/usr/bin/nohup /bin/bash " & ¬
            quoted form of dispatchPath & " shutdown --force >> " & ¬
            quoted form of logPath & " 2>&1 </dev/null &"
            
        do shell script shutdownCommand
        delay 5
    end try
    
    continue quit
end quit
