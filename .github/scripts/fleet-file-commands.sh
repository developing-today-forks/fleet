#!/usr/bin/env bash
# fleet-file-commands — let privilege-dropping commands use the
# step's GitHub file commands.
#
# The dispatch surfaces (fleet-command.yml, fleet-run.yml,
# fleet-dispatch-test.yml) run every step as root inside the
# fleet-build container, and dispatched commands routinely drop
# privileges the documented way:
#
#   runuser -u vscode -- env HOME=/home/vscode bash -lc '...'
#
# The runner creates each step's file-command files — the files
# $GITHUB_STEP_SUMMARY, $GITHUB_ENV, $GITHUB_OUTPUT, $GITHUB_PATH
# and $GITHUB_STATE point at, under
# /__w/_temp/_runner_file_commands/ — owned by the host runner
# user, so a process running as vscode cannot append to them.
# Vitest's GitHub Actions reporter failed its summary write with
# EACCES that way (developing-today/code #13537), and any tool
# appending to $GITHUB_ENV / $GITHUB_OUTPUT from a
# dropped-privilege process hits the same wall.
#
# The files are per-step, so the executor prep step cannot fix
# them up in advance: this script runs at the top of the step that
# executes the command, and makes that step's file-command files
# writable by any user in the container. A variable whose file
# does not exist yet gets its parent directory made writable
# instead, so the process can create the file. The runner reads
# the files back after the step regardless of their mode, and
# commands that stay root are unaffected.
#
# Best-effort by design: it never fails the step — a command that
# never touches the file commands must not notice this ran.

set -uo pipefail

for var in GITHUB_STEP_SUMMARY GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STATE; do
  file="${!var:-}"
  [ -n "$file" ] || continue
  if [ -e "$file" ]; then
    chmod a+w "$file" 2>/dev/null || true
  else
    chmod a+w "$(dirname "$file")" 2>/dev/null || true
  fi
done

exit 0
