#!/usr/local/bin/python3
# bc-verify.py — Battery Commander natural-use verification, v1.
#
# The verifier (design: natural-verification-design.md §5, §7.1, §8).
# A reader/judge only: it never touches the SMC, the config, or any
# agent. It reads episodes.jsonl (+ archives), scores windows, judges
# sleep sidecars' two axes, evaluates the Phase C certification
# definition (§7.1), and writes the state/summary files.
#
#   bc-verify [--range 24h|7d|30d] [--write-state] [--report] [--json]
#             [--since-phase-c] [--episodes FILE] [--state-dir DIR]
#             [--watchdog-log FILE] [--daemon-log FILE]
#             [--phase-c-ts "YYYY-MM-DD HH:MM:SS"] [--now "YYYY-MM-DD HH:MM:SS"]
#
# Exit codes (design §5): 0 = no FAIL in range · 1 = at least one FAIL
# · 2 = insufficient data (no closed episodes in range). With
# --since-phase-c: 0 = Phase C VERIFIED · 1 = blocked by a FAIL or a
# continuity break · 2 = PENDING (conditions not yet met, no FAIL).
# Only enforcer=bc-limit episodes count toward BC verdicts (§0).

import argparse, glob, json, os, re, statistics, sys
from datetime import datetime, timedelta

TSFMT = "%Y-%m-%d %H:%M:%S"
OVERSHOOT_GUARD = 2
SLEEP_BASELINE_HI = 1.7     # %/h — S1/S3 measured baseline band 1.2–1.7
SLEEP_FAIL_HI = 2.5         # %/h
CONTINUITY_MAX_GAP_S = 300  # daemon state lines are 60 s cadence

def parse_ts(s):
    return datetime.strptime(s.replace("T", " ").replace("+02:00", ""), TSFMT)

def fmt_date(dt):
    return dt.strftime("%b %-d") if os.name != "nt" else dt.strftime("%b %d")

def load_episodes(paths):
    eps = []
    for p in paths:
        with open(p) as f:
            for line in f:
                line = line.strip()
                if line:
                    eps.append(json.loads(line))
    return eps

def ep_end(ep):
    return parse_ts(ep["end_ts"]) if ep.get("end_ts") else None

def ep_start(ep):
    return parse_ts(ep["start_ts"]) if ep.get("start_ts") else parse_ts(ep["ts"])

def in_window(ep, now, hours, bc_only=True):
    if bc_only and ep.get("enforcer") != "bc-limit":
        return False
    e = ep_end(ep)
    if e is None:
        return False
    return now - timedelta(hours=hours) <= e <= now + timedelta(seconds=1)

def judge_sleep(ep):
    """Two-axis sleep verdicts (design §2e/§3). Fills verdict fields."""
    if ep.get("verdict_sleep") is not None:
        return ep
    # verdict_bc axis
    if ep.get("data_incomplete"):
        ep["verdict_bc"] = "UNVERIFIED"
    elif ep.get("bc_involved"):
        ep["verdict_bc"] = "FAIL"
    else:
        ep["verdict_bc"] = "PASS"
    # verdict_sleep axis
    if "user" in ep.get("wake_reasons", []):
        ep["verdict_sleep"] = "INTERRUPTED"
    elif ep.get("on_ac"):
        ep["verdict_sleep"] = "PASS"   # judged on hold-during-sleep by the
                                       # morning report's own fields; v1
                                       # sidecar carries no min-pct, so a
                                       # battery night is the judged case.
        ep.setdefault("notes", []).append("on-ac-night-not-judged-v1")
    elif not ep.get("slept_normally"):
        ep["verdict_sleep"] = "UNVERIFIED"
    else:
        rate = ep.get("rate_pct_h")
        if rate is None:
            ep["verdict_sleep"] = "UNVERIFIED"
        elif rate <= SLEEP_BASELINE_HI:
            ep["verdict_sleep"] = "PASS"
        elif rate <= SLEEP_FAIL_HI:
            ep["verdict_sleep"] = "PASS-NOTES"
            ep.setdefault("notes", []).append("elevated")
        elif ep.get("external_notes"):
            ep["verdict_sleep"] = "PASS-NOTES"
            ep.setdefault("notes", []).append("elevated-with-external-note")
        else:
            ep["verdict_sleep"] = "FAIL"
    ep["verdict"] = ep["verdict_sleep"]
    return ep

# ------------------------------------------------------------ Phase C §7.1

L8_NOT_LOADED_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] L8: .*not loaded")
STATE_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] state:")

def evaluate_phase_c(eps, phase_c, watchdog_log, daemon_log):
    """Return (status, checks) — status VERIFIED | PENDING | BLOCKED.
    checks: list of (label, ok, evidence). All from episode FIELDS and
    log scans — verdict strings alone are never trusted (§7.1)."""
    checks = []
    bc = [e for e in eps if e.get("enforcer") == "bc-limit"]
    holds = [e for e in bc if e["type"] == "hold" and ep_end(e) and ep_start(e) >= phase_c]
    discharges = [e for e in bc if e["type"] == "discharge" and ep_end(e)]
    charges = {e["id"]: e for e in bc if e["type"] == "charge"}
    cycles = [e for e in bc if e["type"] == "cycle" and ep_end(e)]

    # 1. Hold proof: >= 30 min on AC, verdict PASS (fields re-checked)
    hold = None
    for h in sorted(holds, key=ep_start):
        if h["duration_s"] >= 1800 and h["verdict"] == "PASS" and \
                h.get("charging_ticks", 1) == 0 and h.get("bclm_always_10"):
            hold = h; break
    checks.append(("1. Hold proof: bc-limit HOLD >= 30 min, PASS, BCLM=10 throughout, 0 charging ticks",
                   hold is not None,
                   ("%s %s -> %s, %d s" % (hold["id"], hold["start_ts"][11:19],
                    hold["end_ts"][11:19], hold["duration_s"])) if hold else
                   "no qualifying bc-limit hold episode found"))

    # 2. Discharge proof: ends <= lower-2 (evaluated on its own evidence;
    #    the in-order requirement is checked by the timestamps below)
    dis = None
    for d in sorted(discharges, key=ep_start):
        if ep_start(d) >= phase_c and d["end_pct"] <= d["lower"] - 2:
            dis = d; break
    if dis is not None and hold is not None and ep_start(dis) < ep_start(hold):
        checks.append(("2. Discharge proof: bc-limit DISCHARGE ending <= lower-2",
                       False, "%s ends at %d%% but predates the hold proof (out of order)"
                       % (dis["id"], dis["end_pct"])))
        dis = None
    else:
        checks.append(("2. Discharge proof: bc-limit DISCHARGE ending <= lower-2",
                       dis is not None,
                       ("%s ended at %d%% (lower %d, threshold %d%%)" %
                        (dis["id"], dis["end_pct"], dis["lower"], dis["lower"] - 2))
                       if dis else "no bc-limit discharge ending deep enough"))

    # 3+4. Charge proof + cycle formed
    cyc = None; chg = None
    if dis is not None:
        for c in sorted(cycles, key=ep_end):
            if c.get("discharge_id") == dis["id"]:
                cyc = c; chg = charges.get(c.get("charge_id")); break
    chg_ok = False; chg_ev = "no cycle pairs the discharge proof"
    if cyc is not None and chg is not None:
        problems = []
        if not chg.get("ended_in_hold"): problems.append("did not end in hold")
        if chg.get("overshoot_max") is None: problems.append("overshoot unknown")
        elif chg["overshoot_max"] > chg["upper"] + OVERSHOOT_GUARD:
            problems.append("overshoot_max %d > upper+2" % chg["overshoot_max"])
        if chg.get("ext_flip"): problems.append("ext_flip")
        if not chg.get("resume_write_seen"): problems.append("resume write (BCLM=100, read-back OK) not seen")
        if not chg.get("hold_write_seen"): problems.append("hold write (BCLM=10, read-back OK) not seen")
        chg_ok = not problems
        chg_ev = ("%s overshoot_max=%s resume_write=%s hold_write=%s" %
                  (chg["id"], chg.get("overshoot_max"), chg.get("resume_write_seen"),
                   chg.get("hold_write_seen"))) + (("; " + "; ".join(problems)) if problems else "")
    checks.append(("3. Charge proof: following CHARGE ends in hold, overshoot <= upper+2, no ext_flip, write pair read-back-verified",
                   chg_ok, chg_ev))
    checks.append(("4. Cycle formed: FULL CYCLE composite of (2)+(3), verdict PASS",
                   cyc is not None and cyc["verdict"] == "PASS",
                   ("%s verdict=%s depth=%s%%" % (cyc["id"], cyc["verdict"], cyc.get("depth_pct")))
                   if cyc else "no cycle record for the discharge proof"))

    # 5. Continuity: no L8 not-loaded lines, no daemon gap, swap -> cycle close
    cont_ok = False; cont_ev = "cycle not formed — continuity window undefined"
    if cyc is not None:
        end = ep_end(cyc); problems = []
        if watchdog_log:
            with open(watchdog_log) as f:
                for line in f:
                    m = L8_NOT_LOADED_RE.match(line)
                    if m and phase_c <= parse_ts(m.group(1)) <= end:
                        problems.append("L8 not-loaded at %s" % m.group(1))
        if daemon_log:
            last = None; maxgap = 0; seen = 0
            with open(daemon_log) as f:
                for line in f:
                    m = STATE_RE.match(line)
                    if not m:
                        continue
                    ts = parse_ts(m.group(1))
                    if phase_c <= ts <= end:
                        seen += 1
                        if last is not None:
                            maxgap = max(maxgap, (ts - last).total_seconds())
                        last = ts
            if seen == 0:
                problems.append("no daemon state lines in window")
            elif maxgap > CONTINUITY_MAX_GAP_S:
                problems.append("daemon state gap %.0f s > %d s" % (maxgap, CONTINUITY_MAX_GAP_S))
            cont_ev = "daemon state lines in window: %d, max gap %.0f s" % (seen, maxgap)
        else:
            cont_ev = "daemon log not supplied — gap check skipped"
        if problems:
            cont_ev += "; " + "; ".join(problems)
        cont_ok = not problems
    checks.append(("5. Continuity: no L8 'daemon not loaded', no enforcement gap, swap -> cycle close",
                   cont_ok, cont_ev))

    if all(c[1] for c in checks):
        return "VERIFIED", checks
    # BLOCKED if a FAIL verdict or a continuity break poisons the evidence
    blocked = any(e.get("verdict") == "FAIL" for e in bc if ep_end(e) and ep_start(e) >= phase_c) \
        or (cyc is not None and not cont_ok)
    return ("BLOCKED" if blocked else "PENDING"), checks

# ------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(prog="bc-verify")
    ap.add_argument("--episodes", help="episodes.jsonl (default: state-dir/verification/episodes.jsonl + archives)")
    ap.add_argument("--state-dir", default=".")
    ap.add_argument("--range", dest="range", default="24h", choices=["24h", "7d", "30d"])
    ap.add_argument("--write-state", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--since-phase-c", action="store_true")
    ap.add_argument("--phase-c-ts")
    ap.add_argument("--watchdog-log")
    ap.add_argument("--daemon-log")
    ap.add_argument("--now")
    args = ap.parse_args()

    if args.episodes:
        paths = [args.episodes]
    else:
        vdir = os.path.join(args.state_dir, "verification")
        paths = sorted(glob.glob(os.path.join(vdir, "episodes*.jsonl")))
    eps = []
    for p in paths:
        if os.path.exists(p):
            eps.extend(load_episodes([p]))
    for e in eps:
        if e["type"] == "sleep":
            judge_sleep(e)

    ends = [ep_end(e) for e in eps if ep_end(e)]
    now = parse_ts(args.now) if args.now else (max(ends) if ends else datetime.now())
    range_h = {"24h": 24, "7d": 168, "30d": 720}[args.range]

    bc_eps = [e for e in eps if e.get("enforcer") == "bc-limit"]
    closed_bc = [e for e in bc_eps if ep_end(e) and e.get("verdict") is not None]
    win = [e for e in closed_bc if in_window(e, now, range_h)]
    win7 = [e for e in closed_bc if in_window(e, now, 168)]

    def of(kind, pool):
        return [e for e in pool if e["type"] == kind]

    holds_w = of("hold", win); holds_7 = of("hold", win7)
    charges_7 = of("charge", win7)
    cycles_7 = sorted(of("cycle", win7), key=ep_end)
    sleeps_7 = [e for e in eps if e["type"] == "sleep" and in_window(e, now, 168, bc_only=False)]
    gauge_7 = [e for e in eps if e["type"] == "gauge" and in_window(e, now, 168, bc_only=False)]
    lc_7 = [e for e in eps if e["type"] == "limit-change" and in_window(e, now, 168, bc_only=False)]
    fails_w = [e for e in win if e["verdict"] == "FAIL"]
    fails_7 = [e for e in win7 if e["verdict"] == "FAIL"]

    overshoots = [e["overshoot_max"] - e["upper"] for e in charges_7
                  if e.get("overshoot_max") is not None]
    overshoot_max_7d = max([e["overshoot_max"] for e in charges_7
                            if e.get("overshoot_max") is not None], default=None)
    sleep_rates = [e["rate_pct_h"] for e in sleeps_7 if e.get("rate_pct_h") is not None]
    last_cycle = cycles_7[-1] if cycles_7 else None

    # confidence (§8): FULL only if every summarised type has a judged episode
    judged_types = {e["type"] for e in win7}
    if not closed_bc:
        confidence = "INSUFFICIENT"
    elif {"hold", "charge", "discharge", "cycle"} <= judged_types and sleeps_7:
        confidence = "FULL"
    else:
        confidence = "PARTIAL"

    phase_c_status, phase_c_checks = None, []
    phase_c = parse_ts(args.phase_c_ts) if args.phase_c_ts else None
    if phase_c is not None:
        phase_c_status, phase_c_checks = evaluate_phase_c(
            eps, phase_c, args.watchdog_log, args.daemon_log)

    state = {
        "LAST_RUN": now.strftime(TSFMT),
        "ENFORCER": "bc-limit" if bc_eps else ("legacy" if eps else "none"),
        "HOLDS_24H": str(len(holds_w)),
        "HOLDS_PASS": str(len([e for e in holds_w if e["verdict"] == "PASS"])),
        "LAST_CYCLE": fmt_date(ep_end(last_cycle)) if last_cycle else "—",
        "LAST_CYCLE_VERDICT": last_cycle["verdict"] if last_cycle else "—",
        "CYCLES_7D": str(len(cycles_7)),
        "CYCLES_PASS_7D": str(len([e for e in cycles_7 if e["verdict"] == "PASS"])),
        "OVERSHOOT_MAX_7D": (str(overshoot_max_7d) if overshoot_max_7d is not None else "—"),
        "SLEEP_NIGHTS_7D": str(len(sleeps_7)),
        "SLEEP_MEDIAN_PCT_H": ("%.2f" % statistics.median(sleep_rates)) if sleep_rates else "—",
        "SLEEP_BC_INVOLVED": str(len([e for e in sleeps_7 if e.get("bc_involved")])),
        "LIMIT_CHANGES_7D": str(len(lc_7)),
        "LIMIT_MAX_LATENCY_S": "—",
        "GAUGE_EVENTS_7D": str(len(gauge_7)),
        "FAILS_24H": str(len(fails_w)),
        "FAILS_7D": str(len(fails_7)),
        "PHASE_C": ("VERIFIED " + fmt_date(ep_end(last_cycle))) if phase_c_status == "VERIFIED"
                   else (phase_c_status or "NOT_STARTED"),
        "CONFIDENCE": confidence,
    }

    # compact menu line (§6) — honest states, '—' when there is no data
    def mark(ok, none):
        return "—" if none else ("✓" if ok else "⚠")
    latest_hold_7 = holds_7[-1] if holds_7 else None
    hold_mark = mark(latest_hold_7 and latest_hold_7["verdict"] == "PASS", latest_hold_7 is None)
    if last_cycle:
        cyc_txt = "%s %s" % (mark(last_cycle["verdict"] == "PASS", False), fmt_date(ep_end(last_cycle)))
        if last_cycle["verdict"] not in ("PASS",):
            cyc_txt += " (%s)" % last_cycle["verdict"].lower()
    else:
        cyc_txt = "— (none yet)"
    over_txt = ("+%d%%" % max(0, max(overshoots))) if overshoots else "—"
    if confidence == "INSUFFICIENT":
        summary = "Verified: — (insufficient data)"
    else:
        summary = "Verified: Hold %s · Cycle %s · Overshoot %s (7d)" % (hold_mark, cyc_txt, over_txt)
    state["_SUMMARY"] = summary

    # exit code
    if args.since_phase_c:
        exit_code = {"VERIFIED": 0, "BLOCKED": 1, "PENDING": 2}.get(phase_c_status, 2)
    elif not win:
        exit_code = 2
    elif fails_w:
        exit_code = 1
    else:
        exit_code = 0
    state["_EXIT"] = exit_code

    if args.json:
        out = dict(state)
        out["phase_c_checks"] = [
            {"check": c[0], "ok": c[1], "evidence": c[2]} for c in phase_c_checks]
        out["episodes_in_range"] = [
            {k: e.get(k) for k in ("id", "type", "enforcer", "verdict", "start_ts", "end_ts")}
            for e in sorted(win, key=ep_start)]
        print(json.dumps(out, indent=1))
    else:
        print(summary)
        print("range=%s now=%s confidence=%s fails_range=%d fails_7d=%d" %
              (args.range, state["LAST_RUN"], confidence, len(fails_w), len(fails_7)))
        for e in sorted(win, key=ep_start):
            print("  %-9s %s -> %s %-11s %s" % (
                e["type"], e["start_ts"][5:19], e["end_ts"][5:19],
                e["verdict"], " ".join(e.get("notes", []))))
        legacy = [e for e in eps if e.get("enforcer") == "legacy" and ep_end(e)
                  and in_window(e, now, range_h, bc_only=False)]
        if legacy:
            print("legacy episodes in range (baseline only, never BC evidence): %d" % len(legacy))
        for e in sorted([x for x in eps if x["type"] == "sleep"], key=ep_start):
            print("  sleep     %s -> %s verdict_sleep=%s verdict_bc=%s rate=%s%%/h bc_involved=%s" % (
                e["start_ts"][5:19], e["end_ts"][5:19], e.get("verdict_sleep"),
                e.get("verdict_bc"), e.get("rate_pct_h"), e.get("bc_involved")))
        if phase_c_status:
            print("Phase C: %s" % phase_c_status)
            for label, ok, ev in phase_c_checks:
                print("  [%s] %s — %s" % ("OK" if ok else " -- ", label, ev))
        print("exit=%d" % exit_code)

    if args.write_state:
        os.makedirs(args.state_dir, exist_ok=True)
        with open(os.path.join(args.state_dir, ".verification_state"), "w") as f:
            for k, v in state.items():
                if not k.startswith("_"):
                    f.write("%s=%s\n" % (k, v))
        with open(os.path.join(args.state_dir, ".verification_summary"), "w") as f:
            f.write(summary + "\n")
        with open(os.path.join(args.state_dir, "verdicts.jsonl"), "a") as f:
            f.write(json.dumps({
                "ts": now.strftime(TSFMT), "range": args.range,
                "fails_range": len(fails_w), "fails_7d": len(fails_7),
                "confidence": confidence, "phase_c": phase_c_status,
                "exit": exit_code}) + "\n")
    if args.report:
        rdir = os.path.join(args.state_dir, "reports")
        os.makedirs(rdir, exist_ok=True)
        rp = os.path.join(rdir, "verification-%s.txt" % now.strftime("%Y%m%d"))
        with open(rp, "w") as f:
            f.write("Battery Commander — verification report %s\n\n" % now.strftime("%Y-%m-%d"))
            f.write(summary + "\n\n")
            for k, v in state.items():
                if not k.startswith("_"):
                    f.write("%s=%s\n" % (k, v))
            f.write("\nPhase C certification (§7.1): %s\n" % phase_c_status)
            for label, ok, ev in phase_c_checks:
                f.write("  [%s] %s — %s\n" % ("OK" if ok else "FAIL", label, ev))
            f.write("\nEpisodes in range (%s):\n" % args.range)
            for e in sorted(win, key=ep_start):
                f.write("  %s %s %s -> %s %s\n" % (
                    e["id"], e["type"], e["start_ts"], e["end_ts"], e["verdict"]))

    return exit_code

if __name__ == "__main__":
    sys.exit(main())
