# fleet-build — the fleet's shared build/test container

One image, three jobs:

| Use | How |
|---|---|
| **GitHub Actions builds/tests** (any repo, either owner) | `container: ghcr.io/dezren39/fleet-build:full` on a job (see `examples/`) |
| **Codespaces** for dezren39/fleet | `.devcontainer/devcontainer.json` names this image — see below |
| **Local / laptop** | `docker run --rm -it ghcr.io/dezren39/fleet-build:full bash` (or podman) |

Published by `.github/workflows/fleet-build-container.yml` in this repo:
on pushes to main that touch `containers/fleet-build/**`, weekly
(Mondays 06:00 UTC), and on manual dispatch — where **Fresh build**
rebuilds with no layer cache (the "maybe a fresh build" knob).

## Tags

- `:latest` / `:base` — OS tools + pinned Nix + pinned Go. Small, fast to pull.
- `:full` — base **plus every fleet repo's default Nix dev shell realised
  into the image's `/nix` store** (code, opencode, openchamber required;
  nix, zettel best-effort). Jobs start with their toolchains already
  present: no install step, no cache restore, works offline for those shells.
- `:sha-<commit>` / `:full-sha-<commit>` — immutable pins. **Use a sha tag
  in real workflows**; keep `:full` for experiments.

## The no-nixpkgs-update rule

Building this image **never updates any repo's nixpkgs pin**:

- The base layer doesn't use nixpkgs at all — Nix and Go are pinned
  upstream binaries (`NIX_VERSION`, `GO_VERSION` args in the Containerfile,
  bumped only by a deliberate PR).
- The warmed store consumes each repo's `flake.lock` **exactly as
  committed** (`export.sh` contains no `nix flake update`, no
  `--update-input`). If a lock is old, the image faithfully contains the
  old shell.
- How warming works (v3): one GHA *job container* per repo (the base
  image) realises the shell named in `warm-manifest.txt` (the lean
  `fleet` shell where a repo has one) and exports its closure as a
  binary cache, keyed in actions/cache by that repo's lock hash —
  unchanged locks are never re-realised. The `:full` image then only
  *imports* the merged caches. Realising inside `docker build` was
  tried first and abandoned: Nix store realisation under BuildKit
  dies deterministically with a libstore SQLite assertion (fleet runs
  41516480304 / 41517835968). Importing is a different, sequential
  code path and is safe there.
- The same export jobs also sign each closure and push it to the
  fleet's hosted binary cache (developing-today/nix-cache — Nix on
  Cloudflare R2 + Workers), so laptops, Codespaces and other CI can
  substitute the fleet shells without realising them. The image's
  nix.conf and each fleet repo's flake `nixConfig` carry that cache as
  an extra substituter. Push failures are non-fatal to the image
  build.
- The same closures are also pushed to the fleet's Cachix cache
  (developing-today.cachix.org) — the dual-push split: the R2
  nix-cache is the uncapped system of record, Cachix is the fast
  hosted layer for this bounded shell set only (bulkier artifacts
  go to R2 only). The image's nix.conf trusts the Cachix cache as
  an extra substituter too.

## Can Codespaces use it? Yes.

A devcontainer does not have to build a Dockerfile — it can name a
prebuilt image. This repo's `.devcontainer/devcontainer.json` does:

```json
{ "image": "ghcr.io/dezren39/fleet-build:latest", "...": "the rest unchanged" }
```

Codespaces then *pulls* the image instead of building, so a codespace
starts at pull speed, and the fleet prebuilds snapshot that same pull.
Notes:

- The image is based on `mcr.microsoft.com/devcontainers/base` and keeps
  the `vscode` user, so it satisfies the devcontainer runtime contract.
- Devcontainer **features are applied on top of an image too** — but
  anything a non-Codespaces consumer needs (GHA jobs get no features)
  must be in the image itself. That's why Go is baked in rather than
  left as the old devcontainer's Go feature.
- `.devcontainer/Dockerfile` is kept as the fallback: switch the one
  `image` line back to a `build` block and Codespaces builds locally
  again, exactly as before.
- Any *other* repo can do the same — a developing-today repo can name
  `ghcr.io/dezren39/fleet-build:full` in its own devcontainer.json and
  get a codespace with the warmed shells, under its own ownership.
  (Org repos still can't use Codespaces *prebuilds/settings* on the
  Free org plan — that's a plan limit, not an image limit.)

## Using it for builds/tests in BOTH owners

The image is a **public GHCR package under dezren39**. A job container
reference is just an image name — the consuming repo's owner doesn't
matter. The same workflow snippet works verbatim in `dezren39/nix`,
`developing-today/code`, `developing-today/opencode`, etc.
(`examples/gha-job-container.yml`):

```yaml
jobs:
  test:
    runs-on: ubuntu-24.04
    container: ghcr.io/dezren39/fleet-build:full
    steps:
      - uses: actions/checkout@v4
      - run: nix develop --command make test   # or go test ./... etc.
```

Container-job specifics worth knowing:

- If the workflow uses `actions/checkout` (or other JS actions), set
  `options: --user root` on the container — the image's default user is
  `vscode`, under which JS actions cannot write the runner's
  file-command directory and checkout fails with EACCES (verified in
  fleet run 41519078473). Pure `run:` steps work either way.
- Steps run as **root** by default in a job container. Nix here is a
  single-user install owned by `vscode`; root can run it via the
  `/usr/local/bin/nix` symlink, and repo shells are usually best run as
  `runuser -u vscode -- env HOME=/home/vscode bash -lc 'nix develop --command …'`
  (plain `su vscode` prompts for a password in this image — verified in
  the first publish run). The publish workflow's
  smoke job demonstrates both.
- A job container is **not** a runner: the job still counts against the
  owning account's concurrency (40 personal / 20 org) and the 6-hour
  job cap still applies. What the image buys is *zero setup time and a
  known toolchain*, not extra capacity.
- There is also a mirror publish for the org namespace —
  `ghcr.io/developing-today/fleet-build` — built by a workflow in
  developing-today/code from this same Containerfile, for repos that
  prefer an org-owned package. Prefer the dezren39 package (it's the
  canonical build the smoke test verifies); the mirror is a re-tag of
  the same source.

## What's inside (base)

Ubuntu 24.04 (devcontainers base), git, gh (via base image), direnv,
jq, ripgrep, fd, shellcheck, sqlite3, python3, Go (pinned), Nix
(pinned, flakes on, sandbox off — required inside containers).
Everything else comes from the repos' own dev shells in `:full`.
