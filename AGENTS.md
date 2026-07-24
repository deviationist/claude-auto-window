# AGENTS.md — orientation for AI agents working in this repo

Read this before changing code. It captures the architecture, the invariants
that are easy to break, and how to test without burning tokens.

## What this is

A single zsh tool that keeps a **Claude Code 5-hour usage window** perpetually
open. When the window has lapsed it opens a fresh one by driving a **real
interactive** Claude Code session inside a throwaway **tmux** session (send a
trivial prompt → wait for the reply → quit → tear down). It is deliberately
**not** the headless `claude -p` approach — `-p` does not open a 5-hour window.

## Files

| File | Role |
|---|---|
| `claude-auto-window` | The whole tool — one self-contained script (OAuth read + usage fetch inlined). Executable **and** source-able. |
| `claude-auto-window.env.example` → config | Auto-loaded from `$XDG_CONFIG_HOME/claude-auto-window/config` in `_caw_main` (`_caw_load_config`); fills only unset `CLAUDE_AUTO_WINDOW_*` vars (env/flags win). |
| `claude-auto-window@.service` | systemd `--user` template (Linux daemon), keyed on profile via `%i`. |
| `claude-auto-window.plist` | launchd template (macOS daemon), `__HOME__` placeholders. |
| `claude-auto-window.env.example` | Every `CLAUDE_AUTO_WINDOW_*` knob. |

## Architecture (control flow)

- **CLI** `_caw_main` parses flags → sets `CLAUDE_AUTO_WINDOW_*` env → resolves
  the profile list → dispatches to a mode function.
- **Profile resolution** `_caw_resolve_profiles` populates the `_caw_profiles`
  array (order-preserving, deduped by resolved check-dir, first wins + WARN on
  the repeat) from, in precedence order: repeatable CLI `--profile`/`--config-dir`
  > `CLAUDE_AUTO_WINDOW_PROFILES` (comma/space list) > legacy single
  `CLAUDE_AUTO_WINDOW_CONFIG_DIR` > fallback `default`. A **spec** is either the
  literal `default` (unpinned) or an absolute dir. Helpers: `_caw_profile_spec
  NAME` (name→spec, prints — `personal`→`~/.claude-personal`, `work`/`default`→
  `~/.claude` spec), `_caw_profile_dir SPEC` (spec→concrete check dir; `default`→
  `~/.claude`), `_caw_pin_profile SPEC` (`default` ⇒ **unset**
  `CLAUDE_AUTO_WINDOW_CONFIG_DIR`; else pin it) called once before each profile's
  single-profile body runs.
- **Iterated modes are thin wrappers.** `claude-auto-window-{once,run,status,reset}`
  call `_caw_iterate`, which loops `_caw_profiles`, `_caw_pin_profile`s each spec
  into the ambient env, and runs the renamed **single-profile body**
  `_caw_{once,run,status,reset}_one` (byte-for-byte the old single-profile logic).
  It **continues through all profiles on failure** and returns the **first**
  non-zero rc. The **daemon does not** use `_caw_iterate` — it has its own
  per-profile loop (below).
- **Modes:**
  - `_caw_run_one` — fire immediately, **no checks, no jitter**.
  - `_caw_once_one` *(default)* — **early-exit gate first**: read the
    stored `resets_at`; if it's still in the future, return 0 WITHOUT fetching
    (this is what makes a per-minute cron cheap). Otherwise check the window —
    **self-healing an expired access token first** (rc 4 → `_caw_refresh_token`
    → re-check; blind fire only as fallback) — and if closed, **jitter** then
    open. Guards: already-open, **balance gate** (`_caw_plan_exhausted`),
    no-5h-window. Not a flag — always on; `--status` is the live-check escape.
  - `claude-auto-window-daemon` — its own per-profile loop (**not** `_caw_iterate`):
    each wake services **every enabled profile serially** (pin → `_caw_once_one`
    body), tracking a per-profile disable map — `no-window` (rc 70, lifetime
    disable) or `breaker` (rc 3, until the sentinel is cleared; **re-checked
    cheaply each wake** so `--reset` revives a profile with no daemon restart).
    Sleep = **min over still-enabled profiles** of each one's (stored
    `resets_at + POST_EXPIRY − now`, or `INTERVAL` to confirm a just-opened
    window), capped at `MAX_SLEEP`. Not-due profiles cost nothing (stored-
    `resets_at` early-exit, no fetch). Exits **0** (clean; systemd/launchd leave
    it stopped) only when **all** profiles are disabled. Cron can't sleep — it
    relies on the `-once` early-exit gate instead.
  - `_caw_status_one` — print the current session state **plus the balance-gate
    verdict** (`weekly_all=NN% → would fire / WOULD SKIP`, starter model, credits
    line, stored-vs-live `resets_at`) — the daemon health-check.
- **Both `-run` and `-once` open a window via** `_caw_open_window` → which calls
  `_caw_send_starter` and adds the **cheapest-model-with-fallback** retry.
- **`_caw_send_starter`** is the heavy lifter: build launch argv → `tmux
  new-session` running `claude` directly → `_caw_wait_reply` (also auto-accepts
  the trust dialog) → `_caw_quit_and_kill` → `_caw_cleanup_transcript`, the last
  two in an `always {}` block so teardown is guaranteed.
- **`_caw_refresh_token`** is the free self-heal for an expired access token:
  the same tmux launch **minus the prompt and model** (nothing sent → no window
  opened, nothing spent), waiting for `_caw_resolve_token` to turn fresh instead
  of for a reply; identical trust-dialog handling and teardown.
- **Window check** is `_caw_session_active` → `_caw_usage_json` (inlined:
  `_caw_resolve_token` + a `curl` to the OAuth usage endpoint → raw JSON) →
  `.limits[] | select(.kind=="session")`. "Open" = **`resets_at` in the future**;
  `is_active` is deliberately NOT consulted (see Gotchas). Internal rc: 0 open,
  1 closed, 2 no-session-limit, 3 undetermined (network/API), **4 access token
  expired** — on 4, `-once` self-heals via `_caw_refresh_token` (a bare
  prompt-less claude launch that refreshes the token for free; see Gotchas),
  re-checks, and only falls back to firing blind if the refresh launch fails.
  Only 3 hard-fails.
- **Balance gate** `_caw_plan_exhausted <usage-json> <model>` decides whether
  firing would burn usage **credits** instead of plan allowance. The starter is
  fired only when the 5h window is closed (session cap fresh), so the governing
  plan bucket is the **overall weekly cap** (`weekly_all`) **plus** any
  model-scoped weekly cap whose model matches the **starter's own** `<model>`. A
  scoped cap for a *different* model (e.g. a maxed Fable cap while the starter is
  haiku) is NOT that bucket → does not block. "Exhausted" = percent ≥
  `WEEKLY_MAX_PERCENT` (default 100) OR severity `exceeded`. On a hit the checked
  path logs a WARN and returns **0** (clean no-op, same as the old weekly guard).
  This replaced the too-blunt `_caw_weekly_exhausted` (skipped on *any* weekly cap
  at 100%, wrongly suppressing a cheap haiku starter when only Fable was maxed).

All private helpers are prefixed **`_caw_`** (claude-auto-window). Public
functions are the `claude-auto-window*` names.

## Invariants — do not break these

- **Interactive, not `-p`.** The whole point is a real session. Never switch the
  starter to `claude -p` — it won't open the 5-hour window.
- **Run `claude` directly as the pane process** (`tmux new-session … "$paneline"`
  with `exec`), never typed via `send-keys` into a shell. A shell command-echo
  puts the prompt text (which contains the reply token `OK.`) in the pane and
  causes **false-positive reply detection**. This bug already happened; keep it
  fixed.
- **Reply detection filters the prompt echo, then matches the reply.** See
  `_caw_wait_reply`: it drops lines containing the prompt prefix, then counts the
  expected token in what remains. Do not go back to a raw substring count.
- **`--safe-mode` is load-bearing**, not cosmetic: it's what strips
  CLAUDE.md/skills/hooks/MCP/etc. `--bare` is tempting but **disables OAuth** →
  unusable here (we rely on the subscription login).
- **Default model is the `haiku` alias**, not a pinned id — aliases survive model
  rotation. Keep the fallback-to-account-default retry on no-reply.
- **Profile passthrough:** the `default` spec means `CLAUDE_CONFIG_DIR` is
  **never set** — Claude Code resolves `~/.claude` on its own. Only an absolute-dir
  spec pins it (`_caw_pin_profile`). Do not set `CLAUDE_CONFIG_DIR` for `default`.
- **Single-profile behaves identically to before.** The `_caw_*_one` bodies are
  the byte-for-byte old single-profile logic; a one-profile invocation (and its
  `<hash>.state` file) is unchanged — no state-format migration. `--config-dir`
  and `--profile` now **accumulate** (both repeatable) rather than `--config-dir`
  silently winning; keep the resolution order in `_caw_resolve_profiles` and the
  dedup-by-resolved-dir (first wins).
- **Per-profile isolation.** Iterated modes continue through all profiles on
  failure (return the FIRST non-zero rc); the daemon disables profiles
  individually (`no-window` lifetime / `breaker` until sentinel cleared) and only
  **exits cleanly (0)** once **all** are disabled. A breaker sentinel is re-checked
  each daemon wake, so `--reset` re-enables without a restart.
- **Balance gate never spends credits by default.** `_caw_plan_exhausted` keys on
  the **starter's own model** (changing `--model` changes which weekly bucket
  governs). Don't widen it back to "any weekly cap at 100%" — a maxed Fable cap
  must not suppress a plan-covered haiku starter. The skip is a clean rc 0, not an
  error.
- **Teardown is unconditional.** `kill-session` by unique name + transcript
  cleanup run in the `always {}` block regardless of success/timeout.
- **Isolated tmux socket** (`-L claude-auto-window`) — never touch the user's real
  tmux server.
- **Circuit breaker must not be defeated.** `_caw_breaker_*` count consecutive
  opens that never register a window; after `CLAUDE_AUTO_WINDOW_MAX_FAILURES`
  (default 3) it trips: notify once + persistent trip file + stop (once returns 3,
  cron no-ops, both stay stopped across restarts until `--reset`; the daemon
  **disables that profile** — until its sentinel clears — and exits cleanly only
  once every profile is disabled). The counter **resets on a confirmed-open cycle**
  and increments
  **once per fire attempt** (post-cooldown, post-balance-gate) — keep it that way,
  or normal operation would false-trip or a fault would never trip. Runtime state
  lives in a **durable** dir (`$XDG_STATE_HOME/claude-auto-window/`): a per-profile
  `<hash>.state` key=value file (`_caw_state_get/set/del`) holds `failcount`,
  `last_open` (cooldown), `resets_at`, and `profile`; the disable **sentinel**
  (`<hash>.tripped`) is deliberately kept as its **own** file (touch/rm
  kill-switch). Only the process lock stays transient in `$TMPDIR`.
- **No 5h window ⇒ do nothing.** `_caw_session_active` returns **2** when the
  account has no `session` limit (API/usage-billed seat). `-once` turns that into
  exit **70** (safe no-op, never "closed → open" — that would spend money per
  token), and the **daemon disables that profile** on 70 (lifetime; exits cleanly
  once all profiles are disabled). `--run` keeps exactly **one**
  guard — it refuses (exit 70) only on the no-window case, fails **open** on every
  other state (active/closed/undetermined) so it stays "just do it", and
  `--force` / `CLAUDE_AUTO_WINDOW_FORCE=1` bypasses even that. Do not add the
  "already open → skip" logic to `--run`.

## Exit codes

`0` ok · `1` general error · `2` config/usage-parse error (fatal in daemon) ·
`3` circuit breaker tripped (checked path refuses; **daemon exits cleanly**) ·
`4` starter sent but **no reply** (real failure, from `_caw_send_starter`; the
post-open verify never returns this — a received reply is treated as success) ·
`70` account has no 5-hour window (checked-path no-op; the **daemon exits
cleanly** so systemd leaves it stopped) · `75` another instance holds the
per-profile lock.

**Multi-profile aggregation:** the iterated modes (`--once`/`--run`/`--status`/
`--reset`) run every profile and return the **first** non-zero rc seen. The daemon
maps per-profile rc's to its disable map rather than exiting: **70** ⇒ disable
that profile for the daemon's lifetime; **3** ⇒ disable until the sentinel clears
(re-checked each wake); **2** is still fatal (config/usage-parse); **75** (locked)
and transient errors just skip that profile this wake. The daemon's own process
exit is **0** once all profiles are disabled.

## Testing without spending real tokens

- **Static:** `zsh -n claude-auto-window` (syntax). `--help`, `--version`.
- **Read-only, cheap:** `claude-auto-window --status` (one usage GET; no window
  opened).
- **Pure-logic unit tests:** `source ./claude-auto-window` then call helpers with
  fake inputs — e.g. feed `_caw_wait_reply`-style pane snapshots to the filter, or
  hand `_caw_session_active` a mocked `_caw_usage_json`. The reply-detection and
  transcript-cleanup logic are fully unit-testable this way.
- **Live but free — the expired-token self-heal path:** temporarily set the
  stored credential's `expiresAt` into the past (keep the blob **in shell
  memory only** — never write it to a file — and mutate just the timestamp;
  on macOS via `security add-generic-password -U`), then run `--once` while a
  window is open: expect the self-heal log → "Access token refreshed by the
  launch" → "Window already open", with nothing fired. The bare launch spends
  nothing, and the CLI rewrites a fresh valid blob itself, so no restore is
  needed on success (restore the original only if the test aborts early).
  Clear the stored `resets_at` first or the early-exit gate skips the check.
- **Live (spends a tiny Haiku turn, opens/uses a window):** `--run`. Only do this
  intentionally. `--run` fires even if a window is already open, so it validates
  the mechanism (prompt → reply → teardown) without waiting for a reset.
- **The one path that needs a *closed* window:** `--once` opening a *fresh*
  window — only meaningful after the current 5h window has reset.

## Gotchas

- **Undocumented endpoint.** `_caw_usage_json` calls
  `api.anthropic.com/api/oauth/usage`, reverse-engineered from Claude Code. It
  returns the **raw** response (not the standalone `claude-usage` CLI's normalized
  `--json` shape — note the field is `is_active`, not `active`). If the schema
  changes, the `.limits[] … kind=="session"` parse is what to fix.
- **`is_active` is NOT "is a window open" — and we don't read it.** It tracks
  recent activity, so an open-but-idle window reads `is_active:false`. The only
  signal we use is **`resets_at` in the future**. Keying on `is_active` was a real
  bug (reported a just-opened window as closed); it was removed entirely. Don't
  reintroduce it.
- **The endpoint lags a few minutes** behind reality (and behind claude.ai) after
  a window opens — `resets_at` is briefly `null` before it populates. So: (a) the
  received reply, not the endpoint, is the authoritative success signal (verify is
  informational, never fails on lag); and (b) `_caw_mark_opened` /
  `_caw_recently_opened` implement a post-open **cooldown**
  (`CLAUDE_AUTO_WINDOW_OPEN_COOLDOWN_SECONDS`, default 900) so the daemon doesn't
  fire redundant starter runs during the blind spot (there's only ever one
  window; re-firing just wastes usage). Don't remove either safeguard.
- **OAuth access tokens live ~8h; refresh tokens ~3 days** (both stored in the
  credential blob; only a real `claude` launch performs the refresh — no plumbing
  command does: `auth status`/`doctor`/`agents --json` are all local-only, and
  `auth status` even reports `loggedIn: true` on an expired token; all verified
  empirically 2026-07-20). So after >8h without any Claude activity the state
  check can't authenticate. That is **not** a hard failure: `_caw_resolve_token`
  returns 4 ("expired, refreshable") vs 1 ("no credentials"), and `-once`
  **self-heals** via `_caw_refresh_token` — a **bare, prompt-less** interactive
  launch in the usual throwaway tmux. The CLI refreshes the token on its first
  authenticated backend call at startup (~2s, verified 2026-07-20), and a
  launch with no message **opens no 5h window and spends nothing** — so heal +
  re-check costs zero. Blind starter fire remains only as the fallback when the
  refresh launch fails (its send also refreshes; a dead refresh token → no
  reply → circuit breaker). Don't "fix" any of this by adding an OAuth refresh
  implementation to the script — reusing the CLI's own refresh was a deliberate
  no-new-auth-logic decision. Don't collapse rc 4 back into rc 3 (that
  recreates a cold-start deadlock: check needs a token, token needs a launch,
  launch never happens because the check fails). And never add a prompt
  argument to `_caw_refresh_token`'s launch — prompt-less is what makes the
  self-heal free.
  dialog; `_caw_wait_reply` auto-accepts it (Enter = "Yes, I trust this folder").
  This writes one `~/.claude.json` trust entry per starter dir — which is why the
  default starter dir is a **stable** tmp path, not a fresh one per run.
- **macOS `$TMPDIR` has a trailing slash** — the default starter dir strips it
  (`${${TMPDIR:-/tmp}%/}`), don't reintroduce a `//`.
- **Transcript cleanup uses a recursive glob by session UUID**, so it works
  regardless of how Claude slugifies the cwd into a `projects/<slug>` folder.
- **A profile with no stored credentials is NOT a lifetime-disable.** No creds ⇒
  `_caw_resolve_token` returns 1 → the check is `undetermined` (rc 3), so the
  daemon **retries it each wake** rather than disabling it (a real breaker trip is
  a distinct sentinel). It **self-heals** the moment you `claude`-log-in that
  profile. Only rc 70 (genuinely no 5h window) disables for the daemon's lifetime.
- **The balance gate keys on the starter's OWN model.** `--model` changes which
  model-scoped weekly bucket `_caw_plan_exhausted` consults alongside `weekly_all`
  — a different-model scoped cap (e.g. Fable) does not govern a haiku starter.
- **Don't `sudo`** anything here; it's all user-scoped.
