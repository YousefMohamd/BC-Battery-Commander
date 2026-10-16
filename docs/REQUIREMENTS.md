# BattOpt — Requirements & Compatibility

This document tells you **whether BattOpt will benefit you** and **what
hardware/software it needs**. Read before installing.

---

## 1. Minimum Requirements

| Component | Requirement | Why |
|-----------|-------------|-----|
| Mac | Intel x86_64 | Uses SMC interface not available on Apple Silicon |
| macOS | 10.15 (Catalina) or newer | SPM 5.3, SwiftBar 1.4+ |
| Storage | Any (SSD or HDD) | HDD reduces sleep quality (see §4) |
| RAM | 4 GB | More RAM = longer wake from Hibernate |
| Battery | Health ≥ 60% | Below that, limits provide little benefit |
| Free disk | 20 GB | Battery snapshots + state files |
| Sudo | Yes | Controls SMC; needs NOPASSWD for battopt/pmset |

---

## 2. Recommended Requirements

For **full feature benefit**, the machine should have:

| Component | Recommended | Reason |
|-----------|-------------|--------|
| Storage | **SSD** | Hibernate writes 8-16 GB; HDD takes 30-60s to wake |
| RAM | 8-16 GB | 16 GB → 15-25s wake; 8 GB → 5-10s |
| Battery health | ≥ 75% | Below 75%, cycle count matters more than limits |
| macOS | 10.15–12.x | Newer macOS moves SMC behind more layers |
| Free disk | 50 GB | Enough headroom for long-term logs |

---

## 3. Feature-by-Feature Hardware Impact

| Feature | SSD | HDD | Low Health (<70%) | High Cycles (>800) |
|---------|-----|-----|-------------------|---------------------|
| Charge limit (85/80) | ✅ Safe | ✅ Safe | ✅ Helps | ⚠️ Helps less |
| Sailing mode | ✅ Safe | ✅ Safe | ✅ Safe | ✅ Safe |
| **Hibernate (mode 25)** | ✅ Recommended | ⚠️ Slow wake | ⚠️ More SSD wear | ✅ Reduces deep discharge |
| Calibration | ✅ Safe | ✅ Safe | ⚠️ Costs 1 full cycle | ⚠️ Costs 1 cycle |
| Clamshell stay-awake | ✅ Safe | ✅ Safe | ⚠️ Heat risk | ✅ Safe |
| Smart Discharge | ✅ Safe | ✅ Safe | ⚠️ Battery stress | ⚠️ Battery stress |
| Power Saver / deep sleep | ✅ Safe | ✅ Safe | ✅ Helps | ✅ Helps |

---

## 4. Hibernatemode 25 — Choose Wisely

BattOpt uses **hibernatemode 25** to reduce overnight drain to ~0%.

**What it means:** RAM contents are compressed and written to disk on
sleep. System powers off completely. Wake reads them back.

**Wake time by hardware:**

| RAM | Storage | Wake time | Verdict |
|-----|---------|-----------|---------|
| 4 GB | SSD | 3-5 s | Excellent |
| 8 GB | SSD | 5-10 s | Good |
| **16 GB** | **SSD** | **15-25 s** | **Acceptable** |
| 4 GB | HDD | 15-25 s | Acceptable |
| 8 GB | HDD | 25-40 s | Slow |
| 16 GB | HDD | 40-60 s | Not recommended |

**SSD wear estimate for 16 GB Mac, 3 sleeps/day:**
- Data written: ~9-17 TB/year
- Typical SSD endurance: 150 TB
- Expected life: **9-16 years** — safe

**If your SSD is a 2012-era original (low TBW):**
- Expected life drops to 5-6 years
- Consider setting `hibernatemode 3` instead (Safe Sleep)
- Trade-off: ~0.3%/hr drain instead of 0%

---

## 5. Who Benefits Most

**You'll get a lot out of BattOpt if:**

- Your Mac stays plugged in for long stretches (charge limits prevent
  staying at 100% — the #1 cause of battery degradation)
- You leave the lid closed on battery overnight
- You want consistent sleep behavior across macOS versions
- You're comfortable with shell scripts and Terminal

**You'll get less benefit if:**

- You use the Mac 90% on battery (limits only protect while plugged in)
- Battery health is already < 60% (limits won't reverse aging)
- You need iOS integration (not supported)
- You expect a Mac App Store signed app (not available)

**Do NOT install if:**

- Your Mac is Apple Silicon (M1/M2/M3) — SMC interface differs
- You're on macOS ≤ 10.14 — dependencies missing
- You can't grant sudo (battopt needs it for SMC writes)
- You use managed/MDM Mac — sudoers edits may conflict

---

## 6. Dependencies

| Package | Source | Notes |
|---------|--------|-------|
| `battopt` CLI | github.com/js4jiang5/BattOpt | Closed-source, x86_64 only |
| SwiftBar | github.com/swiftbar/SwiftBar | MIT, menu-bar plugin runner |
| terminal-notifier | github.com/julienXX/terminal-notifier | For notifications |
| Command Line Tools | Apple | Only CLT needed; no Xcode required |
| Python 3.9+ | System or python.org | For state scripts |

---

## 7. Uninstall Safety

BattOpt does **not** modify:
- macOS system files (only `/usr/local/bin` symlinks)
- Kernel extensions
- Boot process
- User data outside `~/.battopt-swiftbar/`

To uninstall:
```bash
~/Desktop/BattOpt-CC-Release/install.sh uninstall

All state files remain in ~/.battopt-swiftbar/ for audit.
8. Long-Term Health Guarantees

BattOpt will never:

    Force battery below 20% (hard floor)

    Force charge above 100% (SMC physical cap)

    Discharge while on AC (except intentional Smart Discharge)

    Modify firmware or NVRAM

    Write to SMC more than 10×/day in steady state

Every write is logged in ~/.battopt-swiftbar/actions.log for audit.

Last updated: 2026-10-16 · v1.6.2
