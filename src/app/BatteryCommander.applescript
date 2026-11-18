-- Battery Commander Application Wrapper

on run
    try
        set launcherPath to POSIX path of (path to resource "BatteryCommander-launcher.sh" in bundle (path to me))
        do shell script "/usr/bin/nohup /bin/bash " & quoted form of launcherPath & " </dev/null >/dev/null 2>&1 &"
    end try
end run

on idle
    return 60
end idle

on quit
    try
        set homePath to POSIX path of (path to home folder)
        -- BC state dir: ~/.battery-commander/ is the ONLY live state dir
        -- (consolidation 2026-11-13, M2: old-dir fallback retired). If it
        -- is missing there is nothing to shut down — skip the dispatch.
        set stateDir to ".battery-commander"
        set stateDirExists to true
        try
            do shell script "/bin/test -d " & quoted form of (homePath & ".battery-commander")
        on error
            set stateDirExists to false
        end try
        if stateDirExists then
        set dispatchPath to homePath & stateDir & "/dispatch.sh"
        set logPath to homePath & stateDir & "/actions.log"
        
        -- Detach shutdown from the applet before allowing the applet to quit.
        set shutdownCommand to "/usr/bin/nohup /bin/bash " & ¬
            quoted form of dispatchPath & " shutdown --force >> " & ¬
            quoted form of logPath & " 2>&1 </dev/null &"
            
        do shell script shutdownCommand
        delay 5
        end if
    end try
    
    continue quit
end quit
