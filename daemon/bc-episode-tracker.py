#!/usr/local/bin/python3
# bc-episode-tracker.py — Battery Commander natural-use verification, v1.
#
# Episode tracker (design: natural-verification-design.md §2, §4, §9 step 1).
#
# LIVE FORM (design): this logic lives inside bc-watchdog.sh, consuming its
# native 60 s heartbeat stream, keeping .episode_open in the state dir and
# appending one JSON line per closed episode to
# ~/.battery-commander/verification/episodes.jsonl.
#
# SANDBOX FORM (this file): the identical state machines, fed offline from
# log files (watchdog heartbeat log + bc-limit daemon log + discharge.log).
# It writes NOTHING outside its --out-dir. It never touches the SMC, the
# config, or any agent; it only observes.
#
# Inputs
#   --watchdog-log   file with heartbeat lines:
#                    [YYYY-MM-DD HH:MM:SS] heartbeat: PCT=n BCLM=n cfg=U/L
#                    NCR=n EXT=Yes|No IsChg=Yes|No mode=x APG=x backend=x
#   --daemon-log     bc-limit daemon log (state lines + WRITE / WRITE OK)
#   --discharge-log  discharge monitor log ([REAL]/[SHADOW] SESSION/EPISODE)
#   --phase-c-ts     "YYYY-MM-DD HH:MM:SS" — the Phase C swap timestamp.
#                    Ticks/episodes before it are enforcer=legacy, from it
#                    on enforcer=bc-limit (honesty rule #1, design §0).
#   --sleep-sidecar  optional KEY=value .sleep_episode file (design §2e);
#                    may be repeated. Verdicts for sleep are computed by
#                    bc-verify, not here (design §9 step 2).
#   --out-dir        where episodes.jsonl + .episode_open are written.
#   --append         append to an existing episodes.jsonl (rotation applies)
#
# Verdicts are assigned at episode close, per design §3. APG ticks
# (APG != green in the heartbeat) are counted (apg_paused_ticks) and
# never fail an episode.

import argparse, json, os, re, sys
from datetime import datetime, timedelta

GAUGE_JUMP_PCT = 5          # design §2g / §3 standing constant
OVERSHOOT_GUARD = 2         # upper + 2 (guardian LAYER2 / watchdog _overshoot)
HOLD_MIN_JUDGED_S = 600     # micro-holds < 10 min are not judged (§2a)
GAP_CLOSE_S = 900           # tick gap that closes an open episode (sleep/off)
GAP_SENSOR_S = 300          # > 5 ticks missing = sensor gap (§3 discharge)
ROTATE_BYTES = 100 * 1024   # §4 rotation threshold
ROTATE_KEEP = 10            # §4 archive cap

TSFMT = "%Y-%m-%d %H:%M:%S"

def parse_ts(s):
    return datetime.strptime(s, TSFMT)

def iso(dt):
    return dt.strftime(TSFMT).replace(" ", "T") + "+02:00"

def epoch(dt):
    return int(dt.timestamp())

# ---------------------------------------------------------------- inputs

HB_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] heartbeat: "
    r"PCT=(\d+) BCLM=(\d+) cfg=(\d+)/(\d+) NCR=(\d+) EXT=(Yes|No) "
    r"IsChg=(Yes|No) mode=(\S+) APG=(\S+) backend=(\S+)")
WRITE_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] WRITE: BCLM=(\d+) \(pct=(\d+)%\)")
WRITEOK_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] WRITE OK: BCLM=(\d+) verified by read-back")
SESS_START_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[REAL\] SESSION_START_REQUESTED "
    r"target=(\d+) cur=(\d+) ext=(Yes|No)")
SESS_EP_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[REAL\] EPISODE id=(\d+) "
    r"result=(\S+) reason=(\S+) start_pct=(\d+) end_pct=(\d+) depth_pct=(\d+) "
    r"duration_s=(\d+) parked_s=(\d+)")

class Tick(object):
    __slots__ = ("ts", "pct", "bclm", "upper", "lower", "ncr", "ext",
                 "ischg", "mode", "apg", "backend", "contaminated")
    def __init__(self, m):
        self.ts = parse_ts(m.group(1))
        self.pct = int(m.group(2)); self.bclm = int(m.group(3))
        self.upper = int(m.group(4)); self.lower = int(m.group(5))
        self.ncr = int(m.group(6)); self.ext = m.group(7)
        self.ischg = m.group(8); self.mode = m.group(9)
        self.apg = m.group(10); self.backend = m.group(11)
        self.contaminated = False

def load_ticks(path):
    ticks = []
    with open(path) as f:
        for line in f:
            m = HB_RE.match(line)
            if m:
                ticks.append(Tick(m))
    ticks.sort(key=lambda t: t.ts)
    # gauge-jump contamination: the landing tick of a >=5%/tick jump
    for i in range(1, len(ticks)):
        if abs(ticks[i].pct - ticks[i - 1].pct) >= GAUGE_JUMP_PCT:
            ticks[i].contaminated = True
    return ticks

def load_writes(path):
    """Return list of dicts {ts, value, pct, ok} from the daemon log."""
    writes, pending = [], {}
    if not path:
        return writes
    with open(path) as f:
        for line in f:
            m = WRITE_RE.match(line)
            if m:
                w = {"ts": parse_ts(m.group(1)), "value": int(m.group(2)),
                     "pct": int(m.group(3)), "ok": False}
                writes.append(w); pending[(m.group(1), w["value"])] = w
                continue
            m = WRITEOK_RE.match(line)
            if m:
                w = pending.get((m.group(1), int(m.group(2))))
                if w is not None:
                    w["ok"] = True
    return writes

def load_sessions(path):
    """[REAL] discharge sessions from discharge.log: starts + episode lines."""
    starts, episodes = [], []
    if not path:
        return starts, episodes
    with open(path) as f:
        for line in f:
            m = SESS_START_RE.match(line)
            if m:
                starts.append({"ts": parse_ts(m.group(1)),
                               "target": int(m.group(2))})
                continue
            m = SESS_EP_RE.match(line)
            if m:
                episodes.append({"ts": parse_ts(m.group(1)),
                                 "result": m.group(3), "reason": m.group(4)})
    return starts, episodes

# ---------------------------------------------------------------- episodes

class Episode(object):
    def __init__(self, kind, tick, enforcer):
        self.kind = kind
        self.enforcer = enforcer
        self.start = tick.ts
        self.upper = tick.upper; self.lower = tick.lower
        self.start_pct = tick.pct
        self.ticks = 0
        self.min_pct = tick.pct; self.max_pct_raw = tick.pct
        self.pcts_clean = []            # uncontaminated pcts
        self.max_pct_clean_ts = None    # when the clean max was first hit
        self.charging_ticks = 0         # IsChg=Yes while BCLM=10 (hold)
        self.bclm_always_10 = True
        self.apg_paused_ticks = 0
        self.gauge_events = 0
        self.max_gap_s = 0
        self.last_tick = tick
        self.notes = []

    def accumulate(self, tick, prev):
        if prev is not None:
            gap = (tick.ts - prev.ts).total_seconds()
            if gap > self.max_gap_s:
                self.max_gap_s = int(gap)
        self.ticks += 1
        self.last_tick = tick
        self.min_pct = min(self.min_pct, tick.pct)
        self.max_pct_raw = max(self.max_pct_raw, tick.pct)
        if not tick.contaminated:
            if not self.pcts_clean or tick.pct > max(self.pcts_clean):
                self.max_pct_clean_ts = tick.ts
            self.pcts_clean.append(tick.pct)
        if tick.apg != "green":
            self.apg_paused_ticks += 1
        if self.kind == "hold":
            if tick.ischg == "Yes" and tick.bclm == 10:
                self.charging_ticks += 1
            if tick.bclm != 10:
                self.bclm_always_10 = False

    @property
    def max_pct_clean(self):
        return max(self.pcts_clean) if self.pcts_clean else None

    def base(self, end_tick, verdict, reason):
        end = end_tick.ts
        rec = {
            "id": "%s-%d" % (self.kind, epoch(self.start)),
            "type": self.kind,
            "enforcer": self.enforcer,
            "start_ts": iso(self.start),
            "end_ts": iso(end),
            "upper": self.upper, "lower": self.lower,
            "start_pct": self.start_pct,
            "end_pct": end_tick.pct,
            "duration_s": int((end - self.start).total_seconds()),
            "gauge_events": self.gauge_events,
            "apg_paused_ticks": self.apg_paused_ticks,
            "close_reason": reason,
            "verdict": verdict,
            "notes": list(self.notes),
        }
        return rec

def judge_hold(ep, end_tick, reason):
    dur = (end_tick.ts - ep.start).total_seconds()
    rec = ep.base(end_tick, None, reason)
    rec.update({
        "min_pct": ep.min_pct,
        "max_pct": ep.max_pct_clean,
        "max_pct_raw": ep.max_pct_raw,
        "charging_ticks": ep.charging_ticks,
        "bclm_always_10": ep.bclm_always_10,
    })
    if dur < HOLD_MIN_JUDGED_S:
        rec["verdict"] = "UNVERIFIED"; rec["notes"].append("micro")
    elif ep.charging_ticks > 0:
        rec["verdict"] = "FAIL"; rec["notes"].append("charging-during-hold")
    elif not ep.bclm_always_10:
        rec["verdict"] = "FAIL"; rec["notes"].append("bclm-left-10")
    elif ep.max_pct_clean is None:
        rec["verdict"] = "UNVERIFIED"; rec["notes"].append("all-ticks-contaminated")
    elif ep.max_pct_clean > ep.upper + OVERSHOOT_GUARD:
        # Design §3 AS AMENDED 2026-11-14 (approved by Yousef by
        # delegation): a max_pct exceedance FAILs only with evidence of
        # actual energy flow. The branches above already FAIL any
        # charging_ticks > 0 and any tick with BCLM != 10, so reaching
        # this branch with flow evidence is impossible today; the
        # explicit check states the amended rule and keeps it correct
        # if the branch order ever changes. With zero flow evidence
        # the exceedance is gauge-estimate drift: PASS, with the drift
        # (magnitude + timestamp) recorded in notes — never dropped.
        if ep.charging_ticks == 0 and ep.bclm_always_10:
            rec["verdict"] = "PASS"
            rec["notes"].append(
                "gauge-drift: max_pct=%d at %s (+%d above upper=%d; "
                "guard=%d); charging_ticks=0; bclm_always_10=true — "
                "zero-energy-flow drift, PASS per §3 amendment 2026-11-14"
                % (ep.max_pct_clean,
                   iso(ep.max_pct_clean_ts) if ep.max_pct_clean_ts else "unknown",
                   ep.max_pct_clean - ep.upper, ep.upper,
                   ep.upper + OVERSHOOT_GUARD))
        else:
            rec["verdict"] = "FAIL"; rec["notes"].append("max-pct-above-guard")
    else:
        rec["verdict"] = "PASS"
    return rec

def judge_charge(ep, end_tick, reason, writes):
    rec = ep.base(end_tick, None, reason)
    overshoot_clean = ep.max_pct_clean
    rec.update({
        "overshoot_max": overshoot_clean,
        "overshoot_raw_max": ep.max_pct_raw,
        "delta_mah": None,              # no per-tick mAh source in v1 inputs
        "ext_flip": getattr(ep, "ext_flip", False),
        "ended_in_hold": reason == "hold",
        "resume_write_seen": False,
        "hold_write_seen": False,
    })
    # write-pair cross-reference against the daemon log (design §2b)
    for w in writes:
        if w["value"] == 100 and w["ok"] and w["pct"] <= ep.lower and \
                ep.start - timedelta(seconds=300) <= w["ts"] <= ep.start + timedelta(seconds=60):
            rec["resume_write_seen"] = True
        if w["value"] == 10 and w["ok"] and \
                end_tick.ts - timedelta(seconds=300) <= w["ts"] <= end_tick.ts + timedelta(seconds=60):
            rec["hold_write_seen"] = True
    if reason == "ac-detached":
        rec["verdict"] = "FAIL" if (rec["ext_flip"] and ep.enforcer == "bc-limit") else "INTERRUPTED"
        if rec["ext_flip"] and ep.enforcer != "bc-limit":
            rec["notes"].append("ext-flip-known-legacy")
        return rec
    if reason != "hold" and reason != "full":
        rec["verdict"] = "INTERRUPTED"
        return rec
    dur = rec["duration_s"]
    if overshoot_clean is not None and overshoot_clean > ep.upper + OVERSHOOT_GUARD:
        rec["verdict"] = "FAIL"; rec["notes"].append("overshoot-above-guard")
    elif ep.max_pct_raw > ep.upper + OVERSHOOT_GUARD and \
            (overshoot_clean is None or overshoot_clean <= ep.upper + OVERSHOOT_GUARD):
        rec["verdict"] = "UNVERIFIED"; rec["notes"].append("overshoot-only-on-contaminated-ticks")
    elif dur < 180 and rec["delta_mah"] is None:
        rec["verdict"] = "UNVERIFIED"; rec["notes"].append("too-fast-mah-unknown")
    elif rec["ext_flip"]:
        rec["verdict"] = "PASS-NOTES"; rec["notes"].append("ext-flip")
    else:
        rec["verdict"] = "PASS"
    return rec

def judge_discharge(ep, end_tick, reason, sess_starts, sess_eps):
    rec = ep.base(end_tick, None, reason)
    dur_h = rec["duration_s"] / 3600.0
    rate = None
    if dur_h > 0:
        rate = round((ep.start_pct - end_tick.pct) / dur_h, 2)
    rec.update({
        "min_pct": ep.min_pct,
        "rate_pct_h": rate,
        "rate_estimated": ep.gauge_events > 0,
        "crossed_lower": ep.min_pct < ep.lower,
        "below_lower_at_end": end_tick.pct < ep.lower,
    })
    if end_tick.pct < 20:
        rec["notes"].append("deep-discharge-below-20")
    # cross-reference discharge.session records overlapping this episode
    for st in sess_starts:
        if ep.start - timedelta(seconds=180) <= st["ts"] <= end_tick.ts + timedelta(seconds=180):
            rec["notes"].append("session_target=%d" % st["target"])
            if ep.min_pct <= st["target"]:
                rec["notes"].append("session_target_reached=true")
            for se in sess_eps:
                if abs((se["ts"] - end_tick.ts).total_seconds()) <= 300:
                    rec["notes"].append("session_outcome=%s/%s" % (se["result"], se["reason"]))
    if reason in ("gap",):
        rec["verdict"] = "INTERRUPTED"; rec["notes"].append("tick-gap")
    elif ep.max_gap_s > GAP_SENSOR_S:
        rec["verdict"] = "UNVERIFIED"; rec["notes"].append("sensor-gap")
    else:
        rec["verdict"] = "PASS"     # informational: data complete (§3)
    return rec

# ---------------------------------------------------------------- tracker

def hold_cond(t):
    return t.ext == "Yes" and t.bclm == 10 and t.ischg == "No" and t.pct >= t.upper - 1

def charge_cond(t, prev):
    if t.ext != "Yes" or t.pct > t.lower:
        return False
    if t.ischg == "Yes":
        return True
    if t.bclm == 100 and prev is not None and t.pct > prev.pct:
        return True
    return False

def try_open(t, prev, enforcer):
    if t.ext == "No":
        return Episode("discharge", t, enforcer)
    if charge_cond(t, prev):
        return Episode("charge", t, enforcer)
    if hold_cond(t):
        return Episode("hold", t, enforcer)
    return None

def close_reason(ep, t, prev):
    if ep.kind == "hold":
        if t.ext == "No":
            return "ac-detached"
        if (t.upper, t.lower) != (ep.upper, ep.lower):
            return "limit-change"
        if t.pct <= ep.lower:
            return "pct-at-or-below-lower"
    elif ep.kind == "charge":
        if t.ext == "No":
            # an EXT blip that returns within 3 ticks is a flip, not a detach;
            # the flip is judged when/if EXT returns — handled by caller via
            # ep.ext_flip flag; a sustained detach closes the episode.
            return "ac-detached"
        if (t.upper, t.lower) != (ep.upper, ep.lower):
            return "limit-change"
        if t.bclm == 10 and t.ischg == "No" and t.pct >= ep.upper - 1:
            return "hold"
        if t.pct >= 100 and ep.upper >= 100:
            return "full"
    elif ep.kind == "discharge":
        if t.ext == "Yes":
            return "ac-attached"
    return None

def rotate_if_needed(out_dir):
    """Design §4: at 100 KB, archive episodes.jsonl whole; keep max 10."""
    path = os.path.join(out_dir, "episodes.jsonl")
    if os.path.exists(path) and os.path.getsize(path) >= ROTATE_BYTES:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        os.rename(path, os.path.join(out_dir, "episodes-%s.jsonl" % stamp))
    archives = sorted(f for f in os.listdir(out_dir)
                      if f.startswith("episodes-") and f.endswith(".jsonl"))
    while len(archives) > ROTATE_KEEP:
        os.remove(os.path.join(out_dir, archives.pop(0)))

def main():
    ap = argparse.ArgumentParser(prog="bc-episode-tracker")
    ap.add_argument("--watchdog-log", required=True)
    ap.add_argument("--daemon-log")
    ap.add_argument("--discharge-log")
    ap.add_argument("--phase-c-ts", required=True)
    ap.add_argument("--sleep-sidecar", action="append", default=[])
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--append", action="store_true")
    args = ap.parse_args()

    phase_c = parse_ts(args.phase_c_ts)
    ticks = load_ticks(args.watchdog_log)
    writes = load_writes(args.daemon_log)
    sess_starts, sess_eps = load_sessions(args.discharge_log)

    def enforcer_at(ts):
        return "bc-limit" if ts >= phase_c else "legacy"

    records = []
    open_ep = None
    prev = None
    last_closed_discharge = None

    def emit(rec):
        records.append(rec)

    def close_current(end_tick, reason):
        nonlocal open_ep, last_closed_discharge
        ep = open_ep
        if ep.kind == "hold":
            rec = judge_hold(ep, end_tick, reason)
        elif ep.kind == "charge":
            rec = judge_charge(ep, end_tick, reason, writes)
            # full-cycle assembly (design §2d): pair with the preceding
            # discharge that ended at/below lower-2, same enforcer.
            if reason in ("hold", "full") and last_closed_discharge is not None:
                d = last_closed_discharge
                if d["end_pct"] <= d["lower"] - 2 and d["enforcer"] == rec["enforcer"]:
                    cyc = {
                        "id": "cycle-%d" % epoch(parse_ts(rec["start_ts"].replace("T", " ").replace("+02:00", ""))),
                        "type": "cycle",
                        "enforcer": rec["enforcer"],
                        "start_ts": d["start_ts"], "end_ts": rec["end_ts"],
                        "upper": rec["upper"], "lower": rec["lower"],
                        "start_pct": d["start_pct"], "end_pct": rec["end_pct"],
                        "discharge_id": d["id"], "charge_id": rec["id"],
                        "depth_pct": d["start_pct"] - d["end_pct"],
                        "duration_s": d["duration_s"] + rec["duration_s"],
                        "total_duration_s": d["duration_s"] + rec["duration_s"],
                        "overshoot_max": rec["overshoot_max"],
                        "ext_flip": bool(d.get("ext_flip", False) or rec["ext_flip"]),
                        "gauge_events": d["gauge_events"] + rec["gauge_events"],
                        "apg_paused_ticks": d["apg_paused_ticks"] + rec["apg_paused_ticks"],
                        "close_reason": "charge-closed",
                        "verdict": None, "notes": [],
                    }
                    if rec["verdict"] == "PASS" and d["verdict"] in ("PASS", "PASS-NOTES"):
                        cyc["verdict"] = "PASS"
                    elif rec["verdict"] == "FAIL" or d["verdict"] == "FAIL":
                        cyc["verdict"] = "FAIL"
                    else:
                        cyc["verdict"] = "UNVERIFIED"
                        cyc["notes"].append("half-unverified")
                    emit(cyc)
                last_closed_discharge = None
        else:
            rec = judge_discharge(ep, end_tick, reason, sess_starts, sess_eps)
            last_closed_discharge = rec
        emit(rec)
        open_ep = None
        return rec

    for t in ticks:
        # enforcer boundary: split an open episode at the swap timestamp
        if open_ep is not None and enforcer_at(t.ts) != open_ep.enforcer:
            close_current(prev, "enforcer-change")
        # long tick gap (sleep / shutdown / telemetry hole): close at prev
        if open_ep is not None and prev is not None and \
                (t.ts - prev.ts).total_seconds() > GAP_CLOSE_S:
            close_current(prev, "gap")
        # gauge-jump event record (episode-independent, design §2g)
        if t.contaminated and prev is not None:
            records.append({
                "id": "gauge-%d" % epoch(t.ts), "type": "gauge",
                "enforcer": enforcer_at(t.ts),
                "ts": iso(t.ts), "from_pct": prev.pct, "to_pct": t.pct,
                "delta": t.pct - prev.pct,
                "context": "on-ac" if t.ext == "Yes" else "on-battery",
                "verdict": None, "notes": []})
        if open_ep is None:
            open_ep = try_open(t, prev, enforcer_at(t.ts))
            if open_ep is None:
                prev = t
                continue
            open_ep.accumulate(t, None)
            if t.contaminated:
                open_ep.gauge_events += 1
            prev = t
            continue
        # accumulate + gauge bookkeeping
        open_ep.accumulate(t, prev)
        if t.contaminated:
            open_ep.gauge_events += 1
        # config change event
        if prev is not None and (t.upper, t.lower) != (prev.upper, prev.lower):
            records.append({
                "id": "limit-change-%d" % epoch(t.ts), "type": "limit-change",
                "enforcer": enforcer_at(t.ts),
                "ts": iso(t.ts),
                "old_limits": [prev.upper, prev.lower],
                "new_limits": [t.upper, t.lower],
                "verdict": None, "notes": ["judging-is-v2"]})
        r = close_reason(open_ep, t, prev)
        if r:
            close_current(t, r)
            # a successor episode may open on the same tick (e.g. the
            # discharge at the detach tick, the hold at the charge-close tick)
            open_ep = try_open(t, prev, enforcer_at(t.ts))
            if open_ep is not None:
                open_ep.accumulate(t, None)
        prev = t

    # sleep sidecars: pass through as episode records; bc-verify judges them
    for sc in args.sleep_sidecar:
        kv = {}
        with open(sc) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    kv[k.strip()] = v.strip()
        s_ts = parse_ts(kv["SLEEP_START_TS"]); w_ts = parse_ts(kv["WAKE_TS"])
        records.append({
            "id": "sleep-%d" % epoch(s_ts), "type": "sleep",
            "enforcer": enforcer_at(s_ts),
            "start_ts": iso(s_ts), "end_ts": iso(w_ts),
            "start_pct": int(kv["SLEEP_START_PCT"]), "end_pct": int(kv["WAKE_PCT"]),
            "duration_s": int((w_ts - s_ts).total_seconds()),
            "drain_pct": float(kv["DRAIN_PCT"]), "rate_pct_h": float(kv["RATE_PCT_H"]),
            "darkwakes": int(kv["DARKWAKES"]),
            "wake_reasons": [x for x in kv.get("WAKE_REASONS", "").split(",") if x],
            "slept_normally": kv.get("SLEPT_NORMALLY", "false") == "true",
            "bc_involved": kv.get("BC_INVOLVED", "false") == "true",
            "on_ac": kv.get("ON_AC", "false") == "true",
            "external_notes": [x for x in kv.get("EXTERNAL_NOTES", "").split(",") if x],
            "data_incomplete": kv.get("DATA_INCOMPLETE", "false") == "true",
            "upper": None, "lower": None,
            "gauge_events": 0, "apg_paused_ticks": 0,
            "close_reason": "wake", "verdict": None,
            "verdict_sleep": None, "verdict_bc": None,
            "notes": ["sidecar-input"]})

    records.sort(key=lambda r: epoch(parse_ts((r.get("start_ts") or r["ts"]).replace("T", " ").replace("+02:00", ""))))

    os.makedirs(args.out_dir, exist_ok=True)
    if args.append:
        rotate_if_needed(args.out_dir)
    mode = "a" if args.append else "w"
    with open(os.path.join(args.out_dir, "episodes.jsonl"), mode) as f:
        for rec in records:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")

    open_state = {}
    if open_ep is not None:
        open_state = {"type": open_ep.kind, "enforcer": open_ep.enforcer,
                      "start_ts": iso(open_ep.start),
                      "start_pct": open_ep.start_pct,
                      "upper": open_ep.upper, "lower": open_ep.lower}
    with open(os.path.join(args.out_dir, ".episode_open"), "w") as f:
        json.dump(open_state, f, indent=1)

    for rec in records:
        if rec["type"] in ("hold", "charge", "discharge", "cycle", "sleep"):
            print("%-9s %-8s %s -> %s dur=%ss verdict=%s %s" % (
                rec["type"], rec["enforcer"],
                rec["start_ts"][11:19], rec["end_ts"][11:19],
                rec.get("duration_s"), rec["verdict"],
                " ".join(rec["notes"])))
        else:
            print("%-9s %-8s %s event" % (rec["type"], rec["enforcer"], rec["ts"][11:19]))
    if open_ep is not None:
        print("OPEN      %-8s %s since %s (not judged)" % (
            open_ep.enforcer, open_ep.kind, iso(open_ep.start)[11:19]))
    print("episodes written: %d -> %s" % (len(records), os.path.join(args.out_dir, "episodes.jsonl")))

if __name__ == "__main__":
    main()
