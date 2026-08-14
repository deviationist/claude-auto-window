# AGENTS.md — orientation for AI agents working in this repo

Read this before changing code. It captures the architecture, the invariants
that are easy to break, and how to test without burning tokens.

## What this is

A single zsh tool that keeps a **Claude Code 5-hour usage window** perpetually
open. When the window has lapsed it opens a fresh one with a single trivial
request, via one of **two opener strategies** (`CLAUDE_AUTO_WINDOW_OPENER` /
`--opener`):

- **`http`** (default) — replicate the request Claude Code sends: one raw
  `POST /v1/messages` with the stored OAuth token, spoofing the Claude Code
  identity so the subscription token is accepted (no tmux, no `claude` binary).
  Falls back to `tmux` when the token needs refreshing.
- **`tmux`** — drive a **real interactive** Claude Code session in a throwaway
  **tmux** session (send a trivial prompt → wait for the reply → quit → tear
  down). Deliberately **not** the headless `claude -p` approach — `-p` does not
  open a 5-hour window.

Both anchor a window identically (a completed request on the OAuth login); they
differ only in transport.

## Files

| File | Role |
|---|---|
| `claude-auto-window` | The whole tool — one self-contained script (OAuth read + usage fetch inlined). Executable **and** source-able. |
| `claude-auto-window.env.example` | Every `CLAUDE_AUTO_WINDOW_*` knob, documented. Doubles as the config-file template: auto-loaded from `$XDG_CONFIG_HOME/claude-auto-window/config` in `_caw_main` (`_caw_load_config`), filling only unset vars (env/flags win). |
| `claude-auto-window@.service` | systemd `--user` template (Linux daemon), keyed on profile via `%i`. |
| `claude-auto-window.plist` | launchd template (macOS daemon), `__HOME__` placeholders. |
| `README.md` | User-facing docs. Keep in sync when flags, defaults or behaviour change. |
| `tools/generate-readme-svg.zsh` | Regenerates `assets/*.svg`. Runs the REAL script in a sandbox (stub `curl`/`security`/`date`/claude-profile) and renders its captured output; the hero animates three captures, the timeline is hand-authored. Re-run after any `--status` format or color change. |

## Architecture (control flow)

- **CLI** `_caw_main` parses flags → sets `CLAUDE_AUTO_WINDOW_*` env → resolves
  the profile list → dispatches to a mode function.
- **Profile resolution** `_caw_resolve_profiles` populates the `_caw_profiles`
  array (order-preserving, deduped by resolved check-dir, first wins + WARN on
  the repeat) from, in precedence order: repeatable CLI `--profile`/`--config-dir`
  > `CLAUDE_AUTO_WINDOW_PROFILES` (comma/space list) > legacy single
  `CLAUDE_AUTO_WINDOW_CONFIG_DIR` > fallback `default`. A **spec** is either the
  literal `default` (unpinned), an absolute dir, or a `cpacct:<account>:<dir>`
  account spec (see claude-profile integration). Helpers: `_caw_profile_spec
  NAME` (name→spec; `default` stays `default`, an absolute path passes through,
  any other name is resolved from **claude-profile's config** — no hardcoded
  `personal`/`work` builtins), `_caw_profile_dir SPEC` (spec→concrete check dir /
  state key; `default`→`~/.claude`, `cpacct:`→account pseudo-key),
  `_caw_pin_profile SPEC` (`default` ⇒ **unset**
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
  - `_caw_check_one` / `claude-auto-window-check` — the **health gate**.
    `--status` describes and exits 0; `--check` judges and exits **1** on any
    FAIL. FAIL = tripped breaker, undeterminable state, missing hard dep, or
    claude-profile active without `oauth.usage_url`/`token_url` (a real,
    observed, silent failure — its stale usage cache hides it, which is why the
    config is asserted directly). WARN (exit 0) = plan exhausted, no 5h window,
    expired-but-self-healing token, HTTP 429. Keep WARN out of the exit code:
    paging on routine states trains the operator to ignore it.
  - `_caw_status_one` — print the current session state **plus the balance-gate
    verdict** (`weekly_all=NN% → would fire / WOULD SKIP`, starter model, credits
    line, stored-vs-live `resets_at`) — the daemon health-check.
- **Both `-run` and `-once` open a window via** `_caw_open_window` → a
  **strategy dispatcher** on `CLAUDE_AUTO_WINDOW_OPENER` (`http` default | `tmux`).
  It calls the matching wrapper, then stamps `_caw_mark_opened` on success (rc 0).
  - **`_caw_open_window_tmux`** — `_caw_send_starter` + the
    **cheapest-model-with-fallback** retry (rc 4 → retry on the account default).
  - **`_caw_open_window_http`** — `_caw_send_starter_http` with a **concrete**
    model id (`CLAUDE_AUTO_WINDOW_HTTP_MODEL`, default `claude-haiku-4-5-20251001`;
    the CLI's `haiku` *alias* is NOT a valid API id). A rejected model (rc 6) is
    mapped to rc 5 = "defer to tmux".
  - **Fallback:** when `_caw_open_window_http` returns **5** (no/expired token, or
    `401/403` auth-reject, or model rejected), the dispatcher runs
    `_caw_open_window_tmux` instead — because only a real `claude` launch can
    refresh the token. So `http` is the light fast-path; `tmux` is the safety net.
- **`_caw_send_starter_http`** is the `http` opener: `_caw_resolve_token` → build a
  minimal `/v1/messages` body (spoofing Claude Code — see Invariants) → one `curl`
  → HTTP 200 with a completion = window anchored. Return codes: `0` anchored,
  `4` sent-but-no-completion / network (breaker-countable, like tmux no-reply),
  `5` defer-to-tmux (token unusable / auth-rejected), `6` model rejected, `2`
  config error (missing `curl`/`jq`). **The access token is resolved into a local
  and NEVER logged.**
- **`_caw_send_starter`** is the `tmux` opener's heavy lifter: build launch argv →
  `tmux new-session` running `claude` directly → `_caw_wait_reply` (also
  auto-accepts the trust dialog) → `_caw_quit_and_kill` → `_caw_cleanup_transcript`,
  the last two in an `always {}` block so teardown is guaranteed.
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

- **claude-profile integration** (`_caw_cp_*`, `_caw_*_account`) — keep serial /
  parked subscriptions' windows open. claude-profile runs several accounts in one
  config dir (one live, rest parked); a parked account's window is anchorable
  ONLY over HTTP (a `claude` launch always uses the live account), so this is
  **http-only by construction** and delegated to `claude-profile anchor-window`
  (token never leaves claude-profile). Shape:
  - **Discovery/expansion** in `_caw_resolve_profiles`: when `_caw_cp_active`
    (config + script found, unless `CLAUDE_AUTO_WINDOW_CLAUDE_PROFILE=off`), each
    claude-profile profile dir is expanded — account-ful → one `cpacct:<acct>:<dir>`
    spec per account; account-less → a plain dir-target. So multi-profile (dirs)
    AND serial (accounts) both work, mixed too. `_caw_profile_spec` also resolves
    names via claude-profile's config (so `--profile personal` matches
    claude-profile's own dir; the old hardcoded `personal`/`work` builtins were
    removed — names are defined per-machine in claude-profile, not here).
  - **Keying:** an account target is keyed by an absolute pseudo-path
    `<dir>/@account/<acct>` (`_caw_account_key`). Because every state/lock/breaker/
    cooldown helper keys off `sha256(${arg:a})`, passing this pseudo-key reuses ALL
    of them unchanged, and `_caw_profile_dir` returns it for `cpacct:` specs so the
    daemon/iterators (which treat that value as an opaque key) need **zero**
    changes.
  - **Dispatch:** `_caw_once_one`/`_caw_run_one`/`_caw_status_one`/`_caw_reset_one`
    each start with a one-line guard → `_caw_*_account` when `CLAUDE_AUTO_WINDOW_CP_ACCOUNT`
    is pinned. The existing bodies are **byte-for-byte** the dir path.
  - **Per-account bodies** mirror the dir path but source the window state from
    `_caw_cp_usage_json` (parses `claude-profile usage-json --account X`) and anchor
    via `_caw_cp_anchor` (`claude-profile anchor-window`). The LIVE account keeps a
    tmux self-heal fallback (`_caw_cp_anchor` rc 5 → `_caw_open_window`); parked
    accounts have none (structural).
  - **Not obsolete:** the v1.1.0 multi-*dir* substrate (`--profile`/`--config-dir`/
    `PROFILES`, spec→pin→env) is the foundation this builds on — untouched, still
    the mechanism for multiple config dirs.

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
- **`--safe-mode` is load-bearing** (tmux opener), not cosmetic: it's what strips
  CLAUDE.md/skills/hooks/MCP/etc. `--bare` is tempting but **disables OAuth** →
  unusable here (we rely on the subscription login).
- **http opener: the Claude Code spoof is mandatory and exact.** The OAuth token
  is only accepted on `/v1/messages` with BOTH (1) header
  `anthropic-beta: oauth-2025-04-20` and (2) a `system` first block that is
  **character-for-character** `You are Claude Code, Anthropic's official CLI for
  Claude.` Change either and the token is rejected (`401/403`). Do **not** add an
  `x-api-key`/`ANTHROPIC_API_KEY` path — that bills separately and does not anchor
  the subscription window (the tmux opener already strips those env vars for the
  same reason).
- **http opener never logs the token.** `_caw_resolve_token`'s output goes into a
  local and only into the `Authorization` header. Keep it that way.
- **http opener falls back to tmux for token refresh.** Only a real `claude`
  launch refreshes an expired access token, so `_caw_send_starter_http` must
  return **5** (not fire blind) on missing/expired token or `401/403`, and the
  dispatcher must route rc 5 to `_caw_open_window_tmux`. Don't implement an OAuth
  refresh in the script (same rationale as `_caw_refresh_token`).
- **Default model is the `haiku` alias** for the tmux opener, not a pinned id —
  aliases survive model rotation. Keep the fallback-to-account-default retry on
  no-reply. **The http opener cannot use an alias** — it needs a concrete API id
  (`CLAUDE_AUTO_WINDOW_HTTP_MODEL`); a rejected id (rc 6) defers to tmux, which
  does understand aliases + the account default.
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
- **Only `--status` is colorized; `_caw_log` never is.** Log output goes to
  journald, cron mail and `--log` files, where escape codes are corruption rather
  than decoration. Color lives in `_caw_status_line` / `_caw_status_account`,
  initialised once by `_caw_color_init` from `_caw_status_one`, and gated on
  `CLAUDE_AUTO_WINDOW_COLOR` (`auto` = stdout is a TTY | `always` | `never`) with
  `NO_COLOR` overriding everything. `always` exists because the README-SVG
  generator captures output through a pipe. **Keep the plain-text line shape
  byte-identical** — only escapes are added, never re-ordered or re-worded
  fields, since `--status` is plausibly grepped in user scripts.
- **Exactly one component maintains any given credential.** claude-profile's
  keep-alive owns **parked** accounts — it alone can touch that store. The
  **live** account it deliberately refuses (`skipped — live in profile "…"`),
  because refresh tokens rotate on use and a second writer racing Claude Code
  means a lost update and a dead credential. So the live account is repaired by
  claude-auto-window causing a **bare, prompt-less `claude` launch**
  (`_caw_refresh_token`) — note the writer is still Claude Code itself; this
  script never writes a credential. The two sets are disjoint by construction:
  `_caw_cp_is_live` gates the repair so it only ever runs for the account
  claude-profile has explicitly declined. This is **not** a second keep-alive —
  it is reactive (only after a check has already failed), unscheduled, and it is
  the same self-heal the dir path has relied on since before claude-profile
  existed, which standalone use still depends on. Don't "unify" it by removing
  it: without claude-profile there would then be no token maintenance at all.
  Guard it on the token actually being unusable (`_caw_resolve_token` non-zero) —
  a fresh token with a failing usage lookup is a claude-profile-side problem no
  launch can fix, and relaunching each wake would be pure waste.
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
- **A 429 is not a closed window.** `_caw_usage_json` returns a distinct rc
  **5** for HTTP 429 so rate-limiting is never conflated with a broken account:
  `-once` holds off until the next wake, `--status` says so, and `--check` calls
  it WARN rather than paging. Don't collapse 5 back into 3 — the old behaviour
  was safe (the error body failed validation) but reported "could not determine
  window state" / "offline, or no stored credentials", which is a misleading
  page.
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
`3` circuit breaker tripped (checked path refuses; the **daemon disables that
profile** until its sentinel clears) ·
`4` starter sent but **no reply / no completion** (real failure, from
`_caw_send_starter` or `_caw_send_starter_http`; the post-open verify never
returns this — a received reply / HTTP 200 is treated as success) ·
`--check` exits `1` if any target FAILs, `0` otherwise (WARN does not count) ·
`70` account has no 5-hour window (checked-path no-op; the **daemon disables that
profile** for its lifetime) · `75` another instance holds the per-profile lock.
The daemon's own process exit is **0** once every profile is disabled, so
systemd/launchd leave it stopped.

**Multi-profile aggregation:** the iterated modes (`--once`/`--run`/`--status`/
`--reset`) run every profile and return the **first** non-zero rc seen. The daemon
maps per-profile rc's to its disable map rather than exiting: **70** ⇒ disable
that profile for the daemon's lifetime; **3** ⇒ disable until the sentinel clears
(re-checked each wake); **2** is still fatal (config/usage-parse); **75** (locked)
and transient errors just skip that profile this wake. The daemon's own process
exit is **0** once all profiles are disabled.

## README images

`assets/*.svg` are generated — never hand-edit them. Two are **captures**: the
generator runs `--status` unmodified against a stub `curl` serving canned usage
JSON, with `CLAUDE_AUTO_WINDOW_COLOR=always` (TTY detection would strip color
through the capture pipe). So the text in those images is the script's own
output, and it drifts the moment the line format or palette changes — re-run the
generator, don't patch the SVG. The only edit made to captured text is rewriting
the mktemp sandbox path to `/home/demo`.

`status`, the hero, is **animated out of three such captures**: the command types
itself in (one frame per keystroke), then the window is shown open, lapsed, and
freshly re-anchored. All three runs happen within the same second of wall clock,
so a stub **`date`** stages a shared story clock for them — it intercepts *only*
`date -u +%Y-%m-%dT%H:%M:%S`, the exact invocation the open/closed compare uses,
and passes everything else through to the real binary. Without it the lapsed
frame could only be built by back-dating its `resets_at`, which would then
contradict the frame before it. A guard in the generator asserts the lapsed frame
really does read `five_hour_open=no`, so a refactor of how "now" is fetched fails
the generator instead of silently shipping three identical open windows.

`timeline` is a **schematic** of the daemon's sleep/fire cycle, drawn by hand
because there is no output to photograph.

Both animate via CSS keyframes, never SMIL or script — an SVG in an `<img>` has
scripting disabled but declarative animation live. `status` stacks one `<g>` per
frame and steps opacity with `step-end` (a hard cut; two stops at the same
percentage would collapse and cross-fade instead), and carries `opacity="0"` as a
presentation attribute on every frame but the last, so a renderer ignoring
`<style>` shows the final state rather than all frames at once. In `timeline`
every animated element's BASE state is the fire-moment frame. Either way
`prefers-reduced-motion` freezes on something legible rather than blank.

Filenames carry a random hash purely to bust GitHub's camo cache; the generator
rewrites the README refs and deletes superseded files.

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
  Add `--opener http` to validate the raw `POST /v1/messages` path (expect
  `HTTP opener: request completed (stop_reason='end_turn') → window anchored`),
  and force the http→tmux fallback with a bogus `--http-model` (expect the model
  `404` → `deferring to tmux opener` → the tmux starter replies). Both were
  validated live 2026-07-27.
- **The one path that needs a *closed* window:** `--once` opening a *fresh*
  window — only meaningful after the current 5h window has reset.

## Gotchas

- **Undocumented endpoint.** `_caw_usage_json` calls
  `api.anthropic.com/api/oauth/usage`, reverse-engineered from Claude Code. It
  returns the **raw** response (not the standalone `claude-usage` CLI's normalized
  `--json` shape — note the field is `is_active`, not `active`). If the schema
  changes, the `.limits[] … kind=="session"` parse is what to fix.
- **http opener is an unofficial spoof.** Getting a *subscription* OAuth token
  accepted on `/v1/messages` by presenting as Claude Code (beta header + identity
  system prompt) is reverse-engineered, not a supported API. Anthropic could
  change the acceptance rule at any time; if the http opener starts returning
  `401/403`, that's the likely cause — the rc-5 fall-back to the tmux opener keeps
  the tool working in the meantime, and `--opener tmux` is the escape hatch. Don't
  treat the spoof as a stable contract.
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
- **A first run in a new starter dir shows the workspace-trust**
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
- **Serial account swappers — SOLVED (was: one profile == one config dir == one
  account).** Tools that multiplex N accounts through a *single* dir (parking the
  inactive credentials) used to be invisible to profile resolution — only the live
  account was checked, parked 5h windows lapsed. Now the **claude-profile
  integration** (see that bullet above) enumerates accounts and anchors each. The
  enduring invariant that shaped the fix, and must not be regressed: **refresh
  tokens rotate on use**, so exactly ONE component may own the credential
  write-back. Therefore the script must NOT park/unpark credentials or launch
  against a shadow dir built from a parked credential (that makes it a second
  writer and stales the swapper's copy). It delegates the anchor to claude-profile's
  `anchor-window` (HTTP — no session, no swap, no refresh-token rotation for the
  common case), which remains the sole writer of the parked store.
- **The balance gate keys on the starter's OWN model.** `--model` changes which
  model-scoped weekly bucket `_caw_plan_exhausted` consults alongside `weekly_all`
  — a different-model scoped cap (e.g. Fable) does not govern a haiku starter.
- **Don't `sudo`** anything here; it's all user-scoped.
