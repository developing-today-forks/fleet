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
build-users-group =
extra-substituters = https://nix-cache.developing-today-llc-domains-0.workers.dev https://developing-today.cachix.org
extra-trusted-public-keys = nix-cache-1:x/kKZuzyQI3L0/twmOp3w2U68F2ZgM3WnH3ERYKrwf8= developing-today.cachix.org-1:dfIGqIJODUw9V/O9yUrYP2d3tjJtk3SZTDxOBWn9vN4="
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

while read -r repo col2 col3; do
  [ -z "${repo:-}" ] && continue
  case "$repo" in \#*) continue ;; esac
  if [ -n "$only" ] && [ "$repo" != "$only" ]; then continue; fi
  # Manifest columns: <repo> [shell] [optional] — the shell column names
  # the devShells attribute to warm (default: "default"); a bare
  # "optional" in the shell column means shell=default + optional.
  shell="default"; opt=""
  for tok in "${col2:-}" "${col3:-}"; do
    [ -z "$tok" ] && continue
    if [ "$tok" = "optional" ]; then opt="optional"; else shell="$tok"; fi
  done
  dir="$ctx/$repo"
  if [ ! -f "$dir/flake.nix" ]; then
    echo "export: $repo has no flake.nix — skipped"
    [ "${opt:-}" = "optional" ] && continue || { echo "export: $repo required but missing"; exit 1; }
  fi
  echo "export: building $repo dev shell '$shell' (lock as committed: $(md5sum "$dir/flake.lock" 2>/dev/null | cut -d' ' -f1))"
  ok=""
  for attempt in 1 2; do
    # stdout ONLY into $out: folding stderr in with 2>&1 pollutes the
    # captured store path with substitution progress lines, and the
    # copy step then receives a multi-line blob instead of a path
    # (issue #16; run 41550950349: opencode + openchamber realised fine
    # and failed at copy with a stack-overflow error). stderr goes to
    # a log whose HEAD is printed on failure — v2 printed only the
    # tail, which was an anonymous stack trace (run 41521687044).
    errlog="$(mktemp)"
    if out=$(nix build --accept-flake-config --no-link --print-out-paths "$dir#devShells.x86_64-linux.$shell" 2>"$errlog"); then ok=1; break; fi
    echo "export: $repo attempt $attempt failed:"; grep -vE "^[0-9]+# " "$errlog" | head -25
  done
  rm -f "${errlog:-}"
  if [ -z "$ok" ]; then
    [ "${opt:-}" = "optional" ] && { echo "export: $repo FAILED (optional, continuing)"; continue; }
    echo "export: $repo FAILED (required)"; exit 1
  fi
  out="$(echo "$out" | tail -n 1)"
  echo "export: copying closure of $out to nar-cache"
  nix copy --to "file://$export_dir" "$out" || { echo "export: $repo copy FAILED"; exit 1; }
  # Also push the closure to the fleet's hosted binary cache
  # (developing-today/nix-cache on Cloudflare R2 + Workers), signed
  # with the cache's key, so laptops / Codespaces / other CI pull these
  # paths without realising them. Non-fatal: the nar-cache above is
  # what the image build consumes; a cache outage must not fail it.
  if [ -n "${NIX_CACHE_UPLOAD_URL:-}" ] && [ -n "${NIX_CACHE_SIGNING_KEY_FILE:-}" ]; then
    echo "export: pushing $repo closure to the fleet nix-cache"
    nix path-info --recursive "$out" | nix store sign --key-file "$NIX_CACHE_SIGNING_KEY_FILE" --stdin \
      && nix copy --to "$NIX_CACHE_UPLOAD_URL" "$out" \
      && echo "export: $repo pushed to nix-cache" \
      || echo "export: WARNING $repo nix-cache push failed (non-fatal)"
  fi
  # Also push the closure to the fleet's Cachix cache
  # (developing-today.cachix.org) — the dual-push split (Drew,
  # 2026-11-02): the R2 nix-cache above is the uncapped system of
  # record; Cachix is the fast hosted layer, and only for this
  # bounded shell set — bulkier artifacts go to R2 only. Cachix
  # skips anything already on cache.nixos.org, so only
  # fleet-specific paths land there. Non-fatal, same as the
  # nix-cache push. The cachix CLI comes from the fleet's own
  # pinned nixpkgs (fleetNixpkgsRev) so the tool version tracks
  # the pin instead of drifting.
  if [ -n "${CACHIX_AUTH_TOKEN:-}" ]; then
    echo "export: pushing $repo closure to Cachix (developing-today)"
    nix path-info --recursive "$out" | xargs -r nix run "github:NixOS/nixpkgs/$(nix eval --raw "$ctx#fleetNixpkgsRev")#cachix" -- push developing-today \
      && echo "export: $repo pushed to Cachix" \
      || echo "export: WARNING $repo Cachix push failed (non-fatal)"
  fi
  echo "export: $repo OK"
done < "$manifest"
echo "export: done — $(du -sh "$export_dir" | cut -f1) in nar-cache"
