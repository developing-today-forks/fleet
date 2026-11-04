# Execution surfaces — where fleet work runs

The fleet has three places work can execute: the **laptop**, **GitHub
Actions**, and **Codespaces**. Work is divvied between them by *state
and supervision*, not by which repo it touches:

- If it holds state, needs a rendered secret, or supervises something
  live, it runs on the **laptop**.
- If it is stateless, reproducible, and parallel, it runs in **GitHub
  Actions**.
- If a human or an agent needs to sit inside it and drive it live, it
  runs in a **Codespace**.

Every recurring job in the fleet names its surface when it is created.
When a job seems to belong nowhere, that is a design smell — surface it,
don't quietly run it wherever is convenient.

## The laptop (amd-6) — stateful, secret-bearing, live

The laptop is the fleet's machine of record. It owns:

- **Deploys and activations** — home-manager generations and every
  switch; a deploy is a laptop act, verified from the laptop.
- **Long-running services** — the pm-stack (dispatch, aggregator,
  git-sync), the opencode server, OpenChamber, the mcpx daemon, Kaneo
  and the rest of the pm stack. Services are supervised here, nowhere
  else.
- **Primary clones** — `~/git/*` primaries are deploy sources; work
  happens in worktrees, and a primary's dirt is never discarded by a
  bystander.
- **Secrets in use** — anything needing SOPS/Bitwarden-rendered
  credentials, and anything that must reach the tailnet or the LAN.

Nothing scheduled or stateful may move off the laptop without changing
this document first.

## GitHub Actions — stateless, reproducible, parallel

All fleet repos are public, so hosted runners are free and unlimited.
Actions owns:

- **Clean-room build proofs** — a build that must not be able to see
  the laptop's state (dirty trees, warm caches, staged work) runs here.
- **Scheduled health checks** — cron-driven verification that is pure
  function of a commit (see the umbrella verification below).
- **Container builds** — the `fleet-build` image pipeline
  (`fleet-build-variant.yml`, every 30 min) publishes
  `ghcr.io/developing-today/fleet-build` and advances the umbrella pins.
- **Ad-hoc cross-repo jobs** — through the generic dispatch runners
  below.

Push-triggered workflows in `developing-today/code`,
`developing-today/opencode`, and `developing-today/openchamber` stay
**disabled** (Drew, 2026-11-02); Actions work there is dispatched,
scheduled, or called — never push-triggered.

### The generic runners

Two reusable runners take *repo + command* jobs against an allowlist,
so an agent or a human never re-implements checkout + validation:

| | `fleet-run` | `org-run` |
|---|---|---|
| Home | `dezren39/fleet`, `.github/workflows/fleet-run.yml` | `developing-today/code` |
| Scope | personal / fleet repos | developing-today org repos |
| Triggers | `workflow_dispatch`, `workflow_call` | `workflow_dispatch`, `workflow_call` |

Both share one job model. The `jobs` input is a JSON array of entries
in three shapes:

- **Fan-out** — `{"command": "…", "repos": [{"repo", "ref?", "depth?"}]}`:
  one leg per repo, the same command in each.
- **Together** — `{"command": "…", "together": [{…}, …]}` (≥2 repos):
  exactly one leg; the repos are cloned side-by-side under
  `repos/<basename>` and the command runs once from the workspace
  root, for cross-repo work.
- **Flat** — `{"repo", "ref?", "depth?", "command"}`: exactly one leg.

`ref` is a branch, tag, or SHA (blank = the repo's default branch).
`depth` is the fetch depth (absent = 1, 0 = full history — the escape
hatch for bisection/archaeology). Legs run in parallel with fail-fast
off, each in the published `ghcr.io/developing-today/fleet-build:full`
image, each capped by `timeout_minutes` (5–120, default 60), and the
expanded matrix is capped at 32 legs. `fleet-run` additionally offers a
single-shot dispatch form (`repo` choice + `ref` + `command`).

`fleet-run`'s allowlist is the five core fleet repos —
`developing-today/code`, `developing-today/opencode`,
`developing-today/openchamber`, `dezren39/nix`, `dezren39/fleet` —
plus the fleet umbrella's public members: `developing-today/zettel`,
`developing-today/.github`, `developing-today/zulip-archive`,
`developing-today/hardware-doc`, `dezren39/zettel`,
`dezren39/hatch`. The umbrella's private members (`dezren39/cairn`,
`dezren39/hatch-personal`) are deliberately **not** on it: no
credential available to Actions can read them, so no Actions job may
pretend to verify them.

### The recurring proof: fleet umbrella verification

`.github/workflows/fleet-umbrella-verify.yml` runs **twice daily**
(06:23 and 18:23 UTC) and on dispatch. It is the standing proof that
the split above works:

1. **plan** reads the umbrella's submodule pins off the run's commit.
2. **verify** calls `fleet-run` once per public member, pinned at
   exactly that SHA, shallow: each leg checks the member out and
   asserts `HEAD` equals the recorded pin — the pin resolves, fetches,
   and is current. The private members are verified as *recorded*
   (a full 40-hex pin exists in the tree) and reported as
   recorded-only; if umbrella membership ever drifts from the
   workflow's lists, the plan job fails loudly instead of silently
   dropping a member.
3. **smoke** pulls `ghcr.io/developing-today/fleet-build:full` and
   runs the fleet's own container smoke — the same command the
   variant pipeline gates on — so the published image's defining
   tools (go, git, jq, nix) are proven present.

## Codespaces — interactive and overflow seats

Codespaces are seats, not servers. They are for:

- **Anywhere access** — a full environment from a browser or phone.
- **Disposable per-branch work** — clean-room PR/sweep verification on
  a branch, deleted when the branch merges.
- **Overflow seats** — a live session while the laptop is asleep or
  busy (knowing idle-stop will pause it).

Posture:

- **≤ 3 live codespaces**, default 2-core machine; keys only via
  Codespaces secrets.
- **Delete on merge** — a codespace belongs to a branch, not to a
  person or a project.
- **Idle timeout ~15 minutes**; a codespace that must not stop is a
  laptop job wearing a costume.
- Bounded by the Pro plan's **180 core-hours/month** (90 clock hours
  at 2-core, 45 at 4-core). Steady, scheduled, or daemon work is
  *never* Codespaces work — that is what the laptop and Actions are
  for.

## Routing table

| Job class | Surface | Why |
|---|---|---|
| PR verification / clean-room proof | Actions (`fleet-run` / `org-run` legs) or a Codespace seat | Must not see laptop state; reproducible from the commit |
| Scheduled health checks | Actions cron | Pure function of a commit; free on public repos |
| Ad-hoc cross-repo jobs | Actions (`fleet-run` together / fan-out) | Several repos, one command, no state |
| Deploys & home-manager activations | Laptop | Stateful, secret-bearing, generation-managed |
| Long-running services (pm-stack, opencode, OpenChamber) | Laptop | Supervision and state live here |
| Exploratory / interactive sessions | Codespace (or the laptop's opencode) | A driver sits in it; disposable |
| Anything needing tailnet/LAN or SOPS-rendered secrets | Laptop | Only the laptop holds those keys and routes |
