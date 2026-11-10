#!/bin/zsh
# Launch the installed Debug app on mock data and report how long the main
# thread was stalled after the first frame, from the app's own perf.jsonl.
#
#   scripts/perf-launch.sh [threads] [seconds]    # default 120 threads, 10 s
#
# `threads` is how many unseen active threads the open server's subscription
# answers with, two seconds after launch (`-DuocordMockThreadSync`). UDID
# (default build/duo-sim-udid) picks the simulator. Exits 1 when a stall after
# the first frame is longer than BUDGET_MS (default 500), 2 when the run
# produced no usable record. Drawing the first conversation takes two or three
# stalls of 100 to 350 ms; the budget sits above those.
set -uo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}"
cd "${0:A:h}/.."
udid="${UDID:-$(cat build/duo-sim-udid)}"
threads="${1:-120}"
seconds="${2:-10}"
bundle=com.saphid.duocord

xcrun simctl bootstatus "$udid" -b > /dev/null || exit 2
xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1
data=$(xcrun simctl get_app_container "$udid" "$bundle" data) || { echo "app not installed on $udid" >&2; exit 2; }
rm -f "$data/Documents/perf.jsonl"
xcrun simctl launch "$udid" "$bundle" -DuocordMock YES -DuocordNoNotificationPrompt YES -DuocordPerfStalls YES \
  -DuocordMockThreadSync "$threads" > /dev/null || exit 2
sleep "$seconds"
xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1

python3 - "$data/Documents/perf.jsonl" "$threads" "${BUDGET_MS:-500}" <<'EOF'
import json, sys
path, threads, budget = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    events = [json.loads(line) for line in open(path) if line.strip()]
except OSError:
    print("no perf.jsonl: the app did not launch"); sys.exit(2)
marks = {e["event"]: e["ms"] for e in events if e["event"] in ("appInit", "mainViewAppear", "ready")}
if "ready" not in marks:
    print("no ready mark: %s" % marks); sys.exit(2)
stalls = [e for e in events if e["event"] == "stall"]
# A stall that began before the first frame is launch time, not a frozen interface.
first_frame = marks.get("mainViewAppear", marks["ready"])
frozen = [s for s in stalls if s["at"] >= first_frame]
redraws = sum(1 for e in events if e["event"] == "rebuild" and e.get("reason") == "update")
worst = max((s["ms"] for s in frozen), default=0)
print("threads=%s appInit=%s mainViewAppear=%s ready=%s" % (threads, marks.get("appInit"), marks.get("mainViewAppear"), marks["ready"]))
print("launch stalls before the first frame (at, ms): %s" % [(s["at"], s["ms"]) for s in stalls if s["at"] < first_frame])
print("interface stalls (at, ms): %s" % [(s["at"], s["ms"]) for s in frozen])
print("conversation redraws: %d" % redraws)
print("worst interface stall: %d ms, total %d ms, budget %d ms" % (worst, sum(s["ms"] for s in frozen), budget))
sys.exit(1 if worst > budget else 0)
EOF
