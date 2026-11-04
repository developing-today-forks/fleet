# Fork migration plan — developing-today → developing-today-forks (+ pure-clone archive move)

Status: **EXECUTED 2026-11-04** — Drew approved execution of the §3
real-fork move at 07:02 CST ("yes do it all"); the §8 archive move was
executed earlier the same day. Executed records: §8 (archive) and §9
(real forks) at the end of this document. Companion docs: `docs/execution-surfaces.md`
(surface routing), `docs/placement.md` in the fleet copies (surface
registry).

## 0. Facts on the ground (verified 2026-11-04)

- Source org: `developing-today` (free plan). Forks org:
  `developing-today-forks` (87 repos, 83 of them forks; Drew is admin).
- Fleet copies already stood up: `developing-today/fleet` (fork of
  `dezren39/fleet`, 2026-11-04) and `developing-today-forks/fleet`
  (same parent, 2026-11-04, head == upstream head at creation).
- The **developing-today GitHub App is NOT installed on
  developing-today-forks** — that org's installations are `claude` and
  `developing-today-backup` only. Installing the app there (with access
  to each moved repo) is grants-batch item #1 and a precondition for any
  app-driven write in the forks org.
- Fork-network shape of the moving repos (parents, from the API):
  - `developing-today/opencode` ← parent `dezren39/opencode`
  - `developing-today/openchamber` ← parent `dezren39/openchamber`
  - `developing-today/kaneo` ← parent `usekaneo/kaneo`
  - `developing-today/nix-openclaw` ← parent `openclaw/nix-openclaw`
  The first two are two-level chains (upstream → personal fork → org
  fork). A transfer keeps the repo inside its fork network; default PR
  targeting follows the new owner.

## 1. Classification state

- Planned as REAL forks (this plan): opencode, openchamber, kaneo,
  nix-openclaw — **subject to census confirmation**. The census
  (divergence: ahead/behind vs upstream, unique branches, our open
  PRs) classifies all 15 developing-today forks; if it reclassifies
  one of these four as pure, it drops to the §8 list; if it finds
  another real fork, that repo joins §3 sequencing by reference count.
- `developing-today/fleet` is excluded: it is the placement copy, not a
  migration subject.

## 2. Transfer mechanics (every move, both directions of §8 too)

Per repo:

- [ ] Snapshot: default-branch head sha, open issue/PR counts, Actions
      secret NAMES (values are write-only), webhook URLs, app
      installations, branch-protection/settings summary, deploy keys
      and outside collaborators if any.
- [ ] Announce + start the write-freeze window (§5).
- [ ] Transfer as repo admin (user token — the app has no
      administration permission):
      `POST /repos/developing-today/<repo>/transfer` with
      `{"new_owner": "developing-today-forks"}`. When the same admin
      controls both orgs no acceptance step should be needed; if a
      transfer lands pending, accept it from the forks-org side.
- [ ] Verify: repo resolves under the new owner, default-branch sha
      identical to the snapshot, issues/PRs/branches/tags/releases
      intact (transfer carries all of them).
- [ ] **Hold the old name.** Do not create any repo named `<repo>`
      under developing-today afterwards (see redirect limits).

Redirect behavior and its limits:

- Web and git URLs (`github.com/developing-today/<repo>`, clone /
  fetch / push over https and ssh) redirect to the new location
  indefinitely **while the old name stays unclaimed**.
- Most REST endpoints answer with a redirect to the canonical URL;
  clients should still be repointed (§4) — the redirect is a bridge,
  not the end state.
- **Limit:** creating a new repo at `developing-today/<same name>`
  permanently kills the redirect — the old URL then serves the new
  repo. Any future fresh fork at the old address is a deliberate,
  announced cut, never a side effect.
- Nix `github:` fetchers in flake.lock pin owner/repo + rev and fetch
  through the redirect during the gap. Same rule: bridge only; the
  repoint + relock in §4 ships inside the move window.

## 3. Sequencing (least-referenced first, one repo per window)

1. **nix-openclaw** — zero load-bearing references found (no flake
   inputs, no pm-stack hits; only historical hatch-personal scratch
   logs). Moves first as the transfer dress rehearsal.
2. **kaneo** — references live in the pm-stack aggregator (§4). The
   kaneo *service* repair (code#5398, aggregator sign-in 500) lands
   first; the repo move must not be conflated with that breakage.
3. **openchamber** — flake inputs in nix + code, umbrella gitlink,
   pm-stack projector/dispatch config. Its §4 repoint set is staged
   before the window opens.
4. **opencode** — most referenced (flake inputs in nix, code, *and*
   openchamber; umbrella gitlink; dispatch config; daily repo-health
   writes). Moves last, shortest freeze, repoints pre-staged.

Cascade rule (mcpx → opencode → openchamber → nix): moving opencode
changes openchamber's pinned input URL; nix pins both repos. Repoint
PRs are prepared in advance and merge inside the same window in
consumer order — openchamber's lock repoint first, then code's, then
nix's — each proven by a lock fetch/resolve check before the next
lands. Redirects bridge any skew inside the window; nothing waits on
the next cascade round.

## 4. Reference inventory (measured 2026-11-04)

Counts are file/node hits for the literal `developing-today/<repo>`
string plus parsed flake.lock nodes (owner == developing-today).

### opencode

- `dezren39/nix`: flake.nix input (1); flake.lock node `opencode`
  rev `2d912e02fce3`. Prose/skill refs in the same repoint PR:
  systemPackages.nix, configuration.nix, justfile, ARCHITECTURE.md,
  docs/services.md, planning/README.md, .agents/skills/*.
- `developing-today/code`: flake.nix input (1); flake.lock nodes
  `opencode` rev `4175c630bf83` and `opencode_2` rev `ae5d592093e8`.
  pm-stack: `pm-stack/dispatch/src/config.ts`,
  `pm-stack/dispatch/src/github.ts` (live dispatch config),
  `pm-stack/projector/` (README, .env.example),
  `pm-stack/ready-for-agent/config.json`,
  `pm-stack/kaneo-projects.json`, `scripts/program_tending.py`,
  repo-universe tooling + dispatch tests.
- `developing-today/openchamber`: flake.nix input (1); flake.lock
  node `opencode` rev `4175c630bf83`.
- `dezren39/fleet`: `.gitmodules` — submodule `opencode` URL.
- Muse surfaces: hatch-personal cron definitions and the
  repo-health goal workspaces name `developing-today/opencode` in
  sweep prompts. Repoint the definition files first, then push into
  the live jobs (cron definitions are truth).

### openchamber

- `dezren39/nix`: flake.nix input (1); flake.lock node `openchamber`
  rev `caf27a329ea5`; casks.nix + docs prose.
- `developing-today/code`: flake.nix input (1); flake.lock node
  `openchamber` rev `794e5f5c260e`. pm-stack: dispatch
  `src/config.ts` + `src/github.ts`, projector fixtures/tests,
  `pm-stack/ready-for-agent/config.json`,
  `pm-stack/kaneo-projects.json`.
- `dezren39/fleet`: `.gitmodules` — submodule `openchamber` URL.

### kaneo

- `developing-today/code`: `pm-stack/aggregator/src/program.ts`
  (aggregator source list), `pm-stack/aggregator/test/board-in-flight.test.ts`
  (fixture), `doc/fleet/repo-universe.yaml`.
- No flake inputs, no umbrella gitlink.

### nix-openclaw

- No references found in code, nix, openchamber, or fleet.
  Hatch-personal scratch logs only (historical; leave them).

### Global (all moves)

- fleet-place surface registry (`docs/placement.md` in the fleet
  copies): add the developing-today-forks surfaces for each moved
  repo; agents keep the same interface.
- Codespaces repository grants naming the old repos: re-check after
  each move (see the standing devcontainer-grants question).

## 5. Freeze windows and coordination

- The repo-health sweeps (30-minute cadence) and the fleet lanes
  write to opencode/openchamber continuously. Per repo: announce,
  pause that repo's lanes (pm-dispatch), ~15-minute freeze:
  snapshot → transfer → verify → merge staged repoint PRs →
  unpause. One repo per window, never two at once.
- opencode's window additionally avoids the daily opencode cron
  firings (07:12 / 08:12 America/Chicago).

## 6. What does NOT transfer (re-provision checklist, per repo)

- [ ] Actions secrets — re-provision from Bitwarden/SOPS at move
      time (values are unrecoverable from GitHub):
      - opencode: `REPO_AUTOMATION_TOKEN` (1)
      - openchamber: `ANDROID_KEYSTORE_BASE64`,
        `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
        `ANDROID_KEY_PASSWORD`, `REPO_AUTOMATION_TOKEN` (5)
      - kaneo: none found. nix-openclaw: re-check at move time.
- [ ] Org-level secrets: the GHCR PAT is a developing-today ORG
      secret; org secrets do not follow a repo across orgs. Check
      each moving repo's workflows for org-secret consumption and
      re-provision at repo level or forks-org level.
- [ ] App installation: developing-today app installed on
      developing-today-forks with access to the moved repo BEFORE
      app-driven writes resume there (grants batch).
- [ ] Webhooks: re-create/verify per repo. (Kaneo's app webhook
      config keys repos by id — ids survive transfer; owner-named
      URLs get checked.)
- [ ] Actions settings / branch protection: do not transfer.
      Re-apply the fleet posture in the new home — in particular
      push-triggered workflows in opencode/openchamber stay
      DISABLED (Drew's standing order), and fleet mains keep
      required status checks disabled.
- [ ] Codespaces settings/grants, deploy keys, outside
      collaborators: re-add from the §2 snapshot where present.

## 7. Rollback

- Transfer back (`POST /repos/developing-today-forks/<repo>/transfer`
  → `developing-today`) works while `developing-today/<repo>` remains
  unclaimed — the forward transfer is what frees it, which is the
  second reason §2 holds the name.
- Clean rollback window = until the §4 repoint PRs merge. After
  that, rollback = reverse transfer + revert the repoint PRs.
  Mechanical either way; transfers lose nothing in either direction.

## 8. Pure-clone archive move (parameterized checklist)

- Archive org: `developing-today-vendored` — resolved by Drew
  2026-11-04 (picked over `developing-today-vendor`).
- Transfer list: every developing-today fork the census classifies
  PURE CLONE. The list is deliberately not hardcoded in this plan —
  it lands from the census classifications (divergence evidence per
  repo), and each listed repo gets its own row there.
- Per repo, before transferring:
  - [ ] Reference check: code-search `developing-today/<name>`
        across developing-today/code, dezren39/nix,
        developing-today/openchamber, dezren39/fleet `.gitmodules`,
        and the pm-stack configs.
  - [ ] No references → transfer directly (mechanics per §2,
        destination `developing-today-vendored`).
  - [ ] Referenced → repoint the references in the same pass
        (§4 mechanics), then transfer.
  - [ ] Run the §6 checklist anyway (expected empty for pure
        clones, but cheap): secrets names, webhooks, installations.
  - [ ] Verify post-transfer + hold the old name (§2).
- EXECUTED 2026-11-04: all 10 census-classified pure clones were
  transferred from developing-today to developing-today-vendored:
  okd, ironic-baremetal-nodes-on-ESXi-Host,
  cluster-api-provider-libvirt, terraform-provider-libvirt,
  nomados, dns, consul-dns, balanced-employee-ip-agreement,
  innovators-patent-agreement, webspace-sdk.github.io. Each was
  reference-gated first (the only fleet references were the
  repo-universe.yaml entries, repointed in developing-today/code
  PR #5426) and verified at the new owner with its default branch
  intact; the old developing-today paths redirect to the new
  locations.
- EXECUTED 2026-11-04 (developing-today-fork, the singular
  embedded-themed forks org): census of all 7 repos; 5 classified
  PURE and transferred to developing-today-vendored — syn-rsx,
  nixos-fhs-compat, call-flake, circuitpython, esp-hosted-mcu.
  Each was reference-gated first (zero references anywhere in the
  code/nix/fleet trees) and verified at the new owner with its
  default branch intact; the old developing-today-fork paths
  redirect to the new locations. Two repos were NOT transferred:
  helper (REAL — a 407-commit lineage divergence from its
  recreated parent, sqwu/helper, plus 7 fork-only branches
  including a Jules session branch and Aug-2025
  dependabot-automation branches, and dependabot activity as
  recent as 2026-02-20) and iffy (PURE by evidence — behind
  TruemarkDev/iffy by 3, ahead 0 — but blocked by a name
  collision: developing-today-vendored already holds a different
  iffy, the wzulfikar/iffy fork moved by the
  developing-today-forks sweep; awaiting a ruling).
- EXECUTED 2026-11-04 (developing-today-forks, the 87-repo fork
  library): full census of all 88 repos — 54 classified PURE and
  transferred to developing-today-vendored: DeepSeek-R1,
  DeepSeek-V3, alejandra, bifrost, comin, controllerbus, dgraph,
  distributed-topic-tracker, dozerdb-browser, dozerdb-core,
  dozerdb-plugin, end_of_eden, flexile, git-agecrypt,
  go-retryablehttp, go-type-to-string, graphipedia, harness2,
  helper, iffy, invoice, jessfraz.files, jessfraz.vim, kdl-go,
  kdl-play, lego, necolas.files, neo4j, neosemantics, neovim,
  nerd-fonts, nix-gl-host, nix-software-center, nixos-installer,
  nixos-rescue, nixvim-flake, pagefind, piraeus-operator,
  porkbun-exporter, prime.files, prime.vim, raspberry-pi-nix,
  slides, ssh-slides, starpc, stork, talhelper,
  terraform-upload-ami, the-monospace-web, treefmt, viper,
  wikidata-neo4j-importer, winget-releaser, xen-orchestra-docker.
  Each was reference-gated first (zero references in the code/nix
  trees or the umbrella .gitmodules) and verified at the new
  owner with its default branch intact; the old
  developing-today-forks paths redirect to the new locations
  (54/54 verified). NOT transferred: 31 REAL forks carrying
  dezren39/app commits or PRs (incl. NvChad, NvChad-custom,
  nixpkgs, home-manager, sops-nix, microvm.nix, server.nix,
  charm, koanf, log, emanote, octto, octto-fork,
  scoop-charmbracelet, terraform-plugin-log-tflog-slog-handler —
  full per-repo evidence in the census record), 2 fleet-internal
  repos (fleet and zig-overlay — parents are dezren39's own),
  and nixos-unattended-installer (PURE by divergence but HELD:
  it is a live flake input — code/flake.nix
  `unattended-installer.url` plus a code/flake.lock node —
  repoint before it can move). Note: the moved wzulfikar/iffy
  fork now occupies developing-today-vendored/iffy, which is
  the collision blocking the singular org's TruemarkDev/iffy
  (recorded above, awaiting a ruling).
- RESOLVED 2026-11-04 (iffy collision): Drew ruled to rename the singular org's TruemarkDev/iffy fork to `iffy-truemark` and move it. Executed the same day: `developing-today-fork/iffy` was renamed to `developing-today-fork/iffy-truemark`, then transferred to `developing-today-vendored/iffy-truemark` (repo id 1162280331; parent `TruemarkDev/iffy`, default branch `main` verified intact). The pre-existing `developing-today-vendored/iffy` (repo id 1162280248, the wzulfikar/iffy fork) was not touched and was verified unchanged.


## 9. Real-fork move — EXECUTED 2026-11-04

All four §3 repos were transferred from `developing-today` to
`developing-today-forks` with the user-token transfer API, in plan
order (nix-openclaw, kaneo, openchamber, opencode), each verified at
the destination against a same-day snapshot: default-branch head SHA
identical, branch/issue/PR counts carried, fork parent intact, and
the old `developing-today/<repo>` path answering with a redirect.

- **nix-openclaw**: head `b4f1c9d0`, 14 branches, 0 issues/PRs. §6
  re-check at move time: no Actions secrets, no webhooks, no deploy
  keys — nothing to re-provision. No fleet references existed.
- **kaneo**: head `1e7cb2d8`, 42 branches, 4 open PRs. No secrets or
  webhooks. Repoint (app PR, merged): developing-today/code #5454
  (aggregator program.ts, board fixture, repo-universe.yaml).
- **openchamber**: head `709ce4b0` (includes its own repoint PR),
  52 branches, 41 issues, 6 PRs. Repoints (app PRs, merged):
  openchamber #1580 (its own opencode flake pin — merged *before* the
  transfer, see deviations), developing-today/code #5463,
  dezren39/nix #1466, dezren39/fleet #65 (.gitmodules). Pinned rev
  `794e5f5c` verified fetchable at the new home.
- **opencode**: head `ce1aec22`, 57 branches, 71 issues, 12 PRs.
  Repoints (app PRs, merged): developing-today/code #5465,
  dezren39/nix #1468, dezren39/fleet #66 (.gitmodules). All pinned
  revs (`4175c630`, `ae5d5920`, `2d912e02`) verified fetchable at the
  new home; openchamber's lock pin resolves against the moved repo.

§6 findings that update the checklist's assumptions: for transfers
where the same admin controls both orgs, GitHub **carried the repo
Actions secrets and webhooks with the repo** — verified by name lists
and unchanged `updated_at` timestamps at the destination
(openchamber's 5 secrets, opencode's `REPO_AUTOMATION_TOKEN`, the
supabase CI webhook on both). Manually-disabled workflow states also
carried (opencode 15, openchamber 4 — the push-workflow posture is
unchanged). No manual secret re-provisioning was needed. There were
no org-level Actions secrets in developing-today and no environment
secrets in either repo, so the many upstream-inherited workflow
secret references (Apple/iOS signing, NPM, Discord, …) had nothing
provisioned to carry — they were unprovisioned before the move and
remain so.

Two deliberate side effects in the repoint PRs: dispatch's
`APP_INSTALLED_REPOS` (developing-today/code) no longer lists
opencode/openchamber — the developing.today app is **not installed
on developing-today-forks** (verified with the fleet-paperwork
helper: no installation for that owner), so both repos are app-dark
until grants item G2 lands; the entries return then.
`pm-stack/kaneo-projects.json` still records openchamber's pre-move
installation id; it resolves with the same G2 install.

Open items after the move:

- **G2** (Drew, needs GitHub sudo): install the developing.today app
  on developing-today-forks with access to the moved repos.
- The `REPO_AUTOMATION_TOKEN` value carried, but the fine-grained
  PAT behind it (`developing-today-code-automation`) is scoped to
  developing-today repos; Drew needs to extend/re-approve it for
  developing-today-forks before automation that spends it there
  works.
- Muse surfaces: hatch-personal cron definitions and repo-health
  goal workspaces still name `developing-today/opencode` (the plan's
  §4 item). Redirects bridge git/API access; the app has no write
  access to hatch-personal, so the definition repoint rides that
  repo's own maintenance flow.
- Codespaces repository grants naming the moved repos: re-check per
  the standing devcontainer-grants question.

Deviations from the plan as written: (1) openchamber's own opencode
repoint merged before openchamber's transfer rather than inside the
opencode window (§3 cascade order) — the app cannot write in the
forks org, so pre-transfer was the only app-authenticated slot; the
dangling-pin window was minutes and no fleet build consumes
openchamber's own lock standalone. (2) The §5 pm-dispatch lane pause
was not invoked; windows were kept to minutes and transfers are
atomic, with redirects bridging in-flight git/API traffic. (3)
Branch counts moved between the morning census and the move-day
snapshots (openchamber 104 → 52, opencode 96 → 57) through the
repos' own branch-cleanup workflows — each transfer was verified
against a fresh same-hour snapshot, not the census.
