#!/bin/bash
# Conflict Detection — find tools that clash with BattOpt

REPORT="/tmp/battopt_conflicts_$(date +%Y%m%d_%H%M).txt"

{
echo "═══════════════════════════════════════════════════"
echo "  BattOpt — Conflict Detection"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════"
echo ""

echo "─── OTHER BATTERY TOOLS ───"
found=0
for tool in "AlDente" "Battery" "Coconut" "BatteryHealth" "battery"; do
    pids=$(pgrep -fl "$tool" 2>/dev/null | grep -v battopt)
    if [ -n "$pids" ]; then
        echo "⚠️ $tool: $pids"
        found=1
    fi
done
[ "$found" = "0" ] && echo "✅ No other battery tools running"
echo ""

echo "─── SMC MODIFIERS ───"
for tool in "smcFanControl" "Macs Fan Control" "TG Pro" "iStat"; do
    pids=$(pgrep -fl "$tool" 2>/dev/null)
    if [ -n "$pids" ]; then
        echo "ℹ️ $tool: $pids"
    fi
done
echo ""

echo "─── BACKGROUND HELPERS ───"
for tool in "CleanMyMac" "macpaw" "Cold Turkey" "NMHFirefox"; do
    pids=$(pgrep -fl "$tool" 2>/dev/null)
    if [ -n "$pids" ]; then
        echo "⚠️ $tool: $pids"
    fi
done
echo ""

echo "─── LAUNCHAGENTS (non-Apple, non-BattOpt) ───"
launchctl list | grep -v "com.apple" | grep -v "battopt" | grep -v "^-" | head -20
echo ""

echo "─── KERNEL EXTENSIONS ───"
kextstat 2>/dev/null | grep -v "com.apple" | head -10
echo ""

echo "─── SUDOERS ENTRIES ───"
ls -la /etc/sudoers.d/ 2>/dev/null
echo ""

echo "─── CONFLICTS WITH BATTOPT ───"
# Check if other tools use BCLM
for pid in $(pgrep -f smc 2>/dev/null); do
    cmd=$(ps -p $pid -o command= 2>/dev/null)
    echo "Process using SMC: $cmd"
done
echo ""

echo "═══════════════════════════════════════════════════"
} | tee "$REPORT"

echo "Report: $REPORT"
