# Stabilize `list_ids` in timer assignment snapshots (UUIDs, not local integers)

**Status: implemented 2026-04-23.** Desktop write-path (dashboard schedule +
plan auto-create) now translates local IDs to UUIDs at the Rust write edge in
`create_timer_assignment`; a new `get_list_uuid_to_local_map` Tauri command
backs the session-runner read path. CLI and server were already UUID-ready.
Legacy `number[]` snapshots still render via a fallback branch in
`session-runner.tsx::getListIds` — they are not backfilled.

**Follow-up 2026-04-24:** Same bug class surfaced in the `settings` KV store.
The `pre_distraction_list_ids` setting (used by the "No distractions today"
day-view badge) stored raw local integers. A user's setting contained `[3]`
from a past local-ID space; current local lists were `4, 5, 6`, so
`resolve_timer_list_targets([3])` silently returned empty apps/domains,
`is_pre_distraction` had zero patterns to match, and the badge was permanently
green even with reddit visits present in `activity.db`. Fixed in
`components/dashboard/pre-distraction-status.tsx` by storing UUIDs with a
lazy legacy-integer migration on load. **Lesson: any persisted value shaped as
`number` / `number[]` that references a local-ID space is suspect — audit
other `settings` keys and anything written to disk or sent to server.**

_Follow-up doc captured 2026-04-23 after a live incident. Picks up where the
commit-kit-cli / distraction-list work left off._

## Context

`scheduled_commitments.contract_snapshot.list_ids` currently stores **local
SQLite integer IDs** — the autoincrement PKs from `commitkit-desktop`'s local
`lists` table. This breaks silently when:

- A list is deleted and recreated (new local ID, old snapshot points at the
  missing one).
- The user schedules on one machine and runs on another (local IDs don't
  agree across devices).
- The user reinstalls or resets the local DB (autoincrement restarts).
- Any frozen snapshot outlives the local-ID space that produced it.

When it breaks, `session-runner.tsx::resolvedLists = lists.filter(l =>
snapshot.list_ids.includes(l.id))` returns `[]` → "No distractions configured"
warning with no obvious cause.

### 2026-04-23 incident

User's AM Kickstart timer refused to start with "no distractions configured".
Investigation:

- Server: `contract_snapshot.list_ids: [3, 2, 1]` (from some prior machine).
- Server `lists.client_id` for this user: `18`, `19`, `20`.
- **Current local `lists.id`s on this machine: `4`, `5`, `6`.**

The three numbers were all different, from three different historical
local-ID spaces. Patched manually via SQL:

```sql
UPDATE scheduled_commitments
SET contract_snapshot = jsonb_set(contract_snapshot, '{list_ids}', '[4,5,6]'::jsonb, true)
WHERE id IN ('44a58a75-…', 'b7d9414d-…');
```

Key takeaway: **`client_id` on the server is not a reliable bridge to
current local IDs either.** Only list UUIDs are stable.

## The stable identifier already exists

Lists sync to server with a UUID (`lists.uuid` on local, `lists.id` on
server) and a `client_id` (historical local integer). The helpers
**`build_list_uuid_to_local_map`** and **`build_local_to_list_uuid_map`**
already exist in `commitkit-desktop/src-tauri/src/db_operations.rs` — they're
used for template sync per the repo's cross-device sync rules (see
`commitkit/CLAUDE.md`).

**Snapshots should store UUIDs. Local integer IDs should only exist at
the read edge.**

## Scope

1. **Write path**: when creating a timer assignment, translate local
   list_ids → UUIDs before putting them in the snapshot.
   - Ad-hoc already does this: `commands.rs::start_ad_hoc_timer` uses
     `build_local_to_list_uuid_map`. Confirm and extend to other call sites.
   - Dashboard schedule (`components/dashboard/dashboard.tsx:340`):
     currently `list_ids: template.list_ids` — raw local integers. Translate.
   - Plan-requirement auto-create (`commands.rs:906-956`): uses
     `tmpl.list_ids` directly. Translate.
   - CLI (`commitkit-cli`): audit `stake.rs::create_timer_assignment` and
     the `session.list_ids` population in `main.rs`.

2. **Read path**: at the consumer, translate UUIDs → local integers
   before filtering.
   - `session-runner.tsx::getListIds()` — currently treats
     `snapshot.list_ids` as locals. Needs to map UUID-shaped values
     (strings) through a resolver fetched on mount (new Tauri command that
     returns the UUID → local map).
   - Rust `rule_pusher.rs::build_rules_from_db` — calls
     `resolve_session_targets` which uses `session.list_ids` (local).
     Decide whether the session row stores UUIDs or locals; likely still
     local for the running timer, UUIDs only in frozen snapshots.
   - `timer_eval.rs::build_rules` — same question.

3. **Migration for existing snapshots**: **lazy only.**
   - The 2026-04-23 incident confirms that a one-shot backfill walking
     `lists.client_id ↔ lists.id` would be **wrong** — `client_id` is just a
     snapshot of _some past_ local-ID space and doesn't reconstruct the
     current one. It cannot be trusted as a translation source.
   - Approach: consumers treat `number[]` values as legacy locals (old
     format) and `string[]` / UUID-shaped values as new. New writes always
     use UUIDs. Stale old rows either get manually patched (as we did) or
     tolerated.

4. **Session/session_rows storage**: `timer_sessions.list_ids` (local
   SQLite) is fine as local integers since it's per-machine. Don't touch
   unless the refactor forces it.

## Files likely touched

- `commitkit-desktop/src-tauri/src/commands.rs` — write-path translation in
  schedule / ad-hoc / plan-requirement handlers.
- `commitkit-desktop/src-tauri/src/db_operations.rs` — expose UUID resolver
  via Tauri command.
- `commitkit-desktop/components/dashboard/dashboard.tsx` — schedule flow
  uses translated UUIDs.
- `commitkit-desktop/components/timer/session-runner.tsx` — `getListIds`
  resolves UUIDs → local.
- `commitkit-desktop/src-tauri/src/rule_pusher.rs` /
  `src-tauri/src/timer_eval.rs` — if they read `snapshot.list_ids`, same
  resolution.
- `commitkit-cli/src/stake.rs`, `src/main.rs`, `src/eval.rs`,
  `src/rules.rs` — write + read path.
- `commitkit-server/src/domain/commitment-types.ts` — `list_ids` field
  direction (`set_add_strict`) still works for UUIDs. No registry change.
- Tests: `routes-timer-assignments-ad-hoc.test.ts` + new cases; a
  migration-shape regression test.

## Verification

- Schedule a timer from machine A, open the session runner on machine A —
  lists resolve.
- Schedule on A, delete + recreate a list locally, open the runner — lists
  still resolve (UUIDs stable).
- Old `active` rows in prod with integer `list_ids` still render via the
  legacy number-path.
- `cargo check` / `pnpm type-check` / `pnpm test` clean in all three
  projects.

## Relevant history

- `rule_pusher.rs::build_rules_from_db` + `db_operations::resolve_session_targets`
  is the canonical union-resolution path — reuse, don't parallel.
- `commitkit-cli` schema gate at v25; bump if any migration is introduced.
- `/api/violations/timer` server route accepts `assignment_id` already (see
  `routes-violations-timer.test.ts`); keep using it.
- This work unblocks the broader "snapshot refreshing on template edit"
  follow-up too — same pattern (freeze contract, translate at read), same
  resolver infrastructure.
