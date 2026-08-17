#!/bin/bash
# Application-prep pipeline. Run by launchd twice daily, or by hand:
#   agent/pipeline.sh            normal run
#   agent/pipeline.sh --baseline mark everything current as seen, prepare nothing
#
# The wrapper owns notification in a trap so a crash still reports. The model
# step only ever prepares folders; a human certifies and submits everything.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ROOT
CLAUDE="${CLAUDE:-$(command -v claude)}"
[ -x "$CLAUDE" ] || { echo "claude CLI not found on PATH. Set CLAUDE= in agent/config.env." >&2; exit 1; }
STATE="$ROOT/agent/state"
LOG="$STATE/run-$(date +%Y%m%d-%H%M).log"
SUMMARY="$STATE/summary.txt"
mkdir -p "$STATE"

# Optional config: NTFY_TOPIC for phone push via ntfy.sh
[ -f "$ROOT/agent/config.env" ] && source "$ROOT/agent/config.env"

QUEUE="$STATE/notify-queue.txt"

# Deliver one message. Returns 0 only if it actually reached the phone (or if no
# topic is configured, in which case the local banner is the whole contract).
deliver() {
  local msg="$1" ok=0
  if [ -n "${NTFY_TOPIC:-}" ]; then
    curl -sf -m 15 -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || ok=1
  fi
  /usr/bin/osascript -e "display notification \"${msg//\"/}\" with title \"Intern agent\"" >/dev/null 2>&1 || true
  return $ok
}

# Queue first, then deliver. An alert that cannot be sent must survive.
#
# This is the bug that hid the Aug 10 2026 outage: the network died, the wrapper
# correctly tried to shout about it, and the shout went out over curl to ntfy.sh
# which needs the very network that just failed. Fire-and-forget meant the alarm
# about the network was delivered over the network, so it evaporated and the run
# log looked healthy. Now anything undelivered stays on disk and goes out on the
# next run that has connectivity.
notify() {
  local msg="$1"
  printf '%s\n' "$msg" >> "$QUEUE"
  echo "[notify] $msg" >> "$LOG"
  drain_queue
}

drain_queue() {
  [ -s "$QUEUE" ] || return 0
  local tmp; tmp="$(mktemp)"
  local sent=0 held=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if deliver "$line"; then
      sent=$((sent + 1))
    else
      printf '%s\n' "$line" >> "$tmp"
      held=$((held + 1))
    fi
  done < "$QUEUE"
  mv "$tmp" "$QUEUE"
  [ "$held" -gt 0 ] && echo "[notify] $sent delivered, $held still queued" >> "$LOG"
  return 0
}

# Wait for the network before doing anything. launchd coalesces a missed slot to
# wake time, so a run can fire seconds after Wi-Fi reassociates and lose a DNS
# race it was always going to lose. Waiting is free; dying is not.
wait_for_network() {
  local i
  for i in $(seq 1 30); do
    if curl -sf -m 5 -o /dev/null "https://raw.githubusercontent.com" 2>/dev/null; then
      [ "$i" -gt 1 ] && echo "[net] reachable after $((i * 10))s" >> "$LOG"
      return 0
    fi
    /bin/sleep 10
  done
  echo "[net] still unreachable after 5 minutes; continuing anyway so fetch_diff can report" >> "$LOG"
  return 0
}

finish() {
  local code=$?
  if [ $code -ne 0 ] && [ ! -s "$SUMMARY" ]; then
    notify "PIPELINE FAILED (exit $code) — see $(basename "$LOG")"
  fi
}
trap finish EXIT

echo "=== run $(date -u +%FT%TZ) ===" >> "$LOG"
: > "$SUMMARY"

# Anything that failed to send on a previous run goes out now, before new work.
drain_queue

# Don't lose a DNS race against a machine that just woke up.
wait_for_network

# How long has the agent actually been working? Read BEFORE fetch_diff rewrites
# it, so a run can report on the gap it is closing.
PREV_SUCCESS=$(/usr/bin/python3 -c "
import json,sys
try: print(json.load(open('$STATE/seen.json')).get('last_success') or '')
except Exception: print('')
" 2>/dev/null)

# 1. Fetch + diff. Prints the count of new matches.
NEW=$(/usr/bin/python3 "$ROOT/agent/fetch_diff.py" ${1:-} 2>>"$LOG") || {
  notify "PIPELINE FAILED: listings fetch/diff error"
  exit 1
}

# The fetch succeeded. If the last one was long ago, say so out loud: a string
# of failed runs is otherwise indistinguishable from a quiet week, which is
# exactly how a whole day went missing on Aug 10 2026.
if [ -n "$PREV_SUCCESS" ]; then
  GAP_H=$(/usr/bin/python3 -c "
from datetime import datetime, timezone
try:
    prev = datetime.fromisoformat('$PREV_SUCCESS')
    print(int((datetime.now(timezone.utc) - prev).total_seconds() // 3600))
except Exception:
    print(0)
" 2>/dev/null)
  if [ "${GAP_H:-0}" -ge 24 ] 2>/dev/null; then
    notify "Agent was down ${GAP_H}h and is catching up now — check for missed postings"
  fi
fi

if [ "${1:-}" = "--baseline" ]; then
  notify "Baseline complete: current listings marked seen, nothing prepared."
  exit 0
fi

if [ "$NEW" = "0" ]; then
  # NO NEW LISTINGS IS NOT A REASON TO SKIP THE INBOX.
  #
  # This used to `exit 0` right here, which meant the inbox sweep (part of the
  # model step further down) never ran on any day without a new posting. New
  # postings are rare, so in practice it never ran at all: on Aug 9 2026 the
  # Optiver assessment invite, with a seven-day deadline, sat unread while this
  # run logged "0 new; exiting" an hour later. Silent, and it looked healthy.
  #
  # Listings and inbox are independent jobs that happen to share a schedule.
  echo "0 new listings; running inbox sweep only" >> "$LOG"
  cd "$ROOT"
  "$CLAUDE" -p "$(cat "$ROOT/agent/inbox-prompt.md")" \
    --settings "$ROOT/agent/agent-settings.json" \
    --max-turns 30 >> "$LOG" 2>&1 || echo "[inbox] model step failed" >> "$LOG"

  if [ -s "$STATE/oa-alerts.txt" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && notify "$line"
    done < "$STATE/oa-alerts.txt"
    cat "$STATE/oa-alerts.txt" >> "$STATE/oa-alerts.log"
    : > "$STATE/oa-alerts.txt"
  fi

  # Weekly heartbeat (Mondays, morning run) so quiet and dead are distinguishable.
  if [ "$(date +%u)" = "1" ] && [ "$(date +%H)" -lt 12 ]; then
    notify "Intern agent alive — 0 new listings, inbox checked"
  fi

  git add agent/state/inbox-seen.json agent/state/oa-alerts.log agent/state/summary.txt 2>/dev/null >> "$LOG" 2>&1
  git commit -qm "agent: inbox sweep $(date -u +%F-%H%M)" >> "$LOG" 2>&1 || true
  exit 0
fi

# 2. Fetch JDs (best effort, guaranteed stub fallback).
/usr/bin/python3 "$ROOT/agent/jd_fetch.py" >> "$LOG" 2>&1 || true

# 2b. Org sweep per new match: the company's own board may hold a better role.
/usr/bin/python3 - <<'PYEOF' >> "$LOG" 2>&1 || true
import json, os, subprocess
root = os.environ.get("ROOT", ".")
matches = json.load(open(f"{root}/agent/state/new_matches.json"))
for m in matches:
    out = subprocess.run(["/usr/bin/python3", f"{root}/agent/org_sweep.py", m.get("url","")],
                         capture_output=True, text=True, timeout=90)
    with open(f"{root}/agent/state/jd-cache/{m['id']}.sweep.json", "w") as f:
        f.write(out.stdout or '{"ats":"error","roles":[]}')
    print(f"[sweep] {m['company']}: done")
PYEOF

# 3. Model step: judgment, folders, drafts, summary.
MAP_BEFORE=$(grep -cv '^#' "$ROOT/applications/packet-map.txt" || true)
cd "$ROOT"
"$CLAUDE" -p "$(cat "$ROOT/agent/prompt.md")" \
  --settings "$ROOT/agent/agent-settings.json" \
  --max-turns 80 >> "$LOG" 2>&1
MODEL_EXIT=$?

# 4. For each folder the model added to the map: copy the right PDF in under
#    the neutral name, then run the ATS check and append it to the report.
NEUTRAL="${NEUTRAL_NAME:-Resume_SWE_Intern.pdf}"
if [ -f "$ROOT/applications/packet-map.txt" ]; then
  grep -v '^#' "$ROOT/applications/packet-map.txt" | grep -v '^$' | tail -n +$((MAP_BEFORE + 1)) | \
  while IFS=: read -r folder variant; do
    src="$ROOT/resume/out/$(cd "$ROOT/resume" && . ./candidate.env 2>/dev/null; variant_file "$variant" 2>/dev/null || echo "Resume_${variant}.pdf")"
    dest="$ROOT/applications/$folder"
    if [ -d "$dest" ] && [ -f "$src" ]; then
      cp "$src" "$dest/$NEUTRAL"
      ( cd "$ROOT/applications" && ./ats-check.sh "$folder" >> "$dest/report.md" 2>&1 ) || true
      echo "[packet] $folder <- $variant" >> "$LOG"
    else
      echo "[packet] SKIPPED $folder (missing folder or source $variant)" >> "$LOG"
    fi
  done
fi

# 4b. Push OA/reply alerts the model found in the inbox, one push per line,
#     then archive the file so alerts never fire twice.
if [ -s "$STATE/oa-alerts.txt" ]; then
  while IFS= read -r line; do
    notify "$line"
  done < "$STATE/oa-alerts.txt"
  cat "$STATE/oa-alerts.txt" >> "$STATE/oa-alerts.log"
  : > "$STATE/oa-alerts.txt"
fi

# 5. Commit the run so every agent action is reviewable and revertible.
cd "$ROOT"
git add applications agent/state/seen.json agent/state/summary.txt agent/state/inbox-seen.json agent/state/oa-alerts.log 2>/dev/null >> "$LOG" 2>&1
git commit -q -m "agent: $(cat "$SUMMARY" 2>/dev/null || echo "run $(date +%F)")" >> "$LOG" 2>&1 || true

# 6. Notify with the model's one-line summary, or a failure line.
if [ -s "$SUMMARY" ]; then
  notify "$(cat "$SUMMARY")"
elif [ $MODEL_EXIT -ne 0 ]; then
  notify "PIPELINE FAILED: model step exit $MODEL_EXIT with $NEW new listings pending"
  exit 1
else
  notify "PIPELINE WARNING: $NEW new listings but no summary written — check $(basename "$LOG")"
fi
