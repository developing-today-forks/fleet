#!/usr/bin/env bash
# Realise the fleet repos' default dev shells and export their closures
# as a file:// binary cache (nar-cache/) in the current directory.
#
# This runs in a NORMAL GitHub Actions job container (the base image) —
# the environment where `nix develop` provably works (the fleet's CI
# does it daily). It deliberately does NOT run inside `docker build`:
# Nix store realisation under BuildKit died deterministically with a
# libstore SQLite assertion (runs 41516480304 / 41517835968), while the
# same realisation in a job container is routine.
#
# Locks are used exactly as committed — no `nix flake update` anywhere.
#
# Usage: export.sh <manifest> <fleet-workspace-root> [repo]
# With [repo], only that repo is exported (its required/optional flag
# still comes from the manifest). The publish workflow runs one job
# per repo so each closure is cached under its own lock's hash and a
# slow or failing repo neither blocks nor discards the others.
set -uo pipefail
manifest="${1:?manifest path}"
ctx="${2:?fleet workspace root}"
only="${3:-}"
export_dir="$PWD/nar-cache"
mkdir -p "$export_dir"
# In a job container the steps run as root while Nix is a single-user
# install owned by vscode — use its absolute profile path, and pass
# the flake settings via NIX_CONFIG (root has no nix.conf of its own).
export PATH="/home/vscode/.nix-profile/bin:/usr/local/go/bin:$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes ca-derivations
sandbox = false
eval-cache = false
build-users-group ="
# ca-derivations is load-bearing: the crash stack (run 41525338113) is
# LocalStore::queryRealisation_ asserting on a null prepared statement
# — the realisations table is only created when the ca-derivations
# experimental feature is on, and something in code's shell closure
# queries it. With the feature on, realisation proceeds.
# History: an earlier mitigation also serialised substitution/builds
# (max-substitution-jobs = 1, --max-jobs 1). Serial WITHOUT
# ca-derivations still crashed (41525338113); ca-derivations WITH
# serial ran 80+ min without crashing but was impractically slow —
# serial downloads of code's huge shell closure — so that run
# (41526881852) was cancelled and serialisation dropped. If the
# assertion returns with parallel jobs, ca-derivations was not the
# (only) fix and serialisation has to come back in a targeted form.

while read -r repo opt; do
  [ -z "${repo:-}" ] && continue
  case "$repo" in \#*) continue ;; esac
  if [ -n "$only" ] && [ "$repo" != "$only" ]; then continue; fi
  dir="$ctx/$repo"
  if [ ! -f "$dir/flake.nix" ]; then
    echo "export: $repo has no flake.nix — skipped"
    [ "${opt:-}" = "optional" ] && continue || { echo "export: $repo required but missing"; exit 1; }
  fi
  echo "export: building $repo default dev shell (lock as committed: $(md5sum "$dir/flake.lock" 2>/dev/null | cut -d' ' -f1))"
  ok=""
  for attempt in 1 2; do
    if out=$(nix build --accept-flake-config --no-link --print-out-paths "$dir#devShells.x86_64-linux.default" 2>&1); then ok=1; break; fi
    # Print the HEAD of the failure (the actual error) — v2 printed only
    # the tail, which was an anonymous stack trace (run 41521687044).
    echo "export: $repo attempt $attempt failed:"; echo "$out" | grep -vE "^[0-9]+# " | head -25
  done
  if [ -z "$ok" ]; then
    [ "${opt:-}" = "optional" ] && { echo "export: $repo FAILED (optional, continuing)"; continue; }
    echo "export: $repo FAILED (required)"; exit 1
  fi
  echo "export: copying closure of $out to nar-cache"
  nix copy --to "file://$export_dir" "$out" || { echo "export: $repo copy FAILED"; exit 1; }
  echo "export: $repo OK"
done < "$manifest"
echo "export: done — $(du -sh "$export_dir" | cut -f1) in nar-cache"
