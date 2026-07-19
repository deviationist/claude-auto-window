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
| `claude-auto-window@.service` | systemd `--user` template (Linux daemon), keyed on profile via `%i`. |
| `claude-auto-window.plist` | launchd template (macOS daemon), `__HOME__` placeholders. |
| `claude-auto-window.env.example` | Every `CLAUDE_AUTO_WINDOW_*` knob. |

## Architecture (control flow)

- **CLI** `_caw_main` parses flags → sets `CLAUDE_AUTO_WINDOW_*` env → dispatches
  to a mode function.
- **Modes:**
  - `claude-auto-window-run` — fire immediately, **no checks, no jitter**.
  - `claude-auto-window-once` *(default)* — check window; if closed, **jitter**
    then open. Guards: already-open, weekly-exhausted, no-5h-window.
  - `claude-auto-window-daemon` — loop `-once` on a fixed interval (aligned ticks).
  - `claude-auto-window-status` — print the current session state.
- **Both `-run` and `-once` open a window via** `_caw_open_window` → which calls
  `_caw_send_starter` and adds the **cheapest-model-with-fallback** retry.
- **`_caw_send_starter`** is the heavy lifter: build launch argv → `tmux
  new-session` running `claude` directly → `_caw_wait_reply` (also auto-accepts
  the trust dialog) → `_caw_quit_and_kill` → `_caw_cleanup_transcript`, the last
  two in an `always {}` block so teardown is guaranteed.
- **Window check** is `_caw_session_active` → `_caw_usage_json` (inlined:
  `_caw_resolve_token` + a `curl` to the OAuth usage endpoint → raw JSON) →
  `.limits[] | select(.kind=="session")`. "Open" = **`resets_at` in the future**;
  `is_active` is deliberately NOT consulted (see Gotchas).

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
- **Profile passthrough:** when no profile is selected, `CLAUDE_CONFIG_DIR` is
  **never set** — Claude Code resolves `~/.claude` on its own. Only pin it when
  `--profile`/`--config-dir` is given.
- **Teardown is unconditional.** `kill-session` by unique name + transcript
  cleanup run in the `always {}` block regardless of success/timeout.
- **Isolated tmux socket** (`-L claude-auto-window`) — never touch the user's real
  tmux server.
- **Circuit breaker must not be defeated.** `_caw_breaker_*` count consecutive
  opens that never register a window; after `CLAUDE_AUTO_WINDOW_MAX_FAILURES`
  (default 3) it trips: notify once + persistent trip file + stop (once returns 3,
  daemon exits cleanly, cron no-ops, both stay stopped across restarts until
  `--reset`). The counter **resets on a confirmed-open cycle** and increments
  **once per fire attempt** (post-cooldown, post-weekly-guard) — keep it that way,
  or normal operation would false-trip or a fault would never trip. State is in a
  **durable** dir (`CLAUDE_AUTO_WINDOW_STATE_DIR`), separate from the transient
  tmp lock/cooldown markers, so a persistent fault survives reboots.
- **No 5h window ⇒ do nothing.** `_caw_session_active` returns **2** when the
  account has no `session` limit (API/usage-billed seat). `-once` turns that into
  exit **70** (safe no-op, never "closed → open" — that would spend money per
  token), and the **daemon exits cleanly** on 70. `--run` keeps exactly **one**
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

## Testing without spending real tokens

- **Static:** `zsh -n claude-auto-window` (syntax). `--help`, `--version`.
- **Read-only, cheap:** `claude-auto-window --status` (one usage GET; no window
  opened).
- **Pure-logic unit tests:** `source ./claude-auto-window` then call helpers with
  fake inputs — e.g. feed `_caw_wait_reply`-style pane snapshots to the filter, or
  hand `_caw_session_active` a mocked `_caw_usage_json`. The reply-detection and
  transcript-cleanup logic are fully unit-testable this way.
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
- **Trust dialog.** First run in a new starter dir shows the workspace-trust
  dialog; `_caw_wait_reply` auto-accepts it (Enter = "Yes, I trust this folder").
  This writes one `~/.claude.json` trust entry per starter dir — which is why the
  default starter dir is a **stable** tmp path, not a fresh one per run.
- **macOS `$TMPDIR` has a trailing slash** — the default starter dir strips it
  (`${${TMPDIR:-/tmp}%/}`), don't reintroduce a `//`.
- **Transcript cleanup uses a recursive glob by session UUID**, so it works
  regardless of how Claude slugifies the cwd into a `projects/<slug>` folder.
- **Don't `sudo`** anything here; it's all user-scoped.
