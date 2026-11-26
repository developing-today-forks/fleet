#!/usr/bin/env bash
# Regression test for the fleet-executor-prep cargo-target sweep
# (dezren39/fleet#111): a restored cargo target dir must never hand
# cargo a build-script binary produced by another toolchain, so
# prep invalidates every restored build-script unit — fingerprints,
# build/ output dirs, deps/ binaries — while leaving the rest of
# the target dir (library units and their artifacts) warm.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
prep="$here/fleet-executor-prep.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
expect_gone() { [ ! -e "$1" ] || fail "expected swept: $1"; }
expect_kept() { [ -e "$1" ] || fail "expected kept: $1"; }

target="$fixture/cargo-target"

# A build-script crate (ring): compile + run fingerprint units, the
# build/ output dir holding the binary, and the deps/ binary.
mkdir -p "$target/debug/.fingerprint/ring-aaa111"
touch "$target/debug/.fingerprint/ring-aaa111/build-script-build-script-build.json"
mkdir -p "$target/debug/.fingerprint/ring-bbb222"
touch "$target/debug/.fingerprint/ring-bbb222/run-build-script-build-script-build.json"
mkdir -p "$target/debug/build/ring-bbb222/out"
printf 'poisoned binary (foreign interpreter)\n' >"$target/debug/build/ring-bbb222/build-script-build"
touch "$target/debug/build/ring-bbb222/output"
mkdir -p "$target/debug/deps"
printf 'binary' >"$target/debug/deps/build_script_build-aaa111"

# A release-profile build-script crate (aws-lc-sys).
mkdir -p "$target/release/.fingerprint/aws-lc-sys-eee555"
touch "$target/release/.fingerprint/aws-lc-sys-eee555/run-build-script-build-script-build.json"
mkdir -p "$target/release/build/aws-lc-sys-eee555"
printf 'binary' >"$target/release/build/aws-lc-sys-eee555/build-script-build"

# Controls: ordinary lib units and their outputs must survive.
mkdir -p "$target/debug/.fingerprint/ring-ccc333"
touch "$target/debug/.fingerprint/ring-ccc333/lib-ring.json"
mkdir -p "$target/debug/.fingerprint/serde-ddd444"
touch "$target/debug/.fingerprint/serde-ddd444/dep-lib-serde"
printf 'rlib' >"$target/debug/deps/libring-ccc333.rlib"

CARGO_TARGET_DIR="$target" FLEET_PREP_SKIP=nix,rust,bun \
  bash "$prep" >"$fixture/prep.log" 2>&1 ||
  fail "prep exited non-zero: $(cat "$fixture/prep.log")"

expect_gone "$target/debug/.fingerprint/ring-aaa111"
expect_gone "$target/debug/.fingerprint/ring-bbb222"
expect_gone "$target/debug/build/ring-bbb222"
expect_gone "$target/debug/deps/build_script_build-aaa111"
expect_gone "$target/release/.fingerprint/aws-lc-sys-eee555"
expect_gone "$target/release/build/aws-lc-sys-eee555"
expect_kept "$target/debug/.fingerprint/ring-ccc333"
expect_kept "$target/debug/.fingerprint/serde-ddd444"
expect_kept "$target/debug/deps/libring-ccc333.rlib"
grep -Fq "invalidated 3 restored build-script unit(s)" "$fixture/prep.log" ||
  fail "prep did not report 3 swept units: $(cat "$fixture/prep.log")"

# Unset CARGO_TARGET_DIR is a clean no-op.
env -u CARGO_TARGET_DIR FLEET_PREP_SKIP=nix,rust,bun \
  bash "$prep" >/dev/null 2>&1 ||
  fail "prep without CARGO_TARGET_DIR exited non-zero"

echo "ok: cargo-target sweep invalidates build-script units only"
