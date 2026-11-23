#!/usr/bin/env bash
# fleet-executor-prep — make a fleet-build job container boring.
#
# The dispatch surfaces (fleet-command.yml, fleet-run.yml,
# fleet-dispatch-test.yml) run arbitrary commands as root inside the
# fleet-build image. Three environment gaps made every dispatched
# command improvise its own bootstrap first (developing-today/code
# #13159, #13331):
#
#   1. Root has no nix.conf: the image's Nix is a single-user install
#      owned by vscode, whose ~/.config/nix/nix.conf root never reads.
#      As root, `nix develop` therefore failed on experimental
#      features, then on the missing `nixbld` build-users group, and
#      the `--option build-users-group ''` workaround ran builds as
#      root and tripped nix's /homeless-shelter purity check.
#   2. No Rust toolchain: the image shipped none, and the
#      fleet-command cache dirs (CARGO_HOME/RUSTUP_HOME under
#      .fleet/cache) restore empty on a cold key with nothing
#      installing a toolchain into them.
#   3. No bun, which the repos' TypeScript packages test with.
#
# containers/fleet-build/Containerfile now bakes all three into the
# image (nixbld group + members, a system /etc/nix/nix.conf, a
# rustup-managed pinned toolchain, bun). This script is the runtime
# half for images published before the bake, and a no-op once the
# baked image is in place: every section checks whether its piece is
# already present and only installs what is missing. Idempotent.
#
# The nixbld recipe is the one proven live in this container by the
# 2026-11-23 9111-02 dispatch (forks/fleet run 45177477297, recorded
# on code#13159): the group must exist AND its member list must name
# the users — nix rejects a group whose members only have it as
# their primary group ("the build users group 'nixbld' has no
# members"). With real build users configured, builds run as those
# users and the /homeless-shelter purity check (which applies to
# builds running as the invoking user) does not fire; the script
# deliberately does not touch /homeless-shelter itself, which is the
# runner machinery's scratch home.
#
# Knobs (environment):
#   FLEET_PREP_SKIP        comma list of sections to skip: nix,rust,bun
#   RUSTUP_HOME/CARGO_HOME toolchain locations (defaults below)
#   FLEET_RUST_TOOLCHAIN   default toolchain override
#   FLEET_TARGET_DIR       target checkout used to discover a
#                          rust-toolchain.toml channel pin
#   FLEET_BUN_VERSION      bun pin (default: 1.4.5)
#   FLEET_BUN_HOME         where bun lands when missing
#                          (default: /usr/local/bun)
#
# Linux only: the macOS fleet-command surface has no container and
# is out of scope for #13159/#13331, so the script exits 0 there.

set -euo pipefail

log() { echo "[fleet-executor-prep] $*"; }
fail() {
  echo "::error::[fleet-executor-prep] $*"
  exit 1
}

if [ "$(uname -s)" != "Linux" ]; then
  log "non-Linux surface; nothing to prepare"
  exit 0
fi

skip=",${FLEET_PREP_SKIP:-},"
want() { [ "${skip}" != *",$1,"* ]; }

# ---------------------------------------------------------------- nix
# Root-only: creating users and writing /etc/nix/nix.conf needs it.
# A non-root step in this image is the vscode user, whose own
# nix.conf already carries the working single-user settings.
if want nix && command -v nix >/dev/null 2>&1; then
  if [ "$(id -u)" = "0" ]; then
    if ! getent group nixbld >/dev/null 2>&1 || ! getent group nixbld | cut -d: -f4 | grep -q nixbld1; then
      log "creating the nixbld build-users group (with a populated member list)"
      groupadd -f nixbld
      for i in $(seq 1 32); do
        useradd -M -g nixbld -d /var/empty -s /bin/false "nixbld$i" 2>/dev/null || true
        # nix checks the group's member list, so primary-group-only
        # membership is not enough — add every user explicitly.
        usermod -a -G nixbld "nixbld$i"
      done
    else
      log "nixbld group already present with members"
    fi

    if [ ! -f /etc/nix/nix.conf ] || ! grep -q 'build-users-group' /etc/nix/nix.conf; then
      log "writing the system nix.conf (experimental features, build-users-group = nixbld)"
      mkdir -p /etc/nix
      {
        printf '%s\n' \
          '# Managed by fleet-executor-prep / containers/fleet-build (code#13159).' \
          '# The vscode user keeps its own ~/.config/nix/nix.conf, which' \
          '# overrides build-users-group back to empty for the single-user' \
          '# store it owns; this file governs root and every other user.' \
          'experimental-features = nix-command flakes ca-derivations' \
          'build-users-group = nixbld' \
          'sandbox = false' \
          'eval-cache = false' \
          'extra-substituters = https://nix-cache.developing-today.workers.dev https://developing-today.cachix.org' \
          'extra-trusted-public-keys = nix-cache-1:x/kKZuzyQI3L0/twmOp3w2U68F2ZgM3WnH3ERYKrwf8= developing-today.cachix.org-1:dfIGqIJODUw9V/O9yUrYP2d3tjJtk3SZTDxOBWn9vN4='
      } >>/etc/nix/nix.conf
    else
      log "system nix.conf already sets build-users-group"
    fi
    log "nix: $(nix --version), build-users-group = $(nix config show build-users-group 2>/dev/null || echo '?')"
  else
    log "not root and nix present — assuming the image user's own nix.conf (vscode single-user path)"
  fi
fi

# --------------------------------------------------------------- rust
# RUSTUP_HOME/CARGO_HOME arrive from the caller when it manages
# caches (the fleet-command action points them at .fleet/cache);
# otherwise they take the image's baked locations.
export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
if want rust; then
  mkdir -p "$RUSTUP_HOME" "$CARGO_HOME/bin"
  case ":$PATH:" in
  *":$CARGO_HOME/bin:"*) ;;
  *) export PATH="$CARGO_HOME/bin:$PATH" ;;
  esac
  if [ -n "${GITHUB_PATH:-}" ]; then
    grep -qx "$CARGO_HOME/bin" "$GITHUB_PATH" 2>/dev/null || echo "$CARGO_HOME/bin" >>"$GITHUB_PATH"
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    grep -q '^RUSTUP_HOME=' "$GITHUB_ENV" 2>/dev/null || echo "RUSTUP_HOME=$RUSTUP_HOME" >>"$GITHUB_ENV"
    grep -q '^CARGO_HOME=' "$GITHUB_ENV" 2>/dev/null || echo "CARGO_HOME=$CARGO_HOME" >>"$GITHUB_ENV"
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    toolchain="${FLEET_RUST_TOOLCHAIN:-}"
    if [ -z "$toolchain" ] && [ -n "${FLEET_TARGET_DIR:-}" ]; then
      # The fleet-wide pin lives in the target repo's
      # rust-toolchain.toml (code: 1.99.1 at root, pkgs/id, pkgs/fleet).
      for f in "$FLEET_TARGET_DIR/rust-toolchain.toml" "$FLEET_TARGET_DIR/pkgs/fleet/rust-toolchain.toml"; do
        if [ -f "$f" ]; then
          toolchain="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)"
          [ -n "$toolchain" ] && break
        fi
      done
    fi
    toolchain="${toolchain:-1.99.1}"
    log "no cargo on PATH — installing rustup + toolchain $toolchain into $RUSTUP_HOME / $CARGO_HOME"
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile default --default-toolchain "$toolchain" ||
      fail "rustup install failed"
  else
    log "cargo already present ($(command -v cargo))"
  fi
  # Per-repo rust-toolchain.toml pins are honoured by the rustup
  # shims themselves (auto-install on first use inside the repo).
  command -v cargo >/dev/null 2>&1 || fail "cargo still not resolvable after prep"
  log "rust: $(cargo --version), $(rustc --version)"
fi

# ---------------------------------------------------------------- bun
if want bun; then
  bun_home="${FLEET_BUN_HOME:-/usr/local/bun}"
  case ":$PATH:" in
  *":$bun_home/bin:"*) ;;
  *) export PATH="$bun_home/bin:$PATH" ;;
  esac
  if [ -n "${GITHUB_PATH:-}" ]; then
    grep -qx "$bun_home/bin" "$GITHUB_PATH" 2>/dev/null || echo "$bun_home/bin" >>"$GITHUB_PATH"
  fi
  if ! command -v bun >/dev/null 2>&1; then
    bun_version="${FLEET_BUN_VERSION:-1.4.5}"
    case "$(uname -m)" in
    x86_64) bun_asset="bun-linux-x64" ;;
    aarch64 | arm64) bun_asset="bun-linux-aarch64" ;;
    *) fail "no bun asset mapping for architecture $(uname -m)" ;;
    esac
    log "no bun on PATH — installing bun $bun_version into $bun_home"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${bun_version}/${bun_asset}.zip" -o "$tmp/bun.zip" ||
      fail "bun download failed"
    unzip -o -q "$tmp/bun.zip" -d "$tmp" || fail "bun unzip failed"
    mkdir -p "$bun_home/bin"
    install -m 0755 "$tmp/$bun_asset/bun" "$bun_home/bin/bun"
    # The release zip ships bun alone; bunx is bun under a second
    # name (argv[0] dispatch), linked the way the official
    # installer sets it up.
    ln -sf "$bun_home/bin/bun" "$bun_home/bin/bunx"
    rm -rf "$tmp"
    trap - EXIT
  else
    log "bun already present ($(command -v bun))"
  fi
  command -v bun >/dev/null 2>&1 || fail "bun still not resolvable after prep"
  log "bun: $(bun --version)"
  if ! command -v bunx >/dev/null 2>&1; then
    # Images baked before the Containerfile installed bunx ship bun
    # alone, and dispatched JS verification calls bunx directly
    # (code#13189). bunx is bun dispatched on argv[0], so a shim
    # beside the resolved bun is the whole fix.
    mkdir -p "$bun_home/bin"
    ln -sf "$(command -v bun)" "$bun_home/bin/bunx"
    log "bunx missing - shimmed to $(command -v bun) in $bun_home/bin"
  fi
  command -v bunx >/dev/null 2>&1 || fail "bunx still not resolvable after prep"
  log "bunx: $(bunx --version)"
fi

log "executor environment ready"
