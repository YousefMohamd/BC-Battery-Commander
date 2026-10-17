#!/bin/bash
# Slowness / Lag diagnostic — read-only, kills nothing
# Run anytime you feel the Mac is slow
HOME="${HOME:-/Users/Yousef}"
REPORT="/tmp/slowness-$(date +%Y%m%d-%H%M%S).txt"

{
echo "═══════════════════════════════════════════════════"
echo "  Slowness Diagnostic — $(date '+%F %T')"
echo "═══════════════════════════════════════════════════"

# ─── 1. SYSTEM LOAD ───
echo ""
echo "── 1. SYSTEM LOAD ──"
LOAD=$(sysctl -n vm.loadavg)
echo "Load avg: $LOAD"
echo "  (Healthy: < CPU_cores | Concern: > 2x cores)"
CORES=$(sysctl -n hw.ncpu)
echo "CPU cores: $CORES"
LOAD_1=$(echo "$LOAD" | awk '{print $2}')
echo "Load/core ratio: $(echo "$LOAD_1 / $CORES" | bc -l 2>/dev/null | cut -c1-5)"

# ─── 2. MEMORY ───
echo ""
echo "── 2. MEMORY ──"
echo "VM stats:"
vm_stat | head -8
echo ""
echo "Swap:"
sysctl -n vm.swapusage
echo ""
echo "Memory pressure (if available):"
memory_pressure 2>/dev/null | tail -5 || echo "n/a on Catalina"

# ─── 3. TOP CPU PROCESSES ───
echo ""
echo "── 3. TOP 10 CPU CONSUMERS ──"
ps aux | sort -rk 3 | head -11 | awk '{printf "%-6s %5s%% %6sMB  %s\n", $2, $3, int($6/1024), substr($0, index($0,$11), 60)}'

# ─── 4. TOP MEMORY PROCESSES ───
echo ""
echo "── 4. TOP 10 MEMORY CONSUMERS ──"
ps aux | sort -rk 4 | head -11 | awk '{printf "%-6s %5s%% %6sMB  %s\n", $2, $4, int($6/1024), substr($0, index($0,$11), 60)}'

# ─── 5. DISK I/O ───
echo ""
echo "── 5. DISK I/O (top 10) ──"
if command -v iotop >/dev/null 2>&1; then
    sudo -n iotop -P -n 1 -b 2>/dev/null | head -12 || echo "iotop requires root"
else
    echo "iotop not installed"
fi
echo ""
echo "Disk usage:"
df -h / | tail -1

# ─── 6. KERNEL TASK / WINDOWSERVER ───
echo ""
echo "── 6. KERNEL & WINDOWSERVER ──"
ps aux | grep -E "kernel_task|WindowServer|launchd|mds|mdworker|mds_stores|photolibraryd|cloudd" | grep -v grep | awk '{printf "%-6s %5s%% %6sMB  %s\n", $2, $3, int($6/1024), $11}'

# ─── 7. THERMAL / POWER ───
echo ""
echo "── 7. THERMAL & POWER ──"
echo "pmset -g therm:"
pmset -g therm 2>/dev/null
echo ""
echo "CPU speed limit (100 = full):"
pmset -g therm 2>/dev/null | grep -i "CPU_Speed_Limit" || echo "n/a"

# ─── 8. BATTERY STATE ───
echo ""
echo "── 8. BATTERY STATE ──"
ioreg -rn AppleSmartBattery | grep -E '"CurrentCapacity"|"MaxCapacity"|"IsCharging"|"ExternalConnected"|"Temperature"|"CycleCount"'

# ─── 9. NETWORK ───
echo ""
echo "── 9. NETWORK ──"
netstat -an 2>/dev/null | grep ESTABLISHED | wc -l | xargs echo "Established connections:"
lsof -i -n 2>/dev/null | grep -c ESTABLISHED | xargs echo "Active network sockets:"

# ─── 10. PROCESS CHURN (spawning) ───
echo ""
echo "── 10. PROCESS COUNT BY NAME ──"
ps -A -o comm= | awk -F/ '{print $NF}' | sort | uniq -c | sort -rn | head -12

# ─── 11. SPOTLIGHT INDEXING ───
echo ""
echo "── 11. SPOTLIGHT INDEXING ──"
mdutil -s / 2>&1 | head -3
pgrep -fl "mds|mdworker" | head -5 || echo "no indexing"

# ─── 12. TIME MACHINE ───
echo ""
echo "── 12. TIME MACHINE ──"
tmutil currentphase 2>/dev/null || echo "n/a"

# ─── 13. BATTOPT SPECIFIC ───
echo ""
echo "── 13. BATTOPT PROCESSES ──"
ps aux | grep -E "battopt|SwiftBar|powerwatch|guardian|enforce" | grep -v grep | awk '{printf "%-6s %5s%% %6sMB  %s\n", $2, $3, int($6/1024), substr($0, index($0,$11), 50)}'

# ─── 14. WATCHDOG / RELAUNCH CHURN ───
echo ""
echo "── 14. RECENT ACTIVITY (last 20 log lines) ──"
tail -20 "$HOME/.battopt-swiftbar/actions.log" 2>/dev/null

# ─── 15. WAKE EVENTS (last 30 min) ───
echo ""
echo "── 15. WAKE EVENTS (last 30 min) ──"
pmset -g log | grep -E "Wake from|DarkWake" | tail -10

# ─── SUMMARY ───
echo ""
echo "═══════════════════════════════════════════════════"
echo "  INTERPRETATION GUIDE"
echo "═══════════════════════════════════════════════════"
echo "  Load > 2× cores          → CPU overload"
echo "  Swap > 3000 MB           → Memory pressure"
echo "  kernel_task > 30% CPU    → Thermal throttling"
echo "  WindowServer > 15%       → Graphics overload"
echo "  mds/mdworker > 20%       → Spotlight indexing"
echo "  Process count spikes     → Watchdog loop"
echo "  CPU_Speed_Limit < 100    → Thermal throttle"
echo ""
echo "  Report: $REPORT"
} 2>&1 | tee "$REPORT"
