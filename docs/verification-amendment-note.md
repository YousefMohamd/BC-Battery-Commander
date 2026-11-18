# §3 Amendment Applied (Sandbox) — Phase C Certification Verdict

Date: 2026-11-14. Approved by Yousef by delegation (~18:23 EET):
"طلاما تقنيا صح وهيأدي لغرضي اعتمد الحل بتاعك" — adopt the recommended
solution. **Sandbox only — nothing deployed, nothing live touched.**

## Headline

**§7.1 Phase C certification: PHASE_C = VERIFIED** (was BLOCKED).
All five conditions OK on the 2026-11-13 data; `bc-verify` exit
code 0 in both default and `--since-phase-c` modes (was 1 / 1).

## The amendment

Design §3 (HOLD): a hold episode whose `max_pct` exceeds upper+2
FAILs on that ground **only with evidence of actual energy flow**
(charging ticks > 0, or any tick with BCLM ≠ 10 — both already FAIL
independently). A zero-flow exceedance is gauge-estimate drift:
the episode PASSes with the drift recorded in `notes[]`
(`gauge-drift`: magnitude above upper + timestamp of the clean
maximum) — never silently dropped. Real overshoots still FAIL
exactly as before.

## What changed in code

`bc-episode-tracker.py` (repo `battopt-project/bc-build/`) — the §3
hold scoring lives in the tracker's `judge_hold` (verdicts are
assigned at episode close); **`bc-verify.py` needed no change and
is byte-identical** (md5 `b4125e315d5b9a033ac2b01c7cf6b731`). It
consumes verdict + fields, and its §7.1 condition 1 already
re-checks `charging_ticks == 0` and `bclm_always_10` from fields.

Three hunks, nothing else (verified by diff against the pristine
source):

1. **L151** — `Episode.__init__`: new attribute
   `self.max_pct_clean_ts = None` (when the clean max was first hit).
2. **L170–171** — `Episode.accumulate`: set `max_pct_clean_ts` when
   an uncontaminated tick raises the clean maximum. (Minimal field
   addition so the drift note can carry the required timestamp.)
3. **L223–244** — `judge_hold`, the `max_pct_clean > upper +
   OVERSHOOT_GUARD` branch: if `charging_ticks == 0 and
   bclm_always_10` → verdict **PASS** + `gauge-drift` note
   (max_pct, timestamp, +N above upper, guard value); else the
   original FAIL `max-pct-above-guard`. All other branches and all
   other judges are byte-identical in behaviour.

Tracker md5: `401234f60452a279e9cb8bca4bed7341` →
`e18f08fc97ee1bfa7bf840823dd1fd4d`. Pristine source kept as
`bc-episode-tracker.py.pre-amendment-20261114` in the same folder.

## Design doc

`natural-verification-design.md` §3: dated amendment paragraph
appended at the end of §3 (after the "Notes on specific criteria"),
stating the new rule, the rationale (the 2026-11-13 hold: BCLM = 10
and zero charging ticks on all 294 ticks while the gauge stepped
+3 to 89 at zero current, 19:13:23), and the implementation pointer.
Both copies (Mac repo + `~/workspace/bc-build/`) are md5-identical:
`7c9e6e266a7f1d1241549ba9f7445a8e` → `22645c1ed18420d355d192fe6bb80b9f`.
Pre-amendment copy kept as
`natural-verification-design.md.pre-amendment-20261114` (Mac repo).

## Re-run on the sandbox data (2026-11-13 logs)

Pipeline re-run in place (`verify-sandbox/out-pre-amendment-20261114/`
holds the pre-amendment outputs for comparison).

**Hold episode (bc-limit, 17:34:54 → 22:29:55, 17,701 s):**
- Before: **FAIL** — `max-pct-above-guard` (max_pct 89 > 88).
- After: **PASS** — notes: `gauge-drift: max_pct=89 at
  2026-11-13T19:13:23+02:00 (+3 above upper=86; guard=88);
  charging_ticks=0; bclm_always_10=true — zero-energy-flow drift,
  PASS per §3 amendment 2026-11-14`.
- Every other episode verdict unchanged (legacy hold PASS;
  discharge PASS with `session_outcome=ended/superseded` carried
  verbatim; charge PASS; cycle PASS; post-charge hold still OPEN,
  unjudged).

**§7.1 evaluation (all from episode fields + log scans):**
```
[ OK ] 1. Hold proof — hold-1794584094 17:34:54 -> 22:29:55, 17701 s,
         PASS, BCLM=10 throughout, 0 charging ticks
[ OK ] 2. Discharge proof — discharge-1794601795 ended at 79%
         (lower 85, threshold 83%)
[ OK ] 3. Charge proof — charge-1794602520 overshoot_max=86,
         resume_write=True, hold_write=True (read-back verified)
[ OK ] 4. Cycle formed — cycle-1794602520 verdict=PASS, depth=9%
[ OK ] 5. Continuity — 318 daemon state lines swap -> cycle close,
         max gap 65 s; no L8 "not loaded" lines
=> PHASE_C = VERIFIED
```

**Summary line:** `Verified: Hold ✓ · Cycle ✓ Nov 13 · Overshoot +0% (7d)`
(was `Hold ⚠`). State: `PHASE_C=VERIFIED Nov 13`, `FAILS_24H=0`,
`FAILS_7D=0` (was 1/1), `CONFIDENCE=FULL`. Exit codes: default 0
(was 1), `--since-phase-c` 0 (was 1).

## Synthetic guard — real overshoots still FAIL

Scratch test in `verify-sandbox/guard-test/` (real sandbox data
untouched): a synthetic 35-min hold (2026-11-15, clearly synthetic)
with **real charging** — 25 ticks of `IsChg=Yes` at BCLM=10 while
PCT climbs 86 → 90 (max_pct 90 > guard 88). Amended tracker
verdict: **FAIL — `charging-during-hold`**, `charging_ticks=25`.
The amendment does not weaken any real-overshoot FAIL.

## Hard-limit compliance

Sandbox + docs only. No writes to `~/.battery-commander/` (the
verification dir still does not exist there), no deploys, no
chmod of anything live, no SMC, no sudo, no launchctl changes.
Deployment of the verification system remains the separate 6-step
gated sequence in the sandbox build note — this amendment simply
means step 6's decision is now taken, and the deployed system will
score Phase C VERIFIED from day one.
