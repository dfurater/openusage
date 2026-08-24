# Account-First Multi-Account Plan

The execution plan for multi-account Claude/Codex support, replacing the closed PR #1014
(branch `claude/provider-management-ux-780d96`, continued on `agent/multi-account-cli-pr1014`).
Those branches stay alive as **cherry-pick material** — most of their auth-store scoping, discovery
internals, swap timeline, iCloud remapping, and ~4k test lines port into the phases below.

## Why the restart

PR #1014 keyed the default card by *location* (the default home) and every extra account by
*identity*. Review traced nearly every P1 bug to that split: the default card's identity is mutable,
so the branch accreted ~1.5–2k lines of guard machinery (same-account folds, duplicate suppression,
launch gating, history withholding) defending a structural flaw — guards its own follow-up plan
would then delete. Since none of it ever shipped, no user has state that needs the staged
migrate-shadow-flip choreography. This plan flips to the account-first model **before** any
multi-account discovery ships, so the guards never get written.

## Target model

Every card is an **account**: an opaque identity key with a stable record id minted at creation.
Places an account is signed in are **sources** (default home, config dir, Desktop/Cowork, and later
cswap or Codex homes) attached to its record. "Default" is only a badge on the source that currently
occupies the standard home; it never determines a card's identity, credentials, ordering, or history.
A source must prove the account and organization it belongs to before a runtime can use it.

An account with no available verified source is hidden, but its record, custom name, layout, and
pins stay intact so they return when the account becomes available again. There is no Remove
Account action. Newly discovered accounts are enabled, and users can rename any observed account.

### The migration-killing decision

The account occupying the default home at conversion time **keeps the bare id (`claude`, `codex`)
as its permanent record id**. Existing layout keys, pins, histories, cache entries, and integrations
therefore stay valid. If account A originally owns `claude`, then account B signs into the default
home while A remains signed into Desktop or a custom config dir, A's `claude` runtime follows A to
that source. B receives `claude@<hash8>` and a runtime bound to the default home. Neither card
borrows the other's credentials or history.

The bare id also names its provider family in CLI and HTTP requests: plain string matching returns
the exact card plus every other card in that family. It is never resolved by checking which account
currently holds the default badge.

### Why the first Phase 2 attempt was reverted

The earlier implementation kept a hardcoded default-home Claude runtime and added account-owned
runtimes only for extra cards. When the default login changed, the bare card fetched account B's
credentials while its registry record, name, and history still belonged to account A. A guard then
hid A completely when it remained available from another source. Cowork identity matching also
treated an organization-less user id as compatible with multiple organizations.

The replacement builds **every** observed Claude runtime from its account record, including the
bare-id runtime. Refreshes verify their source identity before loading or publishing usage. Same-user
personal and work organizations remain distinct, and unidentified or ambiguous Cowork sandboxes are
excluded instead of being guessed. A lightweight watcher notices default-login changes while the app
is running and replaces the immutable runtime graph after a verified account/source change.

## Phases

Docs and regression tests land with each slice. Account ownership, source verification, history
routing, and live account changes must ship together; splitting those invariants across later phases
recreates the reverted implementation's failure.

### Phase 0 — Standalone reliability (no model change, ~300 LOC)

- Shell-environment snapshot: discovery-grade env facts survive a slow login shell
  (cherry-pick `22c8e97`).
- File splits along provider seams where they help review (`c96fc75`, as needed).
- Exit: beta with zero behavior change beyond launch reliability.

### Phase 1 — Account-first core, single account per family (~800 LOC)

- `ProviderAccountsStore` (`openusage.providerAccounts.v2`): account records with id, family,
  identityKey, label, sources (+ badge), and preserved historical tombstones. Existing v1 records
  are imported once, and their legacy mirror is projected into a shape older app versions can
  still decode; v2 stays authoritative across a downgrade and later re-upgrade. Port from `e052ef9`, dropping the
  shadow-comparison half — the registry is authoritative from day one.
- Default-home identity reading for Claude and Codex (the proven slice of discovery — **no
  candidate scanning yet**). Resolved identity attaches the default source; unresolved leaves the
  family rendering its current state.
- Cards render from account records rather than an independently constructed default-home runtime.
  With exactly one account per family this remains visually unchanged.
- CLI + local HTTP API answer ids by plain string matching (family id → all its cards, always the
  multi-provider shape; unknown id → 404). One deliberate `/v1` break — `/v1/usage/:id` returns an
  array — made now, before multi-account ships, instead of aliasing forever.
- Snapshot-cache identity stamp (v9): cached values remember the producing account; a swap between
  launches discards the stale entry instead of painting it under the new account (port `fef9ad0`).
- Hide unavailable accounts while preserving their records, custom names, layouts, and pins.
- Exit: beta soak; logs confirm identity-resolution rates in the wild; existing users see nothing.

### Phase 2 — Claude multi-account: config-dir discovery (~1,200 LOC)

- Candidate scan (dot-dirs at `~`, dirs under `~/.config`), identity-extraction-is-validation,
  support-trail log lines. Port the discovery internals; **omit** fold/suppression plumbing — a
  candidate naming a known account just attaches as another source/log root on that record, so
  duplicate cards are structurally impossible.
- New account → new record → enabled card named by account label ("Claude — Sunstory"); layout
  inherits the family's default metrics, while new pins are never seeded.
- Scoped `ClaudeAuthStore` (per-config-dir keychain names), per-account spend from each home's logs.
- iCloud identity routing: `PeerHistoryRemapper`, account-identity matching, v1-peer histories to a
  family bucket rendered as device-labeled remote-only slices. Required the moment two accounts can
  exist.
- Every runtime, including the bare-id account, binds to its own verified default-home or config-dir
  source; swapping the default login never changes another account's identity.
- Exit: real two-account tests cover both login directions, custom names, CLI/API output, and
  account-specific spend.

### Phase 3 — Claude: Cowork / Desktop accounts (~500 LOC)

- Cowork sandbox walk with exact account-plus-organization identities; verified sandboxes attach
  to their account's log roots, and a distinct account becomes one organization-pinned Desktop card.
- An unidentified sandbox or organization-less identity shared by multiple organizations stays
  unassigned. A truncated walk with multiple accounts withholds Cowork spend until it can be routed
  safely.
- Desktop accounts use the same record-owned runtime graph as CLI accounts, including an existing
  bare-id account that moves from the default home into Desktop.

### Phase 4 — Claude: cswap (~500 LOC)

- Vault slot discovery: each parked slot is a source of its account; the active slot is whoever
  holds the default badge.
- Switch-log timeline partitions the shared home's spend logs per account.
- A swap is the badge moving between records. The running app detects the changed source identity,
  rebuilds its account graph, and keeps existing ids, layouts, and names attached to their accounts.

### Phase 5 — Codex multi-account + per-card resets (~700 LOC)

- **5a:** `CODEX_HOME` candidate scan with the strict identity rule — `tokens.account_id` or the
  id_token's ChatGPT account claim; a credential file that can't name its account never becomes a
  card (port `93e741e`). Scoped auth stores, per-identity log-root grouping, and the
  `CodexResetClaimRouter` (port `b6be1b1`) so every account's row claims its own reset credits from
  day one.
- **5b (separate if needed):** keyring-mode homes — an unverified keyring source claims no account
  until the one-time post-launch account-scoped read binds it (`CodexHomeIdentityCache`). The
  nichest slice; keeping it out of 5a keeps 5a simple.

### Phase 6 — Attribution polish (small)

- Pi spend attribution routed through the resolver to the badge holder.
- Family-keyed telemetry rollups (`accounts_per_family` gauge).
- Total Spend family grouping/tinting if still wanted (see `c6a63eb` on the old branch for why
  plain size order won before).

## Confirmed owner decisions

1. The first account observed at the default home permanently keeps the bare provider id.
2. An unlabeled additional account falls back to its stable short-hash id and can be renamed.
3. Newly discovered accounts are enabled automatically.
4. Unavailable accounts are hidden without losing their saved state; there is no Remove Account UI.

## Verification

- Per phase: `swift build` + full `swift test`; new suites land with their phase.
- Live: `script/build_and_run.sh`, then `~/Library/Logs/OpenUsage/OpenUsage.log` — discovery trail,
  exact organization identities, account-bound runtime sources, and live graph-rebuild lines.
- Swap the default CLI login in both directions while the app remains open; the original bare-id
  account must follow its remaining config-dir/Desktop source, and the new default account must
  keep its own hashed id, credentials, layout, and spend.
- Beta release per phase via the release-swift skill; soak before the next phase merges.
- CLI/API: `openusage claude` (alias) and `openusage claude@<hash>` (direct);
  `curl 127.0.0.1:6736/v1/usage/claude` echoes the requested id.
- iCloud: two-machine check once Phase 2 lands (migrated writer + old reader and inverse).
