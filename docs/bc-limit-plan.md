# bc-limit Phase A plan (dry-run only, NO SMC writes)

Method: plan first (small tasks, exact paths, verification), then build, test, review.
Design: limit-writer-design.md v2 (authoritative). Superpowers skill files are
outside the File API allowed root (~/superpowers -> 403), so this plan follows
the task brief's explicit steps instead.

## Tasks
1. Write bc-limit.c (battopt-project/bc-build/bc-limit.c) — from scratch, clean-room.
   Probe (BCLM first) + BCLM backend + --dry-run default ON + safety rules 1-9.
   Verify: file exists; compiles clean.
2. Write limit.conf (battopt-project/bc-build/limit.conf) — LAST_UPPER=86, LAST_LOWER=85.
   Verify: file exists; bc-limit reads 86/85.
3. Compile: /usr/bin/clang bc-limit.c -o bc-limit -framework IOKit -framework CoreFoundation.
   Verify: exit 0; binary exists; size recorded.
4. Capture BCLM baseline BEFORE tests: ./bc-candidates (BCLM line). Verify: BCLM=10 recorded.
5. Run ./bc-limit --probe. Verify: selects BCLM (Intel backend).
6. Run ./bc-limit --dry-run and plain ./bc-limit (must default to dry-run).
   Verify: correct decision for current state (hold, 86%, BCLM=10 -> nothing to do);
   log says WOULD write nothing; no write call made.
7. Capture BCLM AFTER tests: ./bc-candidates. Verify: identical to baseline (10).
   This PROVES no SMC writes happened.
8. Write test log: battopt-project/bc-build/test-phase-a-2026-11-08.log
   (probe output, dry-run outputs, BCLM before/after, compile result, binary size).
9. Report back. Do NOT proceed to Phase B (controlled write — separate approval).

## Hard rules
- DRY-RUN ONLY. The write function exists but is NEVER called in Phase A tests.
  No --write flag is passed in any test. No sudo. No installs/push/deletes.
- Only bc-build/ files are touched. Do not modify the design, audit, or any repo
  file outside bc-build/. Do not touch dispatch.sh, the plugin, or helpers.
