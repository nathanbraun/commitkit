---
name: Pre-distraction overlay flow & configurable reset hour
description: Replace the hard-block start gate on `must_complete_before_distractions` timers with an overlay-and-confirm flow, add a configurable per-rule reset hour, and surface preventive overlays at day-reset and mid-day distraction navigation.
---

# Pre-distraction Overlay Flow & Configurable Reset Hour — Design

**Date:** 2026-05-06
**Status:** Design draft; pending review

## Summary

Today, a timer template with `must_complete_before_distractions = true` is gated by a single hard check at session start: if `is_pre_distraction(domains, apps, ...)` returns false, the user gets a blocking toast ("Cannot start — distractions have already been visited today") and cannot run the session. Stale browser tabs left open across the day boundary trigger this gate even when the user closes them immediately.

This spec replaces the hard block with an **overlay-and-confirm** flow that mirrors the active-timer browser-overlay UX, adds two preventive trigger points (day-reset hour and mid-day distraction navigation), and introduces a per-rule `pre_distraction_reset_hour` setting (default 3 AM) so the rule's "today" window doesn't snap to midnight.

The change keeps `must_complete_before_distractions` as a start-time gate (no new during-session enforcement) and reuses the existing monitor overlay infrastructure (`commitkit-monitor` AppleScript/JXA dialog, currently driven by `app_watcher.rs`) for the two preventive triggers. No new charging path. No data-model migrations on the server.

## Context

### The bug

User had ESPN.com open in Chrome from the previous day. New day starts, user sits down, closes ESPN immediately. Tries to start their "Early AM Kickstart" timer (a template with `must_complete_before_distractions = true`). Session refuses to start because the activity DB shows ESPN activity since the day boundary.

### Current implementation (verified)

1. **Rule:** `must_complete_before_distractions: bool` on `TimerTemplate` (`commitkit-desktop/src-tauri/src/models.rs:441`). Stored in the `timer_templates` SQLite table.

2. **Start-time check:**
   - Frontend at `components/timer/session-runner.tsx:162–171` calls `tauri.checkPreDistractionStatus(listIds)` before allowing Start.
   - Backend handler at `src-tauri/src/commands.rs:1487–1494` resolves the template's lists to apps/domains and calls `proof_of_work_eval::monitoring::integration::is_pre_distraction(&domains, &apps, 3, false)`.
   - The `3` parameter is currently hardcoded — its meaning (likely a reset hour offset or grace window) needs to be confirmed during implementation by inspecting the `commitkit-eval` source. The spec assumes it is or will become a reset-hour parameter; if it's something else, implementation adds an explicit `reset_hour: u32` argument.
   - Returns `false` → frontend shows a blocking toast and disables Start.

3. **No during-session enforcement.** Once a timer is running, the rule does nothing. The active-timer overlay (`commitkit-monitor/src/monitor/app_watcher.rs:147–391`) fires for the *running session's* apps/domains via the `domain-rules` push at session start (`src-tauri/src/rule_pusher.rs:121–139`). That infrastructure is independent of `must_complete_before_distractions`.

4. **Monitor knows nothing about scheduled-but-not-active timers.** The wire contract in `commitkit-rules/src/lib.rs` covers active commitment rules + the synthetic "Focus Timer" rule (id=-1). There is no concept of pending or scheduled rules.

5. **Settings storage** exists: `settings (key TEXT PRIMARY KEY, value TEXT)` table, accessed via `db_operations::get_setting` / `set_setting` (`src-tauri/src/db_operations.rs:673–690`). Already used for `device_id` and other prefs.

## Goals

- Make session start resilient to stale tabs that the user has already closed
- Give the user clear, actionable warnings *before* a future before-distractions session is invalidated by an open tab — both at the day boundary and during normal navigation
- Configurable per-rule reset hour (default 3 AM) so late-night browsing on day N doesn't poison day N+1's morning session
- Reuse the existing native overlay infrastructure for triggers that fire outside the desktop app (mid-day visit, day-reset)
- No new charging path, no new server endpoints, no data-model migrations on the server

## Non-goals

- **During-session enforcement** for `must_complete_before_distractions`. The rule remains a start-time concept; if you start successfully and then visit a distraction, the regular active-timer overlay handles it (this is already how things work — a separate concern from this spec).
- **A global, configurable day-reset hour** for screen-time limits, daily progress, etc. The user explicitly scoped the new reset hour to this rule for now. Generalize later only if other features want it.
- Mobile support. Desktop + monitor only.
- Changing the activity-DB schema or monitor's persistence model.

## Architecture

```
                         Trigger 1: Session start
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────┐
│ User clicks Start on a `must_complete_before_distractions`│
│ template. is_pre_distraction returns FALSE because of     │
│ stale activity since pre_distraction_reset_hour.          │
└──────────────────────────────────────────────────────────┘
                                  │
                                  ▼
              ┌──────────────────────────────────────┐
              │ NEW: in-app Tauri modal (replaces    │
              │ the blocking toast). Shows the apps/ │
              │ domains that were detected, asks the │
              │ user to close them, has              │
              │ "Confirm and Start" / "Cancel".      │
              └──────────────────────────────────────┘
                       │ Confirm
                       ▼
              start_timer (existing path) — session begins normally;
              active-timer overlay handles any subsequent distractions

                         Trigger 2: Mid-day navigation
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────┐
│ User opens a distraction app/domain. There is a queued    │
│ timer assignment for today with must_complete_before_     │
│ distractions = true and lists matching this app/domain.   │
└──────────────────────────────────────────────────────────┘
                                  │
                                  ▼
              ┌──────────────────────────────────────┐
              │ Existing monitor overlay (AppleScript│
              │ /JXA), with new copy:                │
              │ "You have a pending session ($name,  │
              │ due $deadline) that requires no      │
              │ distractions today. Continuing will  │
              │ make it unstartable."                │
              │ Buttons: "Go Back" / "Continue       │
              │ Anyway".                             │
              └──────────────────────────────────────┘

                       Trigger 3: Day-reset hour
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────┐
│ At pre_distraction_reset_hour (default 03:00 local),      │
│ desktop checks: is there a queued before-distractions     │
│ assignment for today AND is any matching app/domain       │
│ currently the foreground app on the monitor?              │
└──────────────────────────────────────────────────────────┘
                                  │ both yes
                                  ▼
              ┌──────────────────────────────────────┐
              │ Same monitor overlay, with copy:     │
              │ "Today starts now. You have a        │
              │ session ($name) that requires no     │
              │ distractions, and $app/domain is     │
              │ currently open. Close it now."       │
              │ Buttons: "Close App" / "Dismiss".    │
              └──────────────────────────────────────┘
```

The desktop is the source of truth for "what before-distractions sessions are pending today." It pushes a **pre-distraction watchlist** to the monitor whenever the relevant state changes. The monitor uses this watchlist to fire triggers 2 and 3.

## Data model

### New setting: `pre_distraction_reset_hour`

Stored in the existing `settings` KV table (no migration needed). Value is a string-encoded integer hour `0–23` in **local time**. Default `3` (3 AM). Read on every `is_pre_distraction` call and on monitor watchlist construction.

```rust
// src-tauri/src/db_operations.rs — new helper
pub async fn get_pre_distraction_reset_hour(pool: &SqlitePool) -> Result<u32, String> {
    let raw = get_setting(pool, "pre_distraction_reset_hour").await?;
    Ok(raw.and_then(|s| s.parse().ok()).unwrap_or(3))
}
```

### Wire contract: pre-distraction watchlist

Extend the rules push (currently `commitkit-rules` `RulesPayload`) with a new optional field:

```rust
pub struct RulesPayload {
    pub rules: Vec<CommitmentRule>,
    pub focus_timer: Option<FocusTimerRule>,
    // NEW:
    pub pre_distraction_watchlist: Vec<PreDistractionEntry>,
}

pub struct PreDistractionEntry {
    pub assignment_id: i64,           // server scheduled_commitments.id
    pub display_name: String,         // for overlay copy ("Early AM Kickstart")
    pub due_at_iso: String,           // for overlay copy
    pub apps: Vec<String>,            // resolved app names
    pub domains: Vec<String>,         // resolved domain patterns
    pub reset_hour: u32,              // 0–23, local time
}
```

Empty list = no watchlist (current behavior). The desktop populates this list with one entry per timer assignment scheduled for **today** (per the assignment's `date` column) where the snapshot has `must_complete_before_distractions = true` and the assignment is still in a startable state (not completed, not failed, not cancelled).

The watchlist is rebuilt and pushed:
1. On the existing 30-second rule_pusher heartbeat
2. Immediately whenever a relevant assignment is created, completed, failed, or cancelled
3. Immediately at `pre_distraction_reset_hour` (because "today" just changed)

### No server changes

`scheduled_commitments` already carries the template snapshot, which includes `must_complete_before_distractions`. No new server endpoints; no migration. The desktop computes and pushes the watchlist locally.

## Trigger 1: session start

**Replace** the current hard-block in `components/timer/session-runner.tsx:162–171` with an overlay-and-confirm flow.

### Backend

Add a new Tauri command alongside `check_pre_distraction_status`:

```rust
// src-tauri/src/commands.rs
pub async fn check_pre_distraction_detail(
    pool: State<'_, SqlitePool>,
    list_ids: Vec<i64>,
) -> Result<PreDistractionDetail, String> {
    let (apps, domains) = db_operations::resolve_timer_list_targets(&pool, &list_ids).await?;
    let reset_hour = db_operations::get_pre_distraction_reset_hour(&pool).await?;
    // Returns: is_pre, plus the list of apps/domains that were actually seen since reset.
    // Implementation queries the monitor's activity DB the same way is_pre_distraction does.
    proof_of_work_eval::monitoring::integration::pre_distraction_detail(
        &domains, &apps, reset_hour, false,
    )
}

pub struct PreDistractionDetail {
    pub is_pre: bool,
    pub seen_apps: Vec<String>,
    pub seen_domains: Vec<String>,
    pub reset_hour: u32,
}
```

`pre_distraction_detail` is a new helper in `commitkit-eval` that returns *which* apps/domains were seen, not just a boolean. (The existing `is_pre_distraction` stays — it's still the right primitive for callers that only need the bool, e.g. day-view UI.)

### Frontend

Replace the toast in `session-runner.tsx` with a Tauri-webview modal:

- Title: **"Recent distraction activity detected"**
- Body: "These apps/sites were used since {reset_hour}:00 today: **{seen_apps + seen_domains}**. Make sure they're closed, then confirm to start. Once running, visiting them will fail your session."
- Buttons:
  - **Confirm and Start** → proceeds to `start_timer` (existing path). The session starts; the active-timer overlay handles subsequent distractions normally.
  - **Cancel** → dismisses, no session created.

The modal follows the existing `plan-form-dialog` modal pattern (no shadcn primitives — hand-rolled, per `project_commitkit_desktop_no_shadcn` memory).

### Edge case: no recent activity, but rule still wants confirmation

If `is_pre = true` (no recent distractions seen), the modal does **not** appear and the session starts normally — same as today.

## Trigger 2: mid-day distraction navigation

The monitor already detects when the foreground app or browser tab matches a known rule (`app_watcher.rs:79–100`). Extend that check to also consult the `pre_distraction_watchlist`.

### Monitor-side logic

```rust
// commitkit-monitor/src/monitor/app_watcher.rs (sketch)
fn check_foreground(...) {
    // 1. Existing: check active CommitmentRules and FocusTimer rule
    if let Some(hit) = match_active_rules(...) { fire_overlay(hit); return; }

    // 2. NEW: check pre-distraction watchlist
    if let Some(watch_hit) = match_pre_distraction_watchlist(...) {
        fire_pre_distraction_warning(watch_hit);
    }
}
```

`fire_pre_distraction_warning` reuses the existing JXA overlay code with new copy:

> **"Heads up: pending session at risk"**
> You have **{display_name}** scheduled today (due {due_at_iso}) and it requires no distractions. Visiting **{matched_app_or_domain}** will make that session unstartable.
>
> *Go Back* (default) — closes the app
> *Continue Anyway* — accepts the risk; the session won't be startable today

Critically, this is **informational**, not enforcing. Choosing "Continue Anyway" doesn't charge anything (no money is at stake yet — the session hasn't started). It just means trigger 1 will block the session later, and the user knew.

### Suppression to avoid spam

Once the user picks "Continue Anyway" for a given (assignment_id, matched_target) pair, the monitor suppresses re-firing for that combination for the rest of the day. Reuses the existing per-rule "user_continued" suppression pattern in `app_watcher.rs:147–179`.

## Trigger 3: day-reset hour

A scheduled task on the desktop side, run daily at `pre_distraction_reset_hour`:

1. Rebuild the watchlist for today and push it to the monitor (this happens regardless).
2. Ask the monitor: "is any watchlist app/domain currently the foreground app or active browser tab?" via a new `GET /api/foreground-state` endpoint on the monitor (returns the current foreground app + last-seen browser URL).
3. If yes, push a one-shot overlay command to the monitor.

### New monitor endpoint: `POST /api/show-overlay`

A simple imperative trigger so the desktop can request the overlay on demand without waiting for the monitor's natural foreground-poll cycle:

```
POST /api/show-overlay
{
  "kind": "pre_distraction_day_reset",
  "title": "Today starts now",
  "body": "{app_or_domain} is open and you have {display_name} due today...",
  "buttons": [{"label": "Close App", "action": "quit_app", "target": "Chrome"},
              {"label": "Dismiss",  "action": "dismiss"}]
}
```

Response is fire-and-forget. The monitor renders the overlay using the same JXA path as the existing app-watcher dialog.

### Scheduling

The desktop already has a long-running background task pattern (`checker_service.rs`). Add a new ticker that:
- Computes the next occurrence of `pre_distraction_reset_hour` in local time
- Sleeps until then
- Fires the day-reset check
- Loops

The ticker also re-arms itself if `pre_distraction_reset_hour` changes (settings update).

## Configuration UI

Add a **"Pre-distraction reset hour"** setting in the desktop Settings panel:

- Hour picker (0–23, local time), default 3
- Help text: "When does 'today' start for timers that must complete before distractions? Set this to a few hours before you usually wake up so late-night browsing doesn't carry over."

Persists to the `settings` table. Re-arms the day-reset ticker on save.

## Files touched

### commitkit-desktop

- `src-tauri/src/db_operations.rs` — `get_pre_distraction_reset_hour` helper
- `src-tauri/src/commands.rs` — new `check_pre_distraction_detail` command; rewire existing `check_pre_distraction_status` to read the configurable reset hour
- `src-tauri/src/rule_pusher.rs` — extend the rules POST to include `pre_distraction_watchlist`; add a builder that queries today's pending assignments and resolves their lists
- `src-tauri/src/checker_service.rs` (or sibling) — new day-reset ticker that fires at `pre_distraction_reset_hour`, queries the monitor's foreground state, optionally triggers `/api/show-overlay`
- `lib/types.ts` — `PreDistractionDetail` type; settings type extension
- `lib/tauri.ts` — wrapper for `check_pre_distraction_detail`
- `components/timer/session-runner.tsx` — replace blocking toast with confirm-modal flow
- `components/timer/pre-distraction-confirm-modal.tsx` — new modal (hand-rolled)
- `components/settings/*` — new reset-hour input

### commitkit-monitor

- `src/integration.rs` — accept watchlist-aware queries (likely a new `is_in_pre_distraction_watchlist` helper)
- `src/monitor/app_watcher.rs` — extend foreground-check to consult watchlist; new `fire_pre_distraction_warning` path with the warning copy
- `src/api.rs` (or wherever the HTTP server is) — new `POST /api/show-overlay` and `GET /api/foreground-state` endpoints
- `src/main.rs` — wire the new endpoints

### commitkit-rules

- `src/lib.rs` — extend `RulesPayload` with `pre_distraction_watchlist: Vec<PreDistractionEntry>`; new helpers for serializing the watchlist; bump the wire-format minor version if such a thing is tracked

### commitkit-eval

- New `pre_distraction_detail` function returning seen apps/domains alongside the bool (or extend the existing `is_pre_distraction` signature — TBD during implementation)
- Audit the hardcoded `3` parameter in the existing call site; rename to a clearly-named `reset_hour: u32` if it isn't already

### commitkit-cli

- If the CLI exposes any "must complete before distractions" surface, mirror the reset-hour read from the settings table (the CLI shares the desktop SQLite). Quick check during implementation; likely a small change or none.

## Open questions

1. **The `3` in `is_pre_distraction(&domains, &apps, 3, false)`** — current meaning unclear from desktop code. Implementation must inspect `commitkit-eval` to confirm whether this is a reset hour, a grace window, or something else. If it's already the reset hour, the change is a one-line read from settings; if not, the eval signature gets an explicit reset-hour argument.

2. **Scope of the watchlist**: should it include assignments due *tomorrow* if the current time is past today's `pre_distraction_reset_hour` and the user is browsing late at night? Probably yes — at 11 PM on day N, with a session due 9 AM on day N+1 (whose window starts at 03:00 on day N+1), there's no risk. But at 02:00 on day N+1, the same session's window is about to start in an hour. Edge cases like this are best handled by the watchlist always covering "the next assignment whose window begins ≤ 6 hours from now" in addition to "assignments whose window has already started." Worth deciding during implementation.

3. **What counts as "currently open" for trigger 3?** The monitor's notion of "foreground app" is the frontmost macOS app. A backgrounded Chrome window with ESPN open in a non-frontmost tab is arguably "open" but not "active." Recommend starting strict (frontmost only) and loosening if it under-fires in practice.

4. **Desktop-app-not-running case for trigger 3.** If the desktop app isn't running at the day-reset hour, the ticker doesn't fire. Acceptable for v1 — the user is unlikely to have the monitor running but desktop closed at 3 AM. Note for later: the monitor itself could own the day-reset trigger (with the watchlist already in hand), but that adds complexity not worth taking now.

## Testing

- **Unit (desktop, Vitest)**: confirm-modal renders the seen apps/domains; "Confirm and Start" calls `start_timer`; "Cancel" dismisses cleanly; reset-hour setting reads/writes correctly
- **Unit (Rust)**: watchlist builder produces correct entries given a fixture of scheduled assignments + templates + lists; `pre_distraction_reset_hour` defaults to 3 when unset
- **Manual**:
  - **Bug repro**: stale ESPN tab open across day boundary, sit down, close it, click Start — modal appears, confirm, session runs
  - **Mid-day visit**: have a queued before-distractions session for today, navigate to a distraction app — overlay fires with new copy, "Continue Anyway" suppresses re-firing for the rest of the day
  - **Day-reset**: at 03:00 with a distraction tab in the foreground, overlay fires
  - **Reset-hour custom value**: set hour to 5; activity at 04:00 doesn't poison the 09:00 session
- No new charging behavior, so no Stripe / cron tests are affected

## Migration / rollout

- Default reset hour 3 AM applies retroactively on first read. No backfill needed — the setting is read-with-default.
- Behavior change for existing users: the **hard-block toast disappears** and is replaced by the confirm modal. This is a strict UX improvement (previously the user couldn't start; now they can after confirming) and doesn't need a feature flag.
- Watchlist push is additive in the wire format; older monitor binaries that don't understand the field will ignore it, so the desktop change can ship slightly ahead of the monitor change without breaking. (Verify: the monitor's deserializer must tolerate unknown fields. If `serde` is configured strict, add `#[serde(default)]` to the field on the monitor side first.)
