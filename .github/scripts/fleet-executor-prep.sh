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
#   FLEET_PREP_SKIP        comma list of sections to skip: nix,rust,bun,cargotarget
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

  # Discover the target repo's rust-toolchain.toml pins (fleet#119):
  # the root file plus the per-package pins this fleet's repos carry
  # (pkgs/id, pkgs/fleet). pin_channels/pin_dirs are parallel arrays
  # of the distinct channels in probe order and the directory each
  # was found in (the install below runs from that directory so the
  # file's components list applies).
  pin_channels=()
  pin_dirs=()
  if [ -n "${FLEET_TARGET_DIR:-}" ]; then
    for f in "$FLEET_TARGET_DIR/rust-toolchain.toml" "$FLEET_TARGET_DIR/pkgs/id/rust-toolchain.toml" "$FLEET_TARGET_DIR/pkgs/fleet/rust-toolchain.toml"; do
      [ -f "$f" ] || continue
      ch="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)"
      [ -n "$ch" ] || continue
      seen=0
      if [ "${#pin_channels[@]}" -gt 0 ]; then
        for have in "${pin_channels[@]}"; do
          [ "$have" = "$ch" ] && seen=1
        done
      fi
      [ "$seen" = 1 ] && continue
      pin_channels+=("$ch")
      pin_dirs+=("$(dirname "$f")")
    done
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    toolchain="${FLEET_RUST_TOOLCHAIN:-}"
    if [ -z "$toolchain" ] && [ "${#pin_channels[@]}" -gt 0 ]; then
      toolchain="${pin_channels[0]}"
    fi
    toolchain="${toolchain:-1.99.1}"
    log "no cargo on PATH — installing rustup + toolchain $toolchain into $RUSTUP_HOME / $CARGO_HOME"
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile default --default-toolchain "$toolchain" ||
      fail "rustup install failed"
  else
    log "cargo already present ($(command -v cargo))"
  fi

  # Honour the pins (fleet#119). The fleet-command cache restores a
  # RUSTUP_HOME that can carry the rustup shims with the pinned
  # toolchain missing and no default configured: cargo then errors
  # "one wasn't specified explicitly, and no default is configured"
  # in any directory without a toolchain file in scope (this prep
  # step runs from the workspace root, outside the target checkout),
  # and a dispatched command that resolves some other toolchain
  # reports that toolchain's signal instead of the repo's (clippy
  # 1.99.0 flagging pre-existing lints against a 1.99.1 pin). So:
  # install every distinct pin that is missing, and when rustup
  # has no default configured, set the first pin as the default.
  # An existing default and installed pins are left alone, so the
  # baked image stays a no-op.
  if command -v rustup >/dev/null 2>&1; then
    reconcile_channels=()
    reconcile_dirs=()
    if [ -n "${FLEET_RUST_TOOLCHAIN:-}" ]; then
      reconcile_channels+=("$FLEET_RUST_TOOLCHAIN")
      reconcile_dirs+=("")
    elif [ "${#pin_channels[@]}" -gt 0 ]; then
      reconcile_channels=("${pin_channels[@]}")
      reconcile_dirs=("${pin_dirs[@]}")
    fi
    if [ "${#reconcile_channels[@]}" -gt 0 ]; then
      for i in "${!reconcile_channels[@]}"; do
        ch="${reconcile_channels[$i]}"
        installed=0
        if [ -d "$RUSTUP_HOME/toolchains" ]; then
          for d in "$RUSTUP_HOME/toolchains"/*/; do
            [ -d "$d" ] || continue
            case "$(basename "$d")" in
            "$ch" | "$ch"-*) installed=1 ;;
            esac
          done
        fi
        if [ "$installed" = 0 ]; then
          log "pinned toolchain $ch not installed — installing it (fleet#119)"
          if [ -n "${reconcile_dirs[$i]}" ]; then
            (cd "${reconcile_dirs[$i]}" && rustup toolchain install "$ch") ||
              fail "installing pinned toolchain $ch failed"
          else
            rustup toolchain install "$ch" ||
              fail "installing pinned toolchain $ch failed"
          fi
        fi
      done
      if [ -z "$(rustup default 2>/dev/null || true)" ]; then
        log "no rustup default configured — setting ${reconcile_channels[0]}, the target repo's pin (fleet#119)"
        rustup default "${reconcile_channels[0]}" ||
          fail "setting the rustup default failed"
      fi
    fi
  fi

  command -v cargo >/dev/null 2>&1 || fail "cargo still not resolvable after prep"
  if command -v rustup >/dev/null 2>&1; then
    # A cargo shim that cannot run is the fleet#119 failure mode;
    # fail here instead of handing the command a broken toolchain.
    cargo --version >/dev/null 2>&1 ||
      fail "cargo resolves through rustup but cannot run (no usable toolchain) — see fleet#119"
  fi
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

# -------------------------------------------------------- cargo target
# The fleet-command action restores .fleet/cache/cargo-target from
# the shared actions/cache and points CARGO_TARGET_DIR at it. A
# restored target dir can carry build-script artifacts produced by
# a different toolchain than the one this run uses (the cache
# crosses refs and commands; the run that saved it may have built
# with a Nix dev-shell cargo while this run uses the rustup cargo,
# or vice versa). Library artifacts survive the mismatch — rustc
# only reads them — but a build-script binary is EXECUTED, and
# cargo re-executes the restored binary on fingerprint trust
# alone. If the binary is absent while its fingerprint is fresh,
# or its ELF interpreter was baked in by a toolchain whose loader
# path does not exist in this image, the exec fails with "No such
# file or directory (os error 2)" before any test runs
# (dezren39/fleet#111: ring v0.17.14, runs 45249821636 /
# 45255497015; aws-lc-sys, run 45611503717).
#
# Build scripts are small and quick to rebuild, so never trust a
# restored one: invalidate every build-script unit in the restored
# target dir — compile and run fingerprints, the build/ output
# dir that holds the binary, and the deps/ binary — and let cargo
# rebuild just those units with the live toolchain. Everything
# else in the target dir stays warm.
if want cargotarget; then
  if [ -n "${CARGO_TARGET_DIR:-}" ] && [ -d "$CARGO_TARGET_DIR" ]; then
    swept=0
    while IFS= read -r -d '' fp_root; do
      profile_dir="$(dirname "$fp_root")"
      for unit in "$fp_root"/*/; do
        [ -d "$unit" ] || continue
        # Build-script units are the fingerprint dirs whose recorded
        # unit files mention build-script (the compile unit records
        # build-script-build-script-build, the run unit records
        # run-build-script-build-script-build; older cargo used
        # custom-build for the run unit). Lib/bin/test units record
        # lib-*, bin-*, dep-lib-* etc. and are left alone.
        if [ -n "$(find "$unit" -maxdepth 1 \( -name '*build-script*' -o -name '*custom-build*' \) -print -quit 2>/dev/null)" ]; then
          rm -rf "$unit" || log "warning: could not remove fingerprint dir $unit"
          swept=$((swept + 1))
        fi
      done
      # The compiled binary and the run outputs live in
      # build/<pkg>-<hash>/ (the hash is the run unit's); drop every
      # such dir that held a build script (a recorded output file,
      # or a build-script-* binary — custom build-target names
      # like aws-lc-sys's build-script-main included), plus the
      # deps/ binaries.
      for out_dir in "$profile_dir"/build/*/; do
        [ -d "$out_dir" ] || continue
        if [ -e "$out_dir/output" ] || [ -n "$(find "$out_dir" -maxdepth 1 -name 'build-script-*' -print -quit 2>/dev/null)" ]; then
          rm -rf "$out_dir" || log "warning: could not remove build output dir $out_dir"
        fi
      done
      rm -f "$profile_dir"/deps/build_script_build-* 2>/dev/null || true
    done < <(find "$CARGO_TARGET_DIR" -maxdepth 3 -type d -name .fingerprint -print0 2>/dev/null)
    log "cargo target: invalidated $swept restored build-script unit(s) under $CARGO_TARGET_DIR (fleet#111)"
  else
    log "cargo target: CARGO_TARGET_DIR unset or missing; nothing to sweep"
  fi
fi

log "executor environment ready"
