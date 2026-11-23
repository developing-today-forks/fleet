# fleet — one Codespace for the whole fleet

Umbrella repo (owned by the personal account on purpose): the
developing-today fleet as git submodules, with a single devcontainer.

Why personal-account ownership matters: Codespaces **prebuilds** and the
repository Codespaces settings page are unavailable for org-owned repos
on the current organization plan (verified 2026-10-25 on
developing-today/code — Settings → Codespaces returns 404). A personal
repo under GitHub Pro gets prebuilds, so this umbrella is where the
fleet's codespaces live. The per-repo devcontainer in developing-today/
code (PR #855) still works for single-repo codespaces billed personally;
this repo is the prebuild play.

## Submodules

The umbrella records 22 submodule pins. [FLEET.md](FLEET.md) lists every
path, repository and management tier. Each pin is a Git commit recorded
in the umbrella tree.

The [devcontainer](.devcontainer/devcontainer.json) initializes ten paths
during prebuilds and attempts `hatch-personal` and `cairn` separately when
access is available. It requests write permissions for eleven repositories
at Codespace creation. Membership, automatic checkout and permission to
push are separate decisions. Run `git submodule update --init -- <path>`
when you need another authorized member.

## Working in it

1. Create a codespace on this repo (2-core default; it's a big tree —
   the prebuild snapshot is what makes starts fast).
2. `cd <repo>` — submodules start **detached** at the recorded SHA.
   `git checkout main` (or your branch) before editing.
3. Commit and push **from inside the submodule**; that repo's own
   rules (worktrees, PRs) still apply.
4. Bumping the umbrella's recorded SHAs is a separate, optional commit
   here — do it when you want the fleet snapshot to move, e.g.
   `git submodule update --remote && git commit -am "sync fleet"`.

Lifecycle note: `updateContentCommand` (runs during prebuilds, skipped
on snapshot creates) does submodule init only. Nix is installed in the
image but deliberately **not** warmed at startup — realizing a repo's
dev shell was the entire cold-start cost (~15-25 min) and re-ran
unreliably from snapshots. Shells realize lazily, per repo, on first
`direnv`/`nix develop` inside the codespace; you pay it once, only for
the repo you're actually working in. `postCreateCommand` is just a
fast version check.

## Codespaces discipline (GitHub Pro: 180 core-hours + 20 GB storage/mo)

- Prebuilds: Settings → Codespaces → Prebuilds, trigger **on push**,
  branch `main`. They run on Actions minutes — free/unlimited here
  because this repo is public.
- **Stop, don't delete** between sessions; delete when a workstream
  ends. This codespace is large; watch the 20 GB storage meter.
- Secrets only via Codespaces secrets, never in the devcontainer config.
- Not for daemons (idle-stop) or GPU work (none; that's Modal's job).
