#!/usr/bin/env bash
# Regression test for the fleet-command cancelled-job log
# preservation (dezren39/fleet#122): a cancelled executor job (the
# timeout_minutes case) loses its step log entirely, so the
# composite action must (1) tee the command's output to
# .fleet/fleet-command.log while it runs, (2) append a "partial
# log" marker to that file when the job is cancelled, and (3)
# upload the file as the fleet-command-log artifact on failure or
# cancellation — in that order, and only then (a successful run
# must not grow a log artifact). This is a static wiring test over
# action.yml; the behavioral proof is a dispatched run cancelled
# mid-command whose artifact is read back (see dezren39/fleet#122).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
action="$here/../actions/fleet-command/action.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$action" ] || fail "action.yml not found at $action"

# (1) The Run command step tees to the log file.
grep -Fq 'command_log="$GITHUB_WORKSPACE/.fleet/fleet-command.log"' "$action" ||
  fail "Run command step does not set the fleet-command.log path"
grep -Fq 'bash -euo pipefail -c "$FLEET_RUN_COMMAND" 2>&1 | tee -a "$command_log"' "$action" ||
  fail "Run command step does not tee the command output to the log file"

# (2) The cancellation marker step exists and appends to the log.
grep -Fq 'if: ${{ cancelled() }}' "$action" ||
  fail "no step is gated on cancelled()"
grep -Fq 'job cancelled before the command finished; this log is partial' "$action" ||
  fail "cancellation marker text missing"

# (3) The upload step exists, gated on failure or cancellation.
grep -Fq "if: \${{ (failure() || cancelled()) && hashFiles('.fleet/fleet-command.log') != '' }}" "$action" ||
  fail "log upload step is not gated on failure() || cancelled()"
grep -Fq 'name: fleet-command-log' "$action" ||
  fail "fleet-command-log artifact upload step missing"
grep -Fq 'path: .fleet/fleet-command.log' "$action" ||
  fail "log upload step does not upload .fleet/fleet-command.log"

# Order: the tee (Run command) precedes the marker step, which
# precedes the upload step — the marker must be appended before
# the file is uploaded.
tee_line=$(grep -nF 'tee -a "$command_log"' "$action" | head -1 | cut -d: -f1)
marker_line=$(grep -nF 'Mark command log when the job is cancelled' "$action" | head -1 | cut -d: -f1)
upload_line=$(grep -nF 'Upload command log on failure or cancellation' "$action" | head -1 | cut -d: -f1)
[ -n "$tee_line" ] && [ -n "$marker_line" ] && [ -n "$upload_line" ] ||
  fail "could not locate tee/marker/upload steps"
[ "$tee_line" -lt "$marker_line" ] && [ "$marker_line" -lt "$upload_line" ] ||
  fail "steps out of order: tee=$tee_line marker=$marker_line upload=$upload_line"

echo "PASS: fleet-command action preserves the command log on failure/cancellation"
