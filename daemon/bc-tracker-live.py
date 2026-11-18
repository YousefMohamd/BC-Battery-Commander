#!/usr/local/bin/python3
# bc-tracker-live.py — Battery Commander natural-use verification, v1
# LIVE driver (design: natural-verification-design.md §2, §4, §9 step 1;
# deployment 2026-11-14).
#
# The design's live form has the episode tracker consuming the
# watchdog's 60 s heartbeat stream from inside the watchdog tick. The
# state machines and judging rules are NOT re-implemented here: this
# driver imports bc-episode-tracker.py (the sandbox-proven module,
# including the 2026-11-14 §3 gauge-drift amendment) and feeds it the
# watchdog's heartbeat ticks incrementally, persisting its progress
# in verification/.tracker_state.json so each invocation resumes
# exactly where the previous one stopped. The per-tick processing
# glue below replicates the batch tracker's main loop step-for-step;
# the equivalence is proven by replaying the sandbox log tick-by-tick
# through this driver and diffing the emitted episodes against the
# batch run (verification-deployment-note.md).
#
# Invoked at the end of every watchdog tick (bc-watchdog.sh, wrapped
# so it can never fail the tick) and once at the head of every
# bc-verify-run.sh run (so verify_now scores fresh data). It appends
# one JSON line per closed episode/event to
# verification/episodes.jsonl (§4 rotation applies), maintains
# .episode_open in the state dir, and ingests the morning report's
# .sleep_episode sidecar when a new one appears. Observe-and-score
# only: it never touches the SMC, the config, or any agent.

import argparse, importlib.util, json, os, sys
from datetime import datetime

TSFMT = "%Y-%m-%d %H:%M:%S"


def load_tracker_module(path):
    spec = importlib.util.spec_from_file_location("bc_episode_tracker", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ------------------------------------------------------------ state I/O

def _dt(s):
    return datetime.strptime(s, TSFMT) if s else None


def _ts(dt):
    return dt.strftime(TSFMT) if dt else None


def tick_to_dict(t):
    if t is None:
        return None
    return {"ts": _ts(t.ts), "pct": t.pct, "bclm": t.bclm,
            "upper": t.upper, "lower": t.lower, "ncr": t.ncr,
            "ext": t.ext, "ischg": t.ischg, "mode": t.mode,
            "apg": t.apg, "backend": t.backend,
            "contaminated": t.contaminated}


def tick_from_dict(mod, d):
    if d is None:
        return None
    t = mod.Tick.__new__(mod.Tick)
    t.ts = _dt(d["ts"]); t.pct = d["pct"]; t.bclm = d["bclm"]
    t.upper = d["upper"]; t.lower = d["lower"]; t.ncr = d["ncr"]
    t.ext = d["ext"]; t.ischg = d["ischg"]; t.mode = d["mode"]
    t.apg = d["apg"]; t.backend = d["backend"]
    t.contaminated = d["contaminated"]
    return t


def ep_to_dict(ep):
    if ep is None:
        return None
    return {"kind": ep.kind, "enforcer": ep.enforcer,
            "start": _ts(ep.start), "upper": ep.upper, "lower": ep.lower,
            "start_pct": ep.start_pct, "ticks": ep.ticks,
            "min_pct": ep.min_pct, "max_pct_raw": ep.max_pct_raw,
            "pcts_clean": list(ep.pcts_clean),
            "max_pct_clean_ts": _ts(ep.max_pct_clean_ts),
            "charging_ticks": ep.charging_ticks,
            "bclm_always_10": ep.bclm_always_10,
            "apg_paused_ticks": ep.apg_paused_ticks,
            "gauge_events": ep.gauge_events, "max_gap_s": ep.max_gap_s,
            "notes": list(ep.notes),
            "ext_flip": getattr(ep, "ext_flip", False)}


def ep_from_dict(mod, d):
    if d is None:
        return None
    ep = mod.Episode.__new__(mod.Episode)
    ep.kind = d["kind"]; ep.enforcer = d["enforcer"]
    ep.start = _dt(d["start"]); ep.upper = d["upper"]; ep.lower = d["lower"]
    ep.start_pct = d["start_pct"]; ep.ticks = d["ticks"]
    ep.min_pct = d["min_pct"]; ep.max_pct_raw = d["max_pct_raw"]
    ep.pcts_clean = list(d["pcts_clean"])
    ep.max_pct_clean_ts = _dt(d["max_pct_clean_ts"])
    ep.charging_ticks = d["charging_ticks"]
    ep.bclm_always_10 = d["bclm_always_10"]
    ep.apg_paused_ticks = d["apg_paused_ticks"]
    ep.gauge_events = d["gauge_events"]; ep.max_gap_s = d["max_gap_s"]
    ep.notes = list(d["notes"]); ep.ext_flip = d["ext_flip"]
    ep.last_tick = None      # re-seeded from prev_tick by the driver
    return ep


class LiveTracker(object):
    """The batch tracker's main loop, made resumable. Judging is done
    exclusively by the imported module's judge_* functions."""

    def __init__(self, mod, phase_c, writes, sess_starts, sess_eps, emit):
        self.mod = mod
        self.phase_c = phase_c
        self.writes = writes
        self.sess_starts = sess_starts
        self.sess_eps = sess_eps
        self.emit = emit                # callable(record dict)
        self.open_ep = None
        self.prev = None
        self.last_closed_discharge = None

    def enforcer_at(self, ts):
        return "bc-limit" if ts >= self.phase_c else "legacy"

    def close_current(self, end_tick, reason):
        mod = self.mod
        ep = self.open_ep
        if ep.kind == "hold":
            rec = mod.judge_hold(ep, end_tick, reason)
        elif ep.kind == "charge":
            rec = mod.judge_charge(ep, end_tick, reason, self.writes)
            if reason in ("hold", "full") and self.last_closed_discharge is not None:
                d = self.last_closed_discharge
                if d["end_pct"] <= d["lower"] - 2 and d["enforcer"] == rec["enforcer"]:
                    cyc = {
                        "id": "cycle-%d" % mod.epoch(mod.parse_ts(
                            rec["start_ts"].replace("T", " ").replace("+02:00", ""))),
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
                    self.emit(cyc)
                self.last_closed_discharge = None
        else:
            rec = mod.judge_discharge(ep, end_tick, reason,
                                      self.sess_starts, self.sess_eps)
            self.last_closed_discharge = rec
        self.emit(rec)
        self.open_ep = None
        return rec

    def process(self, t):
        mod = self.mod
        # enforcer boundary: split an open episode at the swap timestamp
        if self.open_ep is not None and self.enforcer_at(t.ts) != self.open_ep.enforcer:
            self.close_current(self.prev, "enforcer-change")
        # long tick gap (sleep / shutdown / telemetry hole): close at prev
        if self.open_ep is not None and self.prev is not None and \
                (t.ts - self.prev.ts).total_seconds() > mod.GAP_CLOSE_S:
            self.close_current(self.prev, "gap")
        # gauge-jump event record (episode-independent, design §2g)
        if t.contaminated and self.prev is not None:
            self.emit({
                "id": "gauge-%d" % mod.epoch(t.ts), "type": "gauge",
                "enforcer": self.enforcer_at(t.ts),
                "ts": mod.iso(t.ts), "from_pct": self.prev.pct,
                "to_pct": t.pct, "delta": t.pct - self.prev.pct,
                "context": "on-ac" if t.ext == "Yes" else "on-battery",
                "verdict": None, "notes": []})
        if self.open_ep is None:
            self.open_ep = mod.try_open(t, self.prev, self.enforcer_at(t.ts))
            if self.open_ep is None:
                self.prev = t
                return
            self.open_ep.accumulate(t, None)
            if t.contaminated:
                self.open_ep.gauge_events += 1
            self.prev = t
            return
        # accumulate + gauge bookkeeping
        self.open_ep.accumulate(t, self.prev)
        if t.contaminated:
            self.open_ep.gauge_events += 1
        # config change event
        if self.prev is not None and (t.upper, t.lower) != (self.prev.upper, self.prev.lower):
            self.emit({
                "id": "limit-change-%d" % mod.epoch(t.ts),
                "type": "limit-change",
                "enforcer": self.enforcer_at(t.ts),
                "ts": mod.iso(t.ts),
                "old_limits": [self.prev.upper, self.prev.lower],
                "new_limits": [t.upper, t.lower],
                "verdict": None, "notes": ["judging-is-v2"]})
        r = mod.close_reason(self.open_ep, t, self.prev)
        if r:
            self.close_current(t, r)
            # a successor episode may open on the same tick
            self.open_ep = mod.try_open(t, self.prev, self.enforcer_at(t.ts))
            if self.open_ep is not None:
                self.open_ep.accumulate(t, None)
        self.prev = t


def sidecar_record(mod, path, phase_c):
    """Convert a .sleep_episode sidecar into an episode record, exactly
    as the batch tracker's pass-through does (bc-verify judges it)."""
    kv = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                kv[k.strip()] = v.strip()
    s_ts = mod.parse_ts(kv["SLEEP_START_TS"])
    w_ts = mod.parse_ts(kv["WAKE_TS"])
    enforcer = "bc-limit" if s_ts >= phase_c else "legacy"
    return {
        "id": "sleep-%d" % mod.epoch(s_ts), "type": "sleep",
        "enforcer": enforcer,
        "start_ts": mod.iso(s_ts), "end_ts": mod.iso(w_ts),
        "start_pct": int(kv["SLEEP_START_PCT"]),
        "end_pct": int(kv["WAKE_PCT"]),
        "duration_s": int((w_ts - s_ts).total_seconds()),
        "drain_pct": float(kv["DRAIN_PCT"]),
        "rate_pct_h": float(kv["RATE_PCT_H"]),
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
        "notes": ["sidecar-input"]}


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(prog="bc-tracker-live")
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--watchdog-log", required=True)
    ap.add_argument("--daemon-log")
    ap.add_argument("--discharge-log")
    ap.add_argument("--phase-c-ts", required=True)
    ap.add_argument("--tracker-py", required=True,
                    help="path to bc-episode-tracker.py (imported, unmodified)")
    args = ap.parse_args()

    mod = load_tracker_module(args.tracker_py)
    phase_c = mod.parse_ts(args.phase_c_ts)
    state_dir = args.state_dir
    vdir = os.path.join(state_dir, "verification")
    os.makedirs(vdir, exist_ok=True)
    state_path = os.path.join(vdir, ".tracker_state.json")
    episodes_path = os.path.join(vdir, "episodes.jsonl")
    lock_path = os.path.join(vdir, ".tracker.lock")

    # single-instance lock (a watchdog tick and a verify_now run may
    # collide); a lock older than 180 s is stale and is stolen.
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
    except FileExistsError:
        try:
            age = datetime.now().timestamp() - os.path.getmtime(lock_path)
        except OSError:
            age = 0
        if age < 180:
            return 0                    # another run is active; skip
        try:
            os.remove(lock_path)
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
        except OSError:
            return 0

    try:
        state = {}
        if os.path.exists(state_path):
            try:
                with open(state_path) as f:
                    state = json.load(f)
            except (ValueError, OSError):
                state = {}              # corrupt state: restart cleanly;
                                        # episodes.jsonl dedup still applies

        # ids already on disk (crash-safe dedup: a run that appended but
        # died before saving state re-processes its ticks and must not
        # re-append the same episodes)
        known_ids = set()
        if os.path.exists(episodes_path):
            with open(episodes_path) as f:
                for line in f:
                    try:
                        known_ids.add(json.loads(line)["id"])
                    except (ValueError, KeyError):
                        pass

        pending = []

        def emit(rec):
            if rec["id"] not in known_ids:
                known_ids.add(rec["id"])
                pending.append(rec)

        writes = mod.load_writes(args.daemon_log) if args.daemon_log else []
        sess_starts, sess_eps = ([], [])
        if args.discharge_log:
            sess_starts, sess_eps = mod.load_sessions(args.discharge_log)

        lt = LiveTracker(mod, phase_c, writes, sess_starts, sess_eps, emit)
        lt.open_ep = ep_from_dict(mod, state.get("open_ep"))
        lt.prev = tick_from_dict(mod, state.get("prev_tick"))
        lt.last_closed_discharge = state.get("last_discharge")
        if lt.open_ep is not None:
            lt.open_ep.last_tick = lt.prev

        # new heartbeat ticks since the cursor
        cursor = _dt(state.get("cursor_ts"))
        new_ticks = []
        if os.path.exists(args.watchdog_log):
            with open(args.watchdog_log) as f:
                for line in f:
                    m = mod.HB_RE.match(line)
                    if not m:
                        continue
                    ts = mod.parse_ts(m.group(1))
                    if cursor is not None and ts <= cursor:
                        continue
                    new_ticks.append(mod.Tick(m))
            new_ticks.sort(key=lambda t: t.ts)
            # gauge contamination, continuous with the persisted prev tick
            seq_prev = lt.prev
            for t in new_ticks:
                if seq_prev is not None and \
                        abs(t.pct - seq_prev.pct) >= mod.GAUGE_JUMP_PCT:
                    t.contaminated = True
                seq_prev = t

        for t in new_ticks:
            lt.process(t)
        if new_ticks:
            cursor = new_ticks[-1].ts

        # sleep sidecar ingestion (a new night = a new SLEEP_START_TS)
        sidecar = os.path.join(state_dir, ".sleep_episode")
        if os.path.exists(sidecar):
            try:
                rec = sidecar_record(mod, sidecar, phase_c)
                if state.get("sidecar_id") != rec["id"]:
                    emit(rec)
                    state["sidecar_id"] = rec["id"]
            except (ValueError, KeyError, OSError):
                pass                    # malformed sidecar: skip, never fail

        # append + rotate (§4: rotate the whole file at 100 KB, keep 10)
        if pending:
            pending.sort(key=lambda r: mod.epoch(mod.parse_ts(
                (r.get("start_ts") or r["ts"]).replace("T", " ").replace("+02:00", ""))))
            mod.rotate_if_needed(vdir)
            with open(episodes_path, "a") as f:
                for rec in pending:
                    f.write(json.dumps(rec, separators=(",", ":")) + "\n")

        # .episode_open (design §4 render/state surface)
        open_state = {}
        if lt.open_ep is not None:
            open_state = {"type": lt.open_ep.kind,
                          "enforcer": lt.open_ep.enforcer,
                          "start_ts": mod.iso(lt.open_ep.start),
                          "start_pct": lt.open_ep.start_pct,
                          "upper": lt.open_ep.upper,
                          "lower": lt.open_ep.lower}
        tmp = os.path.join(state_dir, ".episode_open.tmp")
        with open(tmp, "w") as f:
            json.dump(open_state, f, indent=1)
        os.rename(tmp, os.path.join(state_dir, ".episode_open"))

        # persist resumable state atomically
        state["cursor_ts"] = _ts(cursor)
        state["prev_tick"] = tick_to_dict(lt.prev)
        state["open_ep"] = ep_to_dict(lt.open_ep)
        state["last_discharge"] = lt.last_closed_discharge
        tmp = state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.rename(tmp, state_path)

        if pending:
            print("tracker-live: +%d record(s); open=%s" %
                  (len(pending), open_state.get("type", "none")))
        return 0
    finally:
        try:
            os.remove(lock_path)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
