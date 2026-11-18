# Comprehensive-Test Catalog — Battery Commander — 2026-11-17

**Purpose:** the finish-day comprehensive test, entry by entry
(بند بند). Every entry names its steps and the specific criteria
that judge each step/button. **Nothing is omitted:** all 95
criteria from `tool-criteria-20261116.md` are mapped (coverage
table at the end), plus the 2026-11-17 finish-prep additions
(Part D) and the parked-issue capture protocol (Part E).

**Sources:** `final-retest-plan-20261116.md` (suites, live
proofs, user-eyes, report shape) + `tool-criteria-20261116.md`
(the 95) + the 2026-11-17 finish-prep results.

**Change note (2026-11-17 00:46, owner's corrections):** the
app icon was redone from the artist's Krita source
(`Battery Commander.kra`, layer group "Copy of Group 7" —
native transparency, no keying) after the owner rejected the
flood-keyed icon; the discharge glyphs **★ ■ ↳** were restored
to the menu as agreed functional symbols. D03, D05, D06, D07,
D08 below carry the updated expectations; the identity package
was rebuilt to match (`BatteryCommander-Identity/`, v2).

**Change note (2026-11-17 06:24, safety gate):** the dispatch
full-stop action is now gated — it executes only with a fresh
(≤120 s) arming token `.fullstop_armed`, consumed on pass;
blind or stale calls log `shutdown: REFUSED — not armed (gate)`
and change nothing, and `BC_FULLSTOP_PROBE=1` + a fresh token
proves the gate (`GATE PASS`) with no teardown. Both dispatch
copies md5 `00c6502626ae8bd7c94cd9bdeaad1852` (backups
`.pre-gate-20261117`). The gate neutralises the quit path of
the leftover applet process (PID 21524), whose handler calls
the action blindly. D11 below carries the entry; the three
sandbox cases live in Part C of
`verify-deploy-test/test_sidecar_dispatch.sh`, and the live
proof script is `battopt-project/bc-build/gate_live_test_20261117.sh`.

**Change note (2026-11-17 06:38, icon B — owner's pick):**
from the three improvement candidates built off the identity,
the owner picked **B — Bold mark**: the whole mark at **92% of
canvas width** with the same mark composited beneath itself at
**103%** of its own size (strokes thicken with the artwork's
own paint/alpha; nothing recoloured or redrawn). B's icns
`2ec113bc…` is now installed in the bundle, both live copies
and the identity package (backups `.pre-iconb-20261117`); the
app was rebuilt (exe `d61f0d08…`) and FR-007 re-proven on the
new binary. D06, D07 (and D08's proof count) carry the updated
expectations; `app-icon.md` documents B as the standard, the
86% construction superseded.

**Change note (2026-11-17 07:48, icon V3 — owner's pick):**
the enlarged B (B-final, icns `19a5dd90…`, exe `0216d2d8…`)
shipped the same morning, but the owner judged it still
small in Launchpad; the comparison against nine real app
icons from this Mac measured the transparent wide mark at
27.4% ink / 57.8% height vs the real icons' 62.7% / 86.2%
average. From that sheet the owner picked **V3 — the
framed emblem, no tile** (crop (200, 0)–(3250, 1980) of the
master at 95% of canvas; ink 31.3% / height 62.5%). V3's
icns `a3579b5a…` is installed in the bundle, both live
copies and the identity package (backups
`.pre-iconv3-20261117`); the app was rebuilt (exe
`654c5576…`), FR-007 re-proven on the new binary, and the
strong icon-cache reset (lsregister + IconServices stores
+ Dock) performed. D06, D07 carry the final expectations;
`app-icon.md` documents V3 as the standard.

**Change note (2026-11-17 08:18, icon V3 + owner's
treatment):** the owner kept V3 but specified his own
treatment on it — deeper blacks, lighter whites, richer
colour, slightly larger so the sharpness shows — and
approved the treated sheet
(`icon-candidates-20261117/icon-treated-20261117.png`).
Treatment, applied to the composed master (RGB only; alpha
asserted byte-identical): levels black point 10/255, white
point 245/255; saturation ×1.10; sharpness ×1.03; placement
enlarged 95% → **99%** of canvas. Measured: ink **34.3%** /
bbox height **64.4%** at the 128 render (untreated V3:
31.3% / 62.5%). Treated icns `8750815b…` is installed in
the bundle, both live copies and the identity package
(backups `.pre-icontreated-20261117`); the app was rebuilt
(exe `99ea8585…`), FR-007 re-proven on the new binary
(AppleEvent quit 08:24:51 → RELEASE OK 08:25:14 →
relaunch 08:25:22 → enforcement resumed at the first
tick), and the strong icon-cache reset performed. D06, D07
carry the updated expectations; `app-icon.md` documents
V3 + treatment as the standard. Contemporaneous user
action: at 08:28:29 the owner invoked Stop Charging Now
(`stop_now`, actions.log), persisting hold-current
**85/84** by design — the config now stands at 85/84
(owner's last action, last-state-wins); the execution-day
refresh's 86/85 expectation below predates it — reconcile
from actions.log.

**Execution-day refresh (do first, before A01):** re-record the
live md5s and state. Expected at start of 2026-11-17: daemon
bc-limit **v1.7-stagec** `b0651e89…`; app exe `99ea8585…`
(icon-treated build, 2026-11-17); bundle icon
`8750815b…` (V3 framed-emblem + owner's treatment, transparent); dispatch both copies
`00c65026…` (safety-gate build, 2026-11-17); config values
**86/85**, SAILING=false, SAIL_GAP=1; sentinel clean; bc-verify
PHASE_C=VERIFIED. Any mismatch is itself a finding — stop and
reconcile before testing.

**Stop rule:** any FAIL in Part A stops the run — fix forward
or roll back, then restart Part A from A01. Parts B–E run only
on a green Part A. Every live proof ends back at the **86/85
hold**; the Quit proof (B06) is last among live proofs because
it releases the limit.

Criteria are cited as «القسم N — اسم المعيار» exactly as named
in the criteria sheet.

---

## Part A — Automated suites (run all, in this order)

**A01 — Daemon calibration suite** `test_bc_limit_calibrate.sh`
Steps: run against the deployed v1.7-stagec source; record
PASS/FAIL/SKIP verbatim. Pass bar: **15/15**.
Judges: «7 — قفل صلب في الكود», «7 — نبض التشغيل»,
«7 — نهاية الأرضية» (fixture half).

**A02 — Daemon discharge suite** `test_bc_limit_discharge.sh`
Pass bar: **11/11**.
Judges: «4 — أرضية الأمان للجلسات العادية», «4 — قاعدة اليتيم»,
«4 — فك الوضع», «4 — النوم ينهي الجلسة».

**A03 — Daemon APG suite** `test_bc_limit_apg.sh`
Pass bar: **9/9 plus** the Stage C addendum case:
`.tool_closed` present + load-pause → the FR-007 release still
wins.
Judges: «3 — وقفة الحمل لوحدها», «3 — معنى "حراري"»,
«2 — الحرارة تمنع الاستئناف», «11 — تحرير الحد».

**A04 — Daemon gauge suite** `test_bc_limit_gauge.sh`
Pass bar: all PASS with both halves exercised (baseline 6 PASS
/ 2 SKIP). Scheduling: run it across the calibration day's
charge leg + hold so both windows occur naturally — never
force a window.
Judges: «5 — حركة كبيرة = مشبوهة», «5 — تأكيد الحركة»,
«5 — مستوى لسه بيتحرك», «5 — كتابة الثبات عند التجاوز»,
«5 — فحص واحد ما يقررش».

**A05 — Daemon AC suite** `test_bc_limit_ac.sh`
Pass bar: ≥ 14 PASS / 0 FAIL / 1 SKIP (A9 orphan case stays
opportunistic).
Judges: «4 — التفريغ على الشاحن», «4 — مراقبة ACEN»,
«4 — سرعة الاستجابة (المستخدم)», «4 — سرعة الاستجابة
(التصحيحية)».

**A06 — FR-007 flag cases** (Stage C sandbox set, re-run on the
live v1.7 binary)
Steps: (1) flag present → daemon logs the release line ending
`RELEASE OK`; (2) no flag → behaviour identical to v1.6.1;
(3) flag + discharge active → discharge mode cleared first.
Pass bar: all three shapes as designed.
Judges: «11 — الخروج بيسلم الجهاز للنظام», «11 — تحرير الحد»,
«11 — تفريغ شغال وقت الخروج», «11 — الرجوع».

**A07 — Discharge monitor suite** `test_discharge.sh`
Pass bar: **36/36**.
Judges: «4 — هدف الجلسة», «4 — أقصى عمر للجلسة»,
«4 — تسليح جلسة المستخدم», «4 — الإكمال», «4 — قلبة الكابل»,
«4 — الانتظار على الشاحن».

**A08 — Charge persistence suite** `test_charge_persistence.sh`
Pass bar: **51/51**.
Judges: «1 — آخر حالة تكسب», «2 — Charge to 100%»,
«2 — Stop Charging Now», «2 — إلغاء كل الحدود»,
«2 — رجوع من الثبات المؤقت», «8 — لو الإبحار اشتغل».

**A09 — Calibration suite** `test_calibration.sh`
Pass bar: **98/98**.
Judges: «7 — اختيار النطاق تلقائي», «7 — النطاق العالي»,
«7 — النطاق الواطي», «7 — نهاية الشحن الكامل»,
«7 — أوقات الراحة», «7 — بيانات صحة مش مقروءة».

**A10 — Watchdog suite** `test_bc_watchdog.sh`
Pass bar: **PASS**.
Judges: «6 — زناد التجاوز», «6 — سلم الانحراف»,
«6 — مهلة بعد الصحيان», «6 — إيقاع الواتش دوج»,
«3 — أصفر», «3 — أحمر», «3 — الرجوع لأخضر من أصفر»,
«3 — الرجوع من أحمر», «3 — إيقاف APG يدويًا».

**A11 — Sentinel suite**
Pass bar: **PASS on the post-Stage C pair set (13 pairs)** —
the count may differ from the soak era, the verdict may not.
Judges: «6 — حارس الحارس (Sentinel)».

**A12 — Sidecar + dispatch suites**
Pass bar: **15/15**.
Judges: «1 — نطاق الحد المخصص», «1 — الأدنى دايمًا تحت
الأعلى», «8 — نطاق الفجوة من القايمة», «9 — بروفايل مش معروف».

**A13 — Tracker equivalence**
Pass bar: **PASS** (episode tracker output identical across
the equivalence fixtures).
Judges: «13 — الاستمرارية» (fixture half).

**A14 — bc-verify on the live store**
Steps: run `bc-verify-run.sh` (or read the day's 08:00 run).
Pass bar: **PHASE_C=VERIFIED, exit 0**; fails_range=0 and
fails_7d=0 expected — the one known explained episode
(`hold-1794837951`, the Stage C FR-007 paperwork FAIL) and
tonight's two designed release windows (2026-11-17 00:34 +
00:37) are the only tolerated exceptions, each named in the
delivery report with its daemon RELEASE OK lines.
Judges: «13 — إثبات الثبات», «13 — إثبات التفريغ الطبيعي»,
«13 — إثبات الشحن», «13 — الدورة الكاملة»,
«13 — تعديل §3 (2026-11-14)».

**A15 — verify-install** `src/verify-install.sh`
Pass bar: **12/12** with post-Stage C expectations (app
present; plugin absence is correct).
Judges: installation integrity across «1 — آلية الحد»
(deployment half).

**A16 — Project health** `project_health.sh`
Pass bar: **FAIL 0, verdict HEALTHY** (Stage C check set:
app-exe check in place of the plugin-presence check).
Judges: deployment integrity (all sections' live halves).

**A17 — App action coverage**
Steps: run the installed app's `--dump-menu`; compare its
action set against the dispatch action set in both directions.
Pass bar: **identical except one named delta** — the dispatch
action `shutdown` exists in code but is intentionally NOT
exposed in the menu (2026-11-17 decision, Part D01). Exposed
actions = 47 + [quit] + [refresh]. Smart Discharge item and
Sleep Mode subtree byte-identical to the frozen shapes in
`app-redesign/menu-design.md`.
Judges: «1 — آخر حالة تكسب» (surface half — every button
present and wired).

---

## Part B — Live behaviours (re-prove each, in this order)

**B01 — Hold**
Steps: on AC at 86/85, observe ≥ 30 min. Daemon state lines
show pct=86, BCLM=10, charging=0 throughout; watchdog
heartbeat fresh; no session files.
Evidence: daemon log excerpt + the tracker's hold episode.
Judges: «1 — الحد الافتراضي الحالي», «1 — آلية الحد»,
«1 — الثبات عند الأعلى», «1 — كل كتابة مؤكدة»,
«1 — إيقاع الدايمون», «13 — إثبات الثبات».

**B02 — Charge resume under load**
Steps: with APG yellow/red from CPU load only (temp < 38 °C,
pause-reason file = `load`): press Charge to 100% → daemon
logs `APG load-pause: resume allowed (reason=load)` +
`WRITE OK: BCLM=100 verified by read-back`; charging starts.
Revert to 86/85; hold re-engages.
Pattern: the 2026-11-16 00:38 proof. Thermal half is
fixture-only (A03) — never heat the battery for a test.
Judges: «2 — استئناف الشحن تحت الحمل», «3 — وقفة الحمل
لوحدها», «1 — استئناف الشحن عند الأدنى».

**B03 — On-AC discharge to a lower limit**
Steps: at the 86 hold, set Custom Limit 80/79 via the real
menu → session arms → `DISCHARGE MODE ENGAGED` on the first
daemon tick after arming → drains on AC (ExternalConnected
flips, negative current) → `DISCHARGE MODE DISENGAGED: target
reached` → `SESSION_COMPLETE … reason=target-reached`; cable
attached throughout. Restore 86/85; charge back; hold.
Pattern: the 2026-11-16 14:37–14:57 proof.
Judges: «4 — التفريغ على الشاحن», «4 — مراقبة ACEN»,
«4 — سرعة الاستجابة (المستخدم)», «4 — الإكمال»,
«1 — نطاق الحد المخصص».

**B04 — On-battery discharge**
Steps: start Smart Discharge and unplug (or start unplugged):
session goes ACTIVE on battery, drains to target, completes;
replug → normal charge to the hold.
Yousef's hands do the unplug/replug — a user action, not a
forced test. Pattern: the 2026-11-15 23:17–23:33 proof.
Judges: «4 — دليل التفريغ على البطارية», «4 — بوابة الحرارة»,
«4 — الإكمال», «12 — 🔋 بطارية» (live half).

**B05 — Gauge-jump refusal**
Cannot be summoned and must not be forced. Re-proof = A04's
fixture cases **plus** the verification system's §3 scoring
of any natural jump in the test window (drift at zero current
with BCLM=10 throughout scores as gauge drift, not
overshoot). If no natural jump occurs in the window, the
suite evidence stands alone and the report says so.
Judges: «5 — حركة كبيرة = مشبوهة», «5 — تأكيد الحركة»,
«5 — كتابة الثبات عند التجاوز», «6 — الانجراف الوهمي ما
يبدأش تصحيح», «13 — تعديل §3 (2026-11-14)».

**B06 — Quit release (FR-007) — LAST live proof**
Steps: Yousef clicks Quit Battery Commander (now the red
line) → icon disappears → ≤ ~70 s the daemon logs the release
ending `RELEASE OK: BCLM=100 verified by read-back` → plugged
in below 100%, the battery visibly charges past 86% (stock) →
config values unchanged (86/85) → he relaunches the app →
housekeeping clears `.tool_closed` → enforcement resumes
≤ ~70 s (BCLM=10 written, read-back verified).
Pass = both directions in logs **and** in the menu bar.
Note: already re-proven on the cleaned binary on 2026-11-17
00:36–00:38 (release 00:37:18, resume 00:38:19) — B06 on
finish day is the user-eyes repetition from the real menu.
Judges: «11 — الخروج بيسلم الجهاز للنظام», «11 — تحرير
الحد», «11 — الإعدادات ما بتتلمسش», «11 — الرجوع»,
«11 — اختبار القبول» (with the Stage C 3-cycle record).

**B07 — Calibration (by reference)**
The live run happens earlier on finish day (see
`tomorrow-runbook-20261117.md`). Cite its episode: result,
floor behaviour, gauge before/after, from `calibration.log` +
the tracker. Not re-run here.
Judges: «7 — نطاق بطارية يوسف», «7 — نهاية الشحن الكامل»,
«7 — نهاية الأرضية», «7 — أوقات الراحة» (live halves).

---

## Part C — User-eyes (Yousef, one short session)

Automation cannot click the menu or judge pixels — these are
his, batched into one sitting.

**C01** — Exactly **one** BC menu-bar icon (the app's); the
plugin icon is gone. Judges: Stage C surface integrity.

**C02** — Icon state map correct in each reachable state:
🔌 on charger · ⚡ charging · 🔴 on battery · 🔋 during a
discharge session. Judges: «12 — 🔌 فيشة», «12 — ⚡ برق»,
«12 — 🔴 دايرة حمرا», «12 — 🔋 بطارية», «12 — القاعدة».

**C03** — Menu colours match the identity palette
(`BatteryCommander-Identity/palette.md`) — headers and
live-state lines; grouped structure as designed; Smart
Discharge and Sleep Mode shapes unchanged (frozen).
Judges: identity conformance (WS1).

**C04** — Header correct ≤ ~4 s after launch; menu opens with
no visible lag he finds objectionable (his call, not a
benchmark). Judges: responsiveness (eyes half; see also E01).

**C05** — Login item present, resolving to
`/Applications/BatteryCommander.app`; app relaunches cleanly
at login. Judges: FR-006 housekeeping surface.

**C06** — Launchpad/Finder shows the app with the NEW
transparent icon (no grey box). Judges: Part D icon entries
(eyes half).

**C07** — About text correct; notifications (session
complete, overshoot) arrive and read correctly. Judges:
surface correctness.

**C08** — The stray Stage B-era applet is gone from the menu
bar after his next natural logout/restart (it exits on its
own; nobody kills it). Judges: environment cleanliness.

---

## Part D — Finish-prep additions (2026-11-17)

**D01 — "Stop ALL Services" is gone**
Steps: dump the installed menu (`--dump-menu` + open it by
eye). Pass: no item with that text anywhere, main menu or any
submenu; the dispatch `shutdown` action still exists in code,
unexposed (verify by source grep, not by clicking).
Judges: Yousef's 2026-11-17 removal decision.

**D02 — Quit carries the red**
Steps: open the menu. Pass: **Quit Battery Commander** is the
only red line in the menu (main menu and, if shown, the
degraded menu); its behaviour is unchanged (B06 proves it).
Judges: «11 — الخروج بيسلم الجهاز للنظام» (surface half);
identity rule "one red" (`BatteryCommander-Identity/usage.md`).

**D03 — Emoji/symbol audit**
Steps: dump the menu; scan every item and submenu title.
Pass: **zero decorative emoji** in items/submenus, and the
agreed **functional symbol set is present and complete**:
✓ (selected/OK) and ✗ (checklist off); plain typography
(─ · –); and the discharge glyphs **★ on Smart Discharge**,
**■ on Cancel Discharge**, **↳ on Stop Discharge** (the last
two render only while a session is active — verify by source
grep against `MenuModel.swift` lines 107/109/111 when no
session is running). The header state icons 🔌 ⚡ 🔴 🔋 (and
⏳ while no reading exists) are untouched and out of scope
for this audit — they are the functional state map.
Reference result (2026-11-17): the cleanup build's menu model
contained ✓×11, ✗×6 and no other pictographs; the
glyph-restore build adds exactly ★ ■ ↳ back, nothing else
(dump diff vs the cleanup build = the ★ line only, plus the
■/↳ source lines).
Judges: Yousef's 2026-11-17 professional-cleanup decision, as
amended by his 2026-11-17 00:46 symbol restoration (★ ■ ↳ are
functional, "الروموز بتاعت الدس اتشارج"); identity spec
`BatteryCommander-Identity/iconography.md`.

**D04 — Purposeless lines removed**
Pass: no "SwiftBar" coexistence line anywhere in the menu
(the retired plugin's process monitor); no orphan
"All saved reports" description line in Logs.
Judges: cleanup decision; A17's coverage delta accounts for
both (display-only lines, no actions lost).

**D05 — Naming/colour unification**
Steps: read the full dump top to bottom. Pass: section
headers all BLUE #007AFF; submenu titles carry no " ▶"
suffix (native arrow only); **★ Smart Discharge** keeps its
ORANGE #FF9500 accent **with** its ★ glyph; **■ Cancel
Discharge** and **↳ Stop Discharge** carry their glyphs
(session-active lines; source-verify if idle); Sleep Report
reads as plain labelled lines with ✓/✗ markers (no ✅ ⚠️ 🔋
💚 🌡️ ⚡ 🔄 📍 🕐 📊 ℹ️ 🔌 glyphs); Auto Cleanup descriptions
carry no ℹ️ ⏱️ 📌 glyphs; the 💤 glyph is gone from the Sleep
Report title.
Judges: identity palette + typography + iconography sheets
(WS1, as amended 2026-11-17 00:46).

**D06 — Icon transparency (file level)**
Steps: extract the installed bundle's .icns elements
(iconutil) at 1024/256/16. Pass: corner alpha = 0 at every
size (round-trip verified 2026-11-17). The icon is composed
from the **Krita-native master** (layer group "Copy of
Group 7" of `Battery Commander.kra`, rendered by Krita with
the backdrop layers hidden; full-canvas export 3508×2039
with **native alpha** — **no keying, no matte**, so no
grey-fringe criterion applies; the retired flood-keyed icon
`27c1f43c…` must NOT be what is installed). Composition
(**V3 — framed emblem, no tile**, owner's pick 2026-11-17
07:48): a **crop of the master, (200, 0)–(3250, 1980) =
3050×1980 ≈ 1.54:1** — sun + rays, the whole pyramid WITH
its base, a 130 px ground-band slice, both caravan groups
whole — placed at **99% of canvas width**, centred, on
full transparency; **no tile, no underlay**; plus the
**owner's treatment** (2026-11-17 08:18): levels black
point 10/255, white point 245/255, saturation ×1.10,
sharpness ×1.03 — RGB only, alpha byte-identical. The superseded
whole-mark constructions — 86% no-underlay (icns
`87d443db…`), B 92% + 103% underlay (icns `2ec113bc…`),
B-final ≈97.5% width (icns `19a5dd90…`), and untreated V3
at 95% without the treatment (icns `a3579b5a…`) — must NOT
be what is installed. Measured on the shipped icns: ink
**34.3%** /
bbox height **64.4%** at the 128 render (comparison-sheet
method; real-icon average 62.7% / 86.2% — the owner picked
the transparent emblem over the tile variants with those
numbers in front of him). Reference md5s: icns
`8750815b…`, identical in the bundle, `assets/icons/`,
`~/.battery-commander/icons/` and the identity package;
master in
`BatteryCommander-Identity/logo/logo-transparent-master.png`
(+ `logo-fullcanvas.png` provenance).
Judges: icon-V3 acceptance numbers (2026-11-17 comparison
package), `BatteryCommander-Identity/app-icon.md`.

**D07 — Icon on light and dark**
Steps: view `BatteryCommander-Identity/logo/proof-light-512.png`,
`proof-dark-512.png`, `proof-light-128.png`,
`proof-dark-128.png`, `proof-light-32.png`,
`proof-dark-32.png`, `proof-light-16.png`,
`proof-dark-16.png` (treated-V3 renders, regenerated 2026-11-17).
Pass: the framed emblem (V3 + treatment construction) reads cleanly on
both backgrounds at 512 and 128; no grey fringe, no halo
(no keyed matte exists). At 32 and 16 the emblem reduces
to the sun + pyramid silhouette — thinner than the retired
B construction's underlaid form, there being no underlay to
carry it; the judge for the small sizes is the comparison
sheet the owner picked V3 from
(`icon-candidates-20261117/icon-comparison-real-20261117.png`
— its 32 px column was in front of him at the pick,
2026-11-17 07:48), and his acceptance of that small-size
form is the criterion, recorded in `app-icon.md`. Eyes half:
C06.
Judges: icon-V3 render proofs (identity `proof-*` set) +
the real-icon comparison sheet.

**D08 — Identity package in place and in sync**
Steps: open `BatteryCommander-Identity/` at the repo root.
Pass: README-identity.md, logo.md, palette.md,
typography.md, iconography.md, app-icon.md, usage.md,
palette-strip.png and logo/ (native master + fullcanvas,
icns, iconset, 512 PNG, 8 proofs) all present (v2 package,
2026-11-17); the identity icns md5 equals both live copies
(`assets/icons/` and `~/.battery-commander/icons/`) and the
installed bundle's icon. Judges: WS1 package definition, as
upgraded by the 2026-11-17 00:46 package.

**D09 — FINDING (observation): corrective-refusal
notification wording**
Origin: 2026-11-16 — when the watchdog's automatic corrective
session was refused (no second signal), the notification
wording did not distinguish an automatic-corrective refusal
from a user-action refusal.
Steps: IF a corrective refusal occurs naturally during the
test window, capture the notification verbatim (screenshot +
actions.log line) and judge: can a reader tell, from the
notification alone, that an *automatic* action was refused
and no user action failed? Record the verdict in the
delivery report either way. Not a ship blocker unless the
wording affirmatively misleads.
Judges: product rule — no silent/invisible behaviour
(2026-11-15), notification half.

**D10 — FINDING (observation): LAYER2 load/thermal label**
Origin: 2026-11-16 — the watchdog's LAYER2 path logged a
load-only APG pause with thermal wording ("thermal pause"),
and corrective arming kept burning its window under a
load-only pause.
Steps: during any APG-yellow window in the test period,
read the watchdog log's LAYER2 lines. Judge: does the label
match the recorded pause reason (`load` vs thermal)? And if
a corrective arm is deferred under load-only APG, is the
deferral visible with the true reason? Record verbatim lines
in the delivery report.
Judges: «6 — ممنوعات التصحيح», «3 — معنى "حراري"»,
«3 — وقفة الحمل لوحدها» (log-wording halves).

**D11 — Full-stop safety gate (dispatch)**
Origin: 2026-11-17 — the leftover applet process (PID 21524,
started 2026-11-13) carries a quit handler that calls the
dispatch full-stop action blindly; a logout would have fired
the full teardown (all user agents unloaded, config rewritten
100/99, state files purged). The owner removed the action
from the menu (D01) and then approved the gate
(2026-11-17 06:24).
Design: the action's first check requires a fresh arming
token `$DASH/.fullstop_armed` (unix timestamp, age 0–120 s),
consumed on pass. No / stale / unreadable token → logs
`shutdown: REFUSED — not armed (gate)`, exits 0, changes
nothing. `BC_FULLSTOP_PROBE=1` + a fresh token → logs
`shutdown: GATE PASS (probe — no teardown)` and exits before
any teardown. Arming is manual-only by design; no UI arms it.
Both dispatch copies md5 `00c6502626ae8bd7c94cd9bdeaad1852`
(backups `.pre-gate-20261117`).
Steps: (1) source-grep both dispatch copies for the gate
block at the head of the action; md5s match. (2) Run the
suite Part C cases (`test_sidecar_dispatch.sh`): C1 no token
→ REFUSED + zero side effects; C2 stale token → REFUSED,
token not consumed; C3 fresh token + probe → GATE PASS,
token consumed, nothing torn down. (3) Read the live proof
in actions.log (2026-11-17, `gate_live_test_20261117.sh`
against the deployed dispatch): REFUSED 06:29:50 (no token),
REFUSED 06:30:00 (stale token, cleaned up after), GATE PASS
06:30:11 (probe; token consumed) — config md5
`69c6c438…`, 17 agents, app PID and the daemon's 86/85 hold
unchanged across all three. (4) Confirm the ghost is gone:
PID 21524 absent; its retirement quit produced a REFUSED
line from its handler's blind call, with the daemon still
holding 86/85 and no marker file created.
Pass: all four steps hold; any state delta in steps 2–3 is
a ship blocker.
Judges: Yousef's 2026-11-17 gate decision (06:24) + D01's
removal decision; product rule — no invisible behaviour
(the refusal and the pass are both logged, never silent).

---

## Part E — Parked issues: capture protocol (Yousef's rule)

These two reports (2026-11-16) are **parked by his
instruction**: not investigated, not "verified fixed", and
never force-reproduced. An entry below becomes a real test
only when a concrete live case occurs in his natural use.

**E01 — End-to-end response latency**
Trigger: Yousef reports a specific moment ("I pressed X at
~HH:MM and it felt slow"). Protocol: note the exact time and
action → replay that window from the timestamped actions.log
+ daemon log + watchdog log → decompose the delay (60 s
daemon cadence / 60 s watchdog cadence / menu refresh) →
report which cadence owns the delay and whether any part is
abnormal for its cadence. Only a delay exceeding its owning
cadence + one tick is a defect.
Judges: C04 (eyes half) + the cadence criteria
«1 — إيقاع الدايمون», «6 — إيقاع الواتش دوج».

**E02 — "Last values I write are not saved"**
Trigger: Yousef reports a specific setting that did not
persist, with the approximate time. Protocol: replay
actions.log around that time (every dispatch write is
timestamped) → compare the written config values then vs the
config of record now (values are the invariant; the file has
two canonical byte forms — dispatch writer and watchdog
writer — md5 alone proves nothing) → identify whether a
later legitimate writer (last-state-wins) overwrote it, or
a write genuinely vanished. A vanished write with no later
writer = defect, escalate.
Judges: «1 — آخر حالة تكسب», «2 — رجوع من الثبات المؤقت».

---

## Criteria coverage map — all 95, nothing omitted

| Criteria section | Count | Judged by |
|---|---|---|
| 1 — الحد والثبات | 9 | A08, A12, A15, A17, B01, B02, B03, E01, E02 |
| 2 — الشحن | 6 | A03, A08, B02, E02 |
| 3 — APG | 7 | A03, A10, B02, B04, D10 |
| 4 — التفريغ | 16 | A02, A05, A07, B03, B04 |
| 5 — سلامة العداد | 5 | A04, B05 |
| 6 — الحارس والمراقبة | 9 | A10, A11, B05, D10, E01 |
| 7 — المعايرة | 10 | A01, A09, B07 (+ the live run itself, runbook) |
| 8 — الإبحار | 4 | A08, A12 |
| 9 — أوضاع النوم وبروفايلات الطاقة | 7 | A12 (unknown-profile) + B-series pmset spot-checks below |
| 10 — BCLM عند النوم (خيار C) | 5 | Spot-checks below (sleep is not forced on test day) |
| 11 — الخروج والرجوع | 6 | A03, A06, B06, D02 |
| 12 — الأيقونات | 5 | B04, C02 |
| 13 — التحقق | 6 | A13, A14, B01, B05 |
| **Total** | **95** | |

**Section 9 spot-checks (add to Part B, between B02 and B03):**
for each profile he cares to touch — Normal, Presentation,
Stay Awake (Lid Closed), Travel, Long Day — apply it from
the menu, read `pmset -g custom`, compare against the
criteria sheet's numbers, then restore Normal. Plus one
read-only check: «9 — النوم العميق على الشاحن» — `pmset -g
custom` still shows the untouched defaults (Option B,
2026-11-16). Judges: «9 — Normal», «9 — Presentation»,
«9 — Stay Awake (Lid Closed)», «9 — Travel», «9 — Long Day»,
«9 — النوم العميق على الشاحن», «9 — بروفايل مش معروف» (A12).

**Section 10 spot-checks (no forced sleep):** verify from
the most recent natural sleep in the logs: BCLM before sleep
== BCLM after wake («10 — القاعدة», «10 — اتقفل وانت ثابت» or
«10 — اتقفل وانت بتشحن», whichever the night had);
«10 — الشحن بالغطا المقفول = قصد صريح بس» from actions.log
(the Charge-to-100% press exists or it didn't happen);
«10 — ملحوظة القايمة» — the hold-state menu shows the
lid-close garnish line on AC hold (added in Stage C; visible
in the finish-prep dumps only in hold state).

**Observe-only (the sheet's two unsourced items — recorded,
not judged):** (1) the explicit upper>lower cross-check
inside the Custom Limit dialog (ranges are code-verified;
the cross-check itself was never sourced) — watch for it
during B03's menu use and note what the dialog does with an
inverted pair; (2) SAIL_GAP=1's role during hold (reserve
value only, per context) — no action; the config read in the
execution-day refresh records it.

---

## Delivery report (produced from this catalog)

Exactly the shape in `final-retest-plan-20261116.md` §4:
verdict → what shipped (md5 table) → automated evidence
(Part A counts vs baselines, every SKIP named) → live proofs
(Part B verbatim log lines) → calibration episode (B07) →
Stage C + FR-007 record → verification verdicts (A14) →
user-eyes checklist (Part C as marked) → known limitations
stated plainly (sleep-entry BCLM = Option C status quo;
Intel/BCLM verified, other mechanisms probe-dependent; the
two parked reports + Part D09/D10 findings with their
recorded verdicts) → remaining gated steps → rollback
inventory.
