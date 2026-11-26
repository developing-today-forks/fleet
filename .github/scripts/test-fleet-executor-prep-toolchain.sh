#!/usr/bin/env bash
# Regression test for the fleet-executor-prep toolchain
# reconciliation (dezren39/fleet#119): a restored RUSTUP_HOME can
# carry the rustup shims with the target repo's pinned toolchain
# missing and no default configured, so cargo errors "no default
# is configured" outside a pinned directory and dispatched
# commands fall back to whatever toolchain resolves instead of
# the repo's pin. Prep must install every distinct pin found in
# the target checkout (root, pkgs/id, pkgs/fleet — duplicates
# collapsed) and set the first pin as the rustup default when
# none is configured, while leaving a warm home untouched.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
prep="$here/fleet-executor-prep.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Build a stub toolchain home: cargo/rustc/rustup shims in
# CARGO_HOME/bin, an empty RUSTUP_HOME/toolchains, and a target
# checkout whose three rust-toolchain.toml files pin 1.99.1
# (root), 1.99.1 again (pkgs/id — a duplicate), and 1.85.0
# (pkgs/fleet). The rustup stub records every call (with cwd) to
# $RUSTUP_STUB_LOG and emulates installs/defaults on the fixture.
make_env() {
  local root="$1"
  mkdir -p "$root/rustup/toolchains" "$root/cargo/bin" \
    "$root/target/pkgs/id" "$root/target/pkgs/fleet"
  printf '[toolchain]\nchannel = "1.99.1"\n' >"$root/target/rust-toolchain.toml"
  printf '[toolchain]\nchannel = "1.99.1"\n' >"$root/target/pkgs/id/rust-toolchain.toml"
  printf '[toolchain]\nchannel = "1.85.0"\n' >"$root/target/pkgs/fleet/rust-toolchain.toml"

  cat >"$root/cargo/bin/rustup" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "toolchain" ] && [ "${2:-}" = "install" ]; then
  ch="${3:-}"
  if [ -z "$ch" ]; then
    ch="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' ./rust-toolchain.toml | head -n 1)"
  fi
  echo "rustup toolchain install $ch cwd=$PWD" >>"$RUSTUP_STUB_LOG"
  mkdir -p "$RUSTUP_HOME/toolchains/$ch-x86_64-unknown-linux-gnu"
  exit 0
fi
if [ "${1:-}" = "toolchain" ] && [ "${2:-}" = "list" ]; then
  ls "$RUSTUP_HOME/toolchains" 2>/dev/null || true
  exit 0
fi
if [ "${1:-}" = "default" ]; then
  if [ -n "${2:-}" ]; then
    echo "rustup default-set $2 cwd=$PWD" >>"$RUSTUP_STUB_LOG"
    printf '%s' "$2" >"$RUSTUP_HOME/stub-default"
    exit 0
  fi
  echo "rustup default-get cwd=$PWD" >>"$RUSTUP_STUB_LOG"
  if [ -f "$RUSTUP_HOME/stub-default" ]; then
    cat "$RUSTUP_HOME/stub-default"
    exit 0
  fi
  exit 1
fi
echo "rustup $* cwd=$PWD" >>"$RUSTUP_STUB_LOG"
exit 0
STUB
  cat >"$root/cargo/bin/cargo" <<'STUB'
#!/usr/bin/env bash
echo "cargo 1.99.1 (stub)"
STUB
  cat >"$root/cargo/bin/rustc" <<'STUB'
#!/usr/bin/env bash
echo "rustc 1.99.1 (stub)"
STUB
  chmod +x "$root/cargo/bin/rustup" "$root/cargo/bin/cargo" "$root/cargo/bin/rustc"
}

run_prep() {
  local root="$1"
  RUSTUP_STUB_LOG="$root/rustup-calls.log" \
    RUSTUP_HOME="$root/rustup" CARGO_HOME="$root/cargo" \
    FLEET_TARGET_DIR="$root/target" FLEET_PREP_SKIP=nix,bun \
    bash "$prep" >"$root/prep.log" 2>&1
}

count_calls() {
  if [ -f "$2" ]; then grep -c "$1" "$2" || true; else echo 0; fi
}

# --- Scenario 1: cold restored cache — shims present, no
# toolchains installed, no default configured.
s1="$fixture/s1"
make_env "$s1"
run_prep "$s1" || fail "scenario 1: prep exited non-zero: $(cat "$s1/prep.log")"

installs="$(count_calls '^rustup toolchain install ' "$s1/rustup-calls.log")"
[ "$installs" = 2 ] ||
  fail "scenario 1: expected 2 pin installs (duplicates collapsed), got $installs: $(cat "$s1/rustup-calls.log")"
grep -Fq "rustup toolchain install 1.99.1 cwd=$s1/target" "$s1/rustup-calls.log" ||
  fail "scenario 1: 1.99.1 not installed from the root pin's directory: $(cat "$s1/rustup-calls.log")"
grep -Fq "rustup toolchain install 1.85.0 cwd=$s1/target/pkgs/fleet" "$s1/rustup-calls.log" ||
  fail "scenario 1: 1.85.0 not installed from the pkgs/fleet pin's directory: $(cat "$s1/rustup-calls.log")"
[ "$(cat "$s1/rustup/stub-default")" = "1.99.1" ] ||
  fail "scenario 1: default not set to the first pin (1.99.1): $(cat "$s1/rustup/stub-default" 2>/dev/null || echo '<unset>')"
grep -Fq "no rustup default configured — setting 1.99.1" "$s1/prep.log" ||
  fail "scenario 1: prep did not report setting the default: $(cat "$s1/prep.log")"

# --- Scenario 2: warm home — both pins installed and a default
# already configured. Prep must not install or override anything.
s2="$fixture/s2"
make_env "$s2"
mkdir -p "$s2/rustup/toolchains/1.99.1-x86_64-unknown-linux-gnu" \
  "$s2/rustup/toolchains/1.85.0-x86_64-unknown-linux-gnu"
printf '%s' "1.85.0-x86_64-unknown-linux-gnu" >"$s2/rustup/stub-default"
run_prep "$s2" || fail "scenario 2: prep exited non-zero: $(cat "$s2/prep.log")"

installs="$(count_calls '^rustup toolchain install ' "$s2/rustup-calls.log")"
[ "$installs" = 0 ] ||
  fail "scenario 2: expected no installs on a warm home, got $installs: $(cat "$s2/rustup-calls.log")"
sets="$(count_calls '^rustup default-set ' "$s2/rustup-calls.log")"
[ "$sets" = 0 ] ||
  fail "scenario 2: expected no default override, got $sets: $(cat "$s2/rustup-calls.log")"
[ "$(cat "$s2/rustup/stub-default")" = "1.85.0-x86_64-unknown-linux-gnu" ] ||
  fail "scenario 2: existing default was changed"

# --- Scenario 3: no target checkout in scope — no pins to
# discover, so no installs and no default changes.
s3="$fixture/s3"
make_env "$s3"
RUSTUP_STUB_LOG="$s3/rustup-calls.log" \
  RUSTUP_HOME="$s3/rustup" CARGO_HOME="$s3/cargo" \
  FLEET_PREP_SKIP=nix,bun \
  bash "$prep" >"$s3/prep.log" 2>&1 ||
  fail "scenario 3: prep exited non-zero: $(cat "$s3/prep.log")"
installs="$(count_calls '^rustup toolchain install ' "$s3/rustup-calls.log")"
[ "$installs" = 0 ] ||
  fail "scenario 3: expected no installs without a target checkout, got $installs"

echo "ok: prep installs the target repo's distinct toolchain pins and defaults to the first when unset"
