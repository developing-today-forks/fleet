#!/usr/bin/env bash
# Realise the fleet repos' default Nix dev shells into this image's
# /nix store, using each repo's flake.lock EXACTLY as committed.
#
# Hard rule (Drew, 2026-11-02): this script must never update a lock.
# There is deliberately no `nix flake update`, no `--update-input`, and
# no network-mutating flag anywhere in here. If a lock is stale, the
# image simply contains the stale shell; the repo updates its own lock
# in its own PR, and the next image build picks it up.
#
# Usage: warm.sh <manifest> <context-dir>
# Manifest lines: <repo-dir-name> [optional]
#   required entries fail the build if the shell cannot be realised;
#   "optional" entries log and continue.
set -uo pipefail
manifest="${1:?manifest path}"
ctx="${2:?context dir}"
export PATH="$HOME/.nix-profile/bin:/usr/local/go/bin:$PATH"

while read -r repo opt; do
  [ -z "${repo:-}" ] && continue
  case "$repo" in \#*) continue ;; esac
  dir="$ctx/$repo"
  if [ ! -f "$dir/flake.nix" ]; then
    echo "warm: $repo has no flake.nix in context — skipped"
    [ "${opt:-}" = "optional" ] && continue || { echo "warm: $repo is required but missing"; exit 1; }
  fi
  echo "warm: realising $repo default dev shell (lock as committed: $(md5sum "$dir/flake.lock" 2>/dev/null | cut -d' ' -f1))"
  # `nix develop --command true` forces full realisation of the shell's
  # closure into the local store without running anything in it.
  if nix develop --accept-flake-config "$dir" --command true; then
    echo "warm: $repo OK"
  elif [ "${opt:-}" = "optional" ]; then
    echo "warm: $repo FAILED (optional, continuing)"
  else
    echo "warm: $repo FAILED (required)"
    exit 1
  fi
done < "$manifest"
echo "warm: done"
