# claude-auto-window

Keep a **Claude Code 5-hour usage window** perpetually open — back to back — so
there's no cold-start wait the moment you actually want to use Claude. When the
current window has lapsed, it opens a fresh one by driving a *real interactive*
Claude Code session inside a throwaway **tmux** session: send one trivial prompt,
wait for the reply, quit, and tear the session down. That single request anchors
a new 5-hour window at minimal token cost.

Useful if you're on a **Claude Pro/Max** plan and want your 5-hour windows to
roll continuously (e.g. overnight, or on a always-on box) so you never lose time
waiting for a new window to start after you hit a limit.

> **Works on plans that have a 5-hour session window — i.e. Claude Pro/Max**
> (and any seat on the same rolling-window rate-limit model). **API/usage-billed
> seats** (many Team/Enterprise/console setups) have no such window, so there's
> nothing to keep open. Every mode **detects this and refuses to fire** by
> default (`--once` no-ops, `--daemon` exits cleanly, `--run` refuses unless you
> pass `--force`) — because on a per-token-billed seat, firing would just cost
> money for no benefit.

## How it works

1. **Check** — read Claude Code's OAuth usage endpoint directly for the `session`
   (5h) limit's `resets_at`. No API key needed — Claude Code's existing login is
   used (token resolution + fetch are built in; no external dependency).
2. **Stop if open** — a window is already running → do nothing.
3. **Jitter** — window closed → wait `0..jitter-max` seconds (default 180), then
   re-check (normal activity during the jitter may have already opened one).
4. **Open a tmux session** — unique name on an isolated socket
   (`-L claude-auto-window`), never touching your real tmux server.
5. **Run** `claude "Reply with exactly: OK."` **directly** as the pane's process
   (not typed into a shell, so there's no command-echo noise), as light as
   possible (see *Minimal footprint*).
6. **Wait for the reply** — poll `capture-pane`, filter out the prompt-echo
   lines, and match Claude's own reply (`OK.`). If the first-run
   **workspace-trust dialog** appears, it's accepted automatically (Enter → the
   default "Yes, I trust this folder") — safe because the starter dir is a
   dedicated dir you own.
7. **Quit** — send `/exit`; if still running, `Ctrl-C Ctrl-C`; then
   `kill-session` by name unconditionally (in an `always` block).
8. **Clean up** — delete the starter's own transcript, verify the window flipped
   active.

A per-profile lock prevents two starters racing for the same account, and a
weekly-allowance guard skips the starter if you're already weekly-capped.

## Requirements

- **zsh**, **tmux**, **jq**, **curl**
- **Claude Code** (`claude`) logged in for the profile you want kept open.
- A **Claude Pro/Max** account (see note above).

### Authentication

There's no separate login. The tool reuses the **OAuth token Claude Code already
stored** when you ran `claude` and logged in through the browser — the same token
Claude Code uses itself. It's read per config-dir:

- **Linux / headless:** `<config-dir>/.credentials.json` (e.g.
  `~/.claude/.credentials.json`) → `.claudeAiOauth.accessToken`.
- **macOS:** the login **Keychain**, service `Claude Code-credentials-<hash>`
  where `<hash>` = first 8 hex of `sha256(absolute config-dir path)` — this is how
  Claude Code namespaces multiple accounts. The first read may prompt for Keychain
  access; click **Always Allow** once.

The freshest non-expired token is used. Claude Code refreshes tokens itself; if
all stored tokens are expired, run a Claude Code session for that account to
refresh, then retry. No `ANTHROPIC_API_KEY` is involved (the starter explicitly
strips it so the subscription login is used).

## Install

Clone the repo, then symlink the script onto your `PATH`:

```sh
git clone https://github.com/deviationist/claude-auto-window.git
cd claude-auto-window
mkdir -p ~/.local/bin ~/.local/state/claude-auto-window
ln -sf "$PWD/claude-auto-window" ~/.local/bin/claude-auto-window
claude-auto-window --status      # smoke test: prints your current 5h state
```

It's a **single self-contained script** — the OAuth token read + usage fetch are
built in, no other files to install.

## Modes

```sh
claude-auto-window              # --once: check; if closed, jitter + open (default)
claude-auto-window --run        # open one now — no window-state checks, no jitter
claude-auto-window --run --force  # ...and skip even the "no 5h window" safety check
claude-auto-window --daemon     # loop --once on a fixed interval
claude-auto-window --status     # print current 5h session state
claude-auto-window --reset      # clear a tripped circuit breaker (see below)
```

## Profiles (multi-account)

Default is a transparent passthrough: `CLAUDE_CONFIG_DIR` is never set, so Claude
Code resolves `~/.claude` exactly as a bare `claude` call would. Each profile is
checked and opened independently against its **own** stored login.

```sh
claude-auto-window --profile personal          # ~/.claude-personal
claude-auto-window --profile work              # ~/.claude
claude-auto-window --config-dir /path/to/prof  # any explicit profile dir
```

## Where it runs

The starter never runs in your current/work directory. It `cd`s into a dedicated
**starter dir** — default `$TMPDIR/claude-auto-window-<uid>`, a stable per-user
tmp dir that's isolated, always empty (transcripts are cleaned), and **trusted
exactly once** (so it adds a single `~/.claude.json` trust entry, not one per
run; re-trusted automatically if a reboot clears tmp). Pin a different location
with `--starter-dir`.

## Minimal footprint

The point is to spend as few tokens as possible, and leave no trace:

- **`--safe-mode`** launches with no CLAUDE.md/memory, skills, hooks, MCP
  servers, plugins, custom agents, output styles, themes or keybindings — OAuth
  auth and the model still work. (`--bare` would be lighter but disables OAuth,
  so it's unusable here.) Plus **`--tools ""`** and
  **`--exclude-dynamic-system-prompt-sections`**. Opt out with
  `CLAUDE_AUTO_WINDOW_LIGHT=0`.
- **Cheapest model, rotation-proof.** Defaults to the **`haiku` alias** — the
  cheapest tier, and an alias always resolves to the *latest* model of that tier,
  so it keeps working when a specific version is retired (pinning a full model id
  is what would break). Override with `--model` (`""` = account default). If the
  chosen model is ever retired outright, the starter **auto-retries once on the
  account default**.
- **No leftover conversation.** `--no-session-persistence` only works with `-p`
  (which doesn't open a window). In practice a short `--safe-mode` session writes
  no transcript at all; as a safety net (and for the `LIGHT=0` path) the starter
  pins a known `--session-id` and **deletes that exact `<uuid>.jsonl`** on
  teardown. Keep it with `CLAUDE_AUTO_WINDOW_KEEP_TRANSCRIPT=1`.

## Loop protection (circuit breaker)

A window opens the instant the starter's request completes — but the usage
endpoint can lag a few minutes before it *reports* the window open. Normally the
post-open cooldown covers that. But if opens keep "succeeding" while the endpoint
**never** shows a window (a real fault, or pathological lag), the daemon would
otherwise re-fire a pointless starter forever. To prevent that:

- The tool counts **consecutive opens that never register a window**. The counter
  resets the moment a window is confirmed open.
- After `CLAUDE_AUTO_WINDOW_MAX_FAILURES` (default **3**) it **trips**: fires a
  one-time notification, writes a **persistent** trip file, and stops. The
  **daemon exits cleanly** (systemd leaves it stopped); a **cron** `--once` run
  becomes a no-op — both stay stopped across restarts until you reset.
- **Notify hook:** set `--notify-cmd` / `CLAUDE_AUTO_WINDOW_NOTIFY_CMD` to any
  shell command; it gets the message on stdin and in `$CLAUDE_AUTO_WINDOW_MESSAGE`
  (wire it to `notify-send`, `mail`, `ntfy`, `osascript`, etc.). Without it, the
  trip is still logged.
- **The trip file is a plain sentinel.** When present the tool is disabled;
  every run **fails early** with the sentinel path and a reset command. It
  doubles as a **manual kill-switch** — `touch` it yourself to pause the tool.
- **Resume:** `claude-auto-window --reset` removes the sentinel (or just `rm` it).
  `--status` shows a `⚠ DISABLED (sentinel present): <path>` block while tripped.

State lives in `$CLAUDE_AUTO_WINDOW_STATE_DIR` (default
`~/.local/state/claude-auto-window`), so it survives reboots.

## The daemon doesn't poll continuously

When a window is open, the daemon knows exactly when it ends (`resets_at`), so it
**sleeps until just after it expires** (`resets_at + --post-expiry`, default 5 s),
wakes, sees it closed, and fires the next starter — no polling in between. It only
does repeated fetches to **confirm** a just-opened window (the endpoint lags a few
minutes, re-checked every `--interval`). So an idle-open window is ~2 requests per
5-hour window, not ~60. A safety cap (`--max-sleep`, default 6h) bounds any single
sleep. The total gap after expiry is `post-expiry + jitter`, so keep `--jitter-max`
small on a single daemon for tight back-to-back windows.

(Cron can't do this — it's stateless external scheduling, so each `--once` fetches
on the crontab's cadence.)

## Config file

For cron/manual runs, the script auto-loads
`$XDG_CONFIG_HOME/claude-auto-window/config` (usually
`~/.config/claude-auto-window/config`) — `KEY=value` lines, same keys as
`claude-auto-window.env.example`. Env vars and CLI flags override it. (systemd
users can keep using `EnvironmentFile` instead.)

Runtime state lives per-profile in `~/.local/state/claude-auto-window/`: a
`<hash>.state` file (records the `profile` path, last `resets_at`, failure count,
last-open time — self-documenting for multi-profile setups) plus the standalone
`<hash>.tripped` disable sentinel.

## Tuning

Every flag has a `CLAUDE_AUTO_WINDOW_*` env equivalent (see
`claude-auto-window.env.example`). Most-used:

| Flag | Env | Default | Meaning |
|---|---|---|---|
| `--interval` | `…_INTERVAL_SECONDS` | 60 | Daemon **confirm-poll** interval (post-open) |
| `--post-expiry` | `…_POST_EXPIRY_SECONDS` | 5 | Wake this long after expiry to fire |
| `--max-sleep` | `…_MAX_SLEEP_SECONDS` | 21600 | Cap on one sleep (safety) |
| `--jitter-max` | `…_JITTER_MAX_SECONDS` | 180 | Extra 0..N wait before firing (small on a daemon) |
| `--model` | `…_MODEL` | `haiku` | Model alias/id, `""` = account default |
| `--max-failures` | `…_MAX_FAILURES` | 3 | Failed opens before the breaker trips |
| `--log` | `…_LOG` | — | Opt-in log file |

## Running it continuously

Pick your platform × style. In all cases, symlink the script to
`~/.local/bin/claude-auto-window` first (see *Install*). The daemon sleeps until
window expiry (above); a cron entry runs `--once` on a schedule instead.

### Linux — systemd `--user` (daemon)

`claude-auto-window@.service` is a template keyed on the profile, so one instance
per account runs side by side:

```sh
mkdir -p ~/.config/systemd/user ~/.config/claude-auto-window ~/.local/state/claude-auto-window
cp claude-auto-window@.service ~/.config/systemd/user/
cp claude-auto-window.env.example ~/.config/claude-auto-window/default.env   # optional, then edit
systemctl --user daemon-reload
systemctl --user enable --now claude-auto-window@default.service
# a second account: systemctl --user enable --now claude-auto-window@personal.service

# Headless box with no persistent login? Let the user manager run at boot:
sudo loginctl enable-linger "$USER"

journalctl --user -u claude-auto-window@default -f    # logs
```

### Linux — cron

```sh
crontab -e
```
```cron
# run every minute — each run exits early (no fetch) while the stored resets_at is
# still in the future, so it only hits the endpoint near expiry. Running every
# minute keeps reopening tight (fires within ~1 min of the window lapsing).
# --quiet so cron doesn't email on every run; --notify-cmd is the alert.
* * * * * $HOME/.local/bin/claude-auto-window --once --quiet \
  --log $HOME/.local/state/claude-auto-window/default.log \
  --notify-cmd 'mail -s "claude-auto-window tripped" you@example.com'
```
Notes:
- **Cheap even every minute.** Cron can't sleep, so it fires on schedule — but each
  run first reads the stored `resets_at` and **exits without fetching** while the
  window is still open. It only actually checks near expiry (and briefly after
  opening, to confirm). So a per-minute crontab still costs ~2 requests per 5-hour
  window, not one per tick. (`--status` always does a live check if you want one.)
- **`--quiet` matters for cron.** Without it the script prints on every run and
  cron emails you every 5 minutes. `--quiet` keeps output in the `--log` file;
  the **`--notify-cmd` mailer** is then your single alert (fires once, on a trip).
- **cron can't be "stopped" from inside** — if the circuit breaker trips, the
  script doesn't remove your crontab entry; instead every subsequent run **no-ops**
  (reads the trip file, exits) until `--reset`. To stop it invoking entirely,
  comment out the crontab line.
- cron has a minimal PATH — if `claude`/`tmux` aren't found, use full paths or set
  `CLAUDE_AUTO_WINDOW_CLAUDE_BIN` and prepend `PATH=...` in the crontab.

### macOS — launchd (daemon)

`claude-auto-window.plist` is a template with `__HOME__` placeholders (launchd
doesn't expand `~`):

```sh
mkdir -p ~/.local/state/claude-auto-window
sed "s|__HOME__|$HOME|g" claude-auto-window.plist > ~/Library/LaunchAgents/claude-auto-window.plist
launchctl load ~/Library/LaunchAgents/claude-auto-window.plist
# stop:  launchctl unload ~/Library/LaunchAgents/claude-auto-window.plist
# logs:  ~/.local/state/claude-auto-window/launchd.log
```

### macOS — cron

macOS ships cron (though launchd is preferred). Same as the Linux cron entry —
`--quiet` + `--notify-cmd`:

```cron
* * * * * $HOME/.local/bin/claude-auto-window --once --quiet \
  --log $HOME/.local/state/claude-auto-window/default.log \
  --notify-cmd 'osascript -e "display notification \"$CLAUDE_AUTO_WINDOW_MESSAGE\" with title \"claude-auto-window\""'
```
(Recent macOS requires granting `cron` **Full Disk Access** in System Settings →
Privacy for it to read the Keychain/config — the launchd agent avoids that.)

### As a shell function

```sh
source /path/to/claude-auto-window/claude-auto-window
claude-auto-window-once
```

## Caveats

- **Undocumented endpoint.** The usage check uses
  `api.anthropic.com/api/oauth/usage`, reverse-engineered from Claude Code; it
  may change without notice.
- **The endpoint lags a few minutes.** After a window opens, the endpoint takes a
  little while to reflect it (and its `active` flag tracks recent activity, not
  whether a window is open — so "open" is detected via `resets_at`). Because of
  this, the received `OK.` reply — not the endpoint — is the success signal, and a
  post-open **cooldown** (`CLAUDE_AUTO_WINDOW_OPEN_COOLDOWN_SECONDS`, default 900 s)
  stops the daemon firing redundant starter runs while the endpoint catches up
  (there's only ever one window; re-firing would just waste a little usage).
- **Auto-accepts workspace trust** for the starter dir. That's intentional and
  safe because the dir is a dedicated, empty directory the tool owns — but if you
  point `--starter-dir` at something shared, know that it will be trusted.
- This tool spends a (tiny) amount of usage on every window it opens. It's built
  to minimise that, not eliminate it.

## Files

| File | Purpose |
|---|---|
| `claude-auto-window` | The whole tool — one self-contained script. |
| `claude-auto-window@.service` | systemd `--user` template (per-profile). |
| `claude-auto-window.plist` | macOS launchd template. |
| `claude-auto-window.env.example` | All env overrides, documented. |
| `AGENTS.md` | Orientation for AI agents working in this repo. |

## License

MIT — see `LICENSE`.
