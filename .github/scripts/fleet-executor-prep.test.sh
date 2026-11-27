#!/usr/bin/env bash
# Regression test for FLEET_PREP_SKIP pattern matching. Source only the
# skip declaration and want() from the prep script; never run any setup section.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
prep="$here/fleet-executor-prep.sh"

load_want() {
  # Keep the production implementation as the oracle without sourcing the
  # executable prep script (which can perform privileged setup).
  # shellcheck disable=SC1090
  source <(sed -n '/^skip=/p; /^want()/p' "$prep")
}

FLEET_PREP_SKIP=nix,rust
export FLEET_PREP_SKIP
load_want
for section in nix rust bun cargotarget; do
  case ",$FLEET_PREP_SKIP," in
  *",$section,"*)
    if want "$section"; then
      echo "FAIL: listed section '$section' was not skipped" >&2
      exit 1
    fi
    ;;
  *)
    if ! want "$section"; then
      echo "FAIL: unlisted section '$section' was skipped" >&2
      exit 1
    fi
    ;;
  esac
done

FLEET_PREP_SKIP=rustling
export FLEET_PREP_SKIP
load_want
if ! want rust; then
  echo "FAIL: section name matching ignored comma boundaries" >&2
  exit 1
fi

echo "PASS: FLEET_PREP_SKIP skips listed declared sections and leaves others enabled"
