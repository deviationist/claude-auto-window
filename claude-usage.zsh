# ============================================================================
# claude-usage — Claude seat spend/limits, from Anthropic's own counter
# ============================================================================
# Reads the same server-side numbers that claude.ai → Settings → Usage shows
# ("$300.04 of $300.00 spent"), via the OAuth usage endpoint that Claude Code's
# own token can query. Covers ALL usage billed to the account (Claude Code on
# any machine + claude.ai), unlike local transcript-based tools like ccusage.
#
# Install:  source this file from ~/.zshrc
#
# Usage:    claude-usage                      # work seat (~/.claude), pretty
#           claude-usage --dir ~/.claude-personal   # another account (Max etc.)
#           claude-usage --json               # machine-readable summary
#           claude-usage --raw                # full untouched endpoint response
#           claude-usage --fresh              # blocking refresh, guaranteed current
#           claude-usage --no-block           # statusline mode: never blocks,
#                                             # prints nothing on cold/broken state
#
# Env:      CLAUDE_USAGE_DIR      default config dir (default: ~/.claude)
#           CLAUDE_USAGE_DIVISOR  credits→dollars divisor (default: 100 = cents)
#
# Output:   Seats with a USD cap:  "$300.04 / $300 (100%)"
#           Max/Pro (no cap):      "5h 12% | 7d 40% | opus 63%"
#
# Caching:  stale-while-revalidate, PER ACCOUNT (cache file is derived from the
#           config dir, so work and personal never clobber each other). Bare
#           invocations always return immediately from cache; if older than
#           $ttl (300s), a detached background refresh runs and the NEXT call
#           sees the new value. Failed refreshes never destroy the last known
#           value, and back off for 60s so a broken state doesn't hammer
#           the endpoint from a constantly-repainting statusline.
#
# Caveats:  - Endpoint (api.anthropic.com/api/oauth/usage) is undocumented and
#             reverse-engineered from Claude Code; it may change without notice.
#           - Token lookup per account: $dir/.credentials.json first, then the
#             macOS Keychain entry "Claude Code-credentials-<hash>", where
#             <hash> = first 8 hex chars of sha256 of the absolute config dir
#             path (this is how Claude Code namespaces multi-account creds).
#             The legacy un-suffixed entry is only used for ~/.claude.
#           - Keep the TTL sane; hammering the endpoint gets rate-limited.
# ============================================================================

# The API reports credits worth $0.01 — divide by 100 for dollars.
export CLAUDE_USAGE_DIVISOR="${CLAUDE_USAGE_DIVISOR:-100}"

# Builtin zstat for portable mtime (GNU and BSD stat disagree on flags).
# -F loads only the zstat builtin, without shadowing the system `stat`.
zmodload -F zsh/stat b:zstat 2>/dev/null

# ----------------------------------------------------------------------------
# Internal: cache path for a given config dir.
# ~/.claude → claude-oauth-usage..claude.json  (basename keeps it readable)
# ----------------------------------------------------------------------------
_claude_usage_cache_path() {
  local dir="${1%/}"
  print -r -- "${TMPDIR:-/tmp}/claude-oauth-usage.${dir:t}.json"
}

# ----------------------------------------------------------------------------
# Internal: fetch the endpoint and atomically replace the cache on success.
#   $1 = 1 → if another refresh holds the lock, wait for it (up to ~10s);
#            also bypasses failure backoff. 0 = background semantics.
#   $2 = config dir
# Return codes: 0 ok, 2 no token, 3 network/timeout, 4 API rejected
# ----------------------------------------------------------------------------
_claude_usage_refresh() {
  local wait="${1:-0}"
  local dir="${2:-${CLAUDE_USAGE_DIR:-$HOME/.claude}}"
  local cache; cache=$(_claude_usage_cache_path "$dir")
  local lock="$cache.lock"
  local failmark="$cache.fail"
  local backoff=60

  # Failure backoff: if the last attempt failed <$backoff seconds ago, don't
  # keep hammering (a cold-cache statusline repaints constantly and would
  # otherwise spawn a doomed refresh on every tick). --fresh (wait=1) bypasses.
  if (( ! wait )) && [[ -f $failmark ]]; then
    local fmtime
    fmtime=$(zstat +mtime "$failmark" 2>/dev/null) || fmtime=0
    (( $(date +%s) - fmtime < backoff )) && return 0
  fi

  # mkdir is atomic → cheap cross-process lock, no stampedes
  if ! mkdir "$lock" 2>/dev/null; then
    (( wait )) || return 0
    local i
    for i in {1..100}; do          # wait ≤10s for the in-flight refresh
      [[ -d $lock ]] || return 0   # it finished; its result is our result
      sleep 0.1
    done
    return 0                       # stuck lock: give up, serve cache
  fi

  {
    # Collect candidate credential blobs from all sources for this dir, then
    # pick the freshest NON-EXPIRED token. Multiple sources can exist for one
    # account (file + suffixed Keychain + plain Keychain), and a stale entry
    # must not shadow a fresh one.
    local -a blobs
    blobs=( "$(cat "$dir/.credentials.json" 2>/dev/null)" )
    if command -v security >/dev/null 2>&1; then
      # macOS Keychain, namespaced per config dir: the service name is
      # "Claude Code-credentials-<first 8 hex of sha256(absolute dir path)>"
      local suffix
      suffix=$(printf '%s' "${dir:a}" \
                 | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null } \
                 | cut -c1-8)
      [[ -n $suffix ]] && blobs+=( "$(security find-generic-password \
          -s "Claude Code-credentials-$suffix" -a "$USER" -w 2>/dev/null)" )
      # Legacy un-suffixed entry, only for the default dir (created by
      # runs without CLAUDE_CONFIG_DIR; not disambiguated per account)
      [[ "${dir%/}" == "${HOME}/.claude" ]] && blobs+=( "$(security find-generic-password \
          -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null)" )
    fi

    local token="" best_exp=-1 found_expired=0
    local now_ms=$(( $(date +%s) * 1000 ))
    local blob cand cand_exp
    for blob in "${blobs[@]}"; do
      [[ -z $blob ]] && continue
      cand=$(jq -r '.claudeAiOauth.accessToken // empty' <<< "$blob" 2>/dev/null)
      [[ -z $cand ]] && continue
      cand_exp=$(jq -r '.claudeAiOauth.expiresAt // empty' <<< "$blob" 2>/dev/null)
      if [[ -n $cand_exp ]] && (( cand_exp <= now_ms )); then
        found_expired=1
        continue
      fi
      [[ -z $cand_exp ]] && cand_exp=$now_ms   # unknown expiry: usable, lowest priority
      if (( cand_exp > best_exp )); then
        best_exp=$cand_exp
        token=$cand
      fi
    done
    if [[ -z $token ]]; then
      touch "$failmark"
      (( found_expired )) && return 5          # 5 = tokens found, all expired
      return 2                                 # 2 = no token at all
    fi

    # Write to tmp, validate, then mv — a failed fetch never clobbers the cache.
    # --connect-timeout fails fast when offline; --max-time bounds the whole call.
    if ! curl -s --connect-timeout 3 --max-time 6 \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" > "$cache.tmp" 2>/dev/null; then
      rm -f "$cache.tmp"
      touch "$failmark"
      return 3                    # 3 = network failure / timeout
    fi
    if ! jq -e '.error == null' "$cache.tmp" >/dev/null 2>&1; then
      rm -f "$cache.tmp"
      touch "$failmark"
      return 4                    # 4 = API rejected it (expired token, rate limit)
    fi
    mv "$cache.tmp" "$cache"
    rm -f "$failmark"
  } always {
    rmdir "$lock" 2>/dev/null
  }
}

# ----------------------------------------------------------------------------
# claude-usage [--dir PATH] [--json|--raw] [--fresh|--no-block]
# ----------------------------------------------------------------------------
claude-usage() {
  emulate -L zsh
  local ttl=300 mode=pretty force=0 noblock=0
  local divisor="${CLAUDE_USAGE_DIVISOR:-1}"

  # Account resolution mirrors the claude() wrapper:
  #   --dir > CLAUDE_USAGE_DIR > CLAUDE_CONFIG_DIR > cwd override > ~/.claude
  # The cwd override defers to _claude_pick_override when defined; otherwise
  # it natively replicates the same contract: if $PWD is at or under any of
  # $CLAUDE_OVERRIDE_PATHS, use $CLAUDE_OVERRIDE_PROFILE.
  local dir="${CLAUDE_USAGE_DIR:-${CLAUDE_CONFIG_DIR:-}}"
  if [[ -z $dir ]]; then
    if typeset -f _claude_pick_override >/dev/null 2>&1; then
      dir="$(_claude_pick_override)"
    elif (( ${#CLAUDE_OVERRIDE_PATHS[@]} )); then
      local _p
      for _p in "${CLAUDE_OVERRIDE_PATHS[@]}"; do
        _p="${_p%/}"
        if [[ "$PWD" == "$_p" || "$PWD" == "$_p"/* ]]; then
          dir="${CLAUDE_OVERRIDE_PROFILE:-$HOME/.claude-personal}"
          break
        fi
      done
    fi
  fi
  [[ -z $dir ]] && dir="$HOME/.claude"

  while (( $# )); do
    case "$1" in
      --json)     mode=json ;;
      --raw)      mode=raw ;;
      --fresh)    force=1 ;;
      --no-block) noblock=1 ;;
      --dir)
        [[ -n "$2" ]] || { print -u2 "claude-usage: --dir requires a path"; return 1 }
        dir="$2"; shift ;;
      --dir=*)    dir="${1#--dir=}" ;;
      -h|--help)
        print "usage: claude-usage [--dir PATH] [--json|--raw] [--fresh|--no-block]"
        return 0 ;;
      *)
        print -u2 "usage: claude-usage [--dir PATH] [--json|--raw] [--fresh|--no-block]"
        return 1 ;;
    esac
    shift
  done
  dir="${dir%/}"

  local cache; cache=$(_claude_usage_cache_path "$dir")

  if (( force )) || [[ ! -f $cache ]]; then
    if (( noblock )); then
      # Statusline mode: NEVER block. No cache yet → kick off a background
      # refresh, print nothing, exit clean; the next repaint picks it up.
      [[ -f $cache ]] || { ( _claude_usage_refresh 0 "$dir" & ) >/dev/null 2>&1; return 0 }
    else
      # Forced refresh or cold start: block on the network.
      # (wait=1 so --fresh also waits out any in-flight background refresh)
      _claude_usage_refresh 1 "$dir"
      local rc=$?
      if [[ ! -f $cache ]]; then
        case $rc in
          2) print -u2 "claude-usage: no OAuth token in $dir — is Claude Code logged in for this account?" ;;
          3) print -u2 "claude-usage: network failure or timeout reaching api.anthropic.com" ;;
          4) print -u2 "claude-usage: API rejected the request (expired token or rate-limited) — run a Claude Code session and retry" ;;
          5) print -u2 "claude-usage: all stored tokens for $dir are expired — start a Claude Code session for this account to refresh them" ;;
          *) print -u2 "claude-usage: refresh failed" ;;
        esac
        return 1
      fi
      # Cache exists but forced refresh failed → warn, then serve stale below
      if (( force && rc != 0 )); then
        print -u2 "claude-usage: refresh failed (code $rc), showing cached value"
      fi
    fi
  else
    # Warm path: serve cache instantly; revalidate behind the scenes if stale.
    # The ( ... & ) subshell detaches from job control: no [1] 12345 noise.
    local mtime
    mtime=$(zstat +mtime "$cache" 2>/dev/null) || mtime=0
    if (( $(date +%s) - mtime > ttl )); then
      ( _claude_usage_refresh 0 "$dir" & ) >/dev/null 2>&1
    fi
  fi

  case $mode in
    raw)
      jq . "$cache"
      ;;
    json)
      jq --argjson d "$divisor" '
        # Money in minor units: {amount_minor, exponent} → dollars
        def money:
          if type == "object" then (.amount_minor // 0) / pow(10; (.exponent // 2))
          elif type == "number" then .
          else 0 end;
        def limit_label:
          if .kind == "session" then "5h"
          elif .kind == "weekly_all" then "7d"
          elif .kind == "weekly_scoped" then (.scope.model.display_name // .scope.surface // "scoped")
          else .kind end;
        # Unified spend: prefer modern .spend, fall back to legacy .extra_usage
        (if (.spend.enabled // false) or ((.spend.limit // null) != null) then
           { spent: (.spend.used | money),
             limit: (.spend.limit | if . == null then null else money end),
             percent: .spend.percent,
             enabled: (.spend.enabled // false),
             source: "spend" }
         elif ((.extra_usage.monthly_limit // 0) > 0 or (.extra_usage.is_enabled // false)) then
           (if .extra_usage.decimal_places != null
            then pow(10; .extra_usage.decimal_places) else $d end) as $div |
           { spent: ((.extra_usage.used_credits  // 0) / $div),
             limit: ((.extra_usage.monthly_limit // 0) / $div),
             percent: .extra_usage.utilization,
             enabled: (.extra_usage.is_enabled // false),
             source: "extra_usage" }
         else
           { spent: null, limit: null, percent: null, enabled: false, source: null }
         end) as $spend |
        {
          spend: $spend,
          limits: [ (.limits // [])[]
                    | { kind, label: limit_label, percent, severity,
                        resets_at, active: (.is_active // false),
                        scope: (.scope.model.display_name // .scope.surface // null) } ],
          # legacy convenience fields
          five_hour_pct:  .five_hour.utilization,
          seven_day_pct:  .seven_day.utilization,
          opus_pct:       .seven_day_opus.utilization,
          sonnet_pct:     .seven_day_sonnet.utilization
        }' "$cache"
      ;;
    pretty)
      jq -r --argjson d "$divisor" '
        def money:
          if type == "object" then (.amount_minor // 0) / pow(10; (.exponent // 2))
          elif type == "number" then .
          else 0 end;
        def fmt2: (. * 100 | round / 100);
        def limit_label:
          if .kind == "session" then "5h"
          elif .kind == "weekly_all" then "7d"
          elif .kind == "weekly_scoped" then (.scope.model.display_name // .scope.surface // "scoped")
          else .kind end;
        # "!" marks non-normal severity (warning/exceeded)
        def limit_line: "\(limit_label) \(.percent // 0 | round)%\(if (.severity // "normal") != "normal" then "!" else "" end)";

        # 1) Modern spend object with a cap
        if (.spend.limit // null) != null then
          (.spend.used | money) as $s | (.spend.limit | money) as $l |
          "$\($s | fmt2) / $\($l | fmt2) (\(.spend.percent // (if $l > 0 then $s / $l * 100 else 0 end) | round)%)"
        # 2) Legacy extra_usage cap (work seats on older schema)
        elif (.extra_usage.monthly_limit // 0) > 0 then
          (if .extra_usage.decimal_places != null
           then pow(10; .extra_usage.decimal_places) else $d end) as $div |
          ((.extra_usage.used_credits  // 0) / $div) as $s |
          ((.extra_usage.monthly_limit // 0) / $div) as $l |
          "$\($s | fmt2) / $\($l | fmt2) (\($s / $l * 100 | round)%)"
        # 3) No USD cap: rate limits — prefer the modern limits[] array
        elif ((.limits // []) | length) > 0 then
          [ .limits[] | limit_line ] | join(" | ")
        # 4) Oldest fallback: flat five_hour / seven_day fields
        else
          [ "5h \(.five_hour.utilization // 0 | round)%",
            "7d \(.seven_day.utilization // 0 | round)%",
            (if (.seven_day_opus.utilization) != null
             then "opus \(.seven_day_opus.utilization | round)%" else empty end),
            (if (.seven_day_sonnet.utilization) != null
             then "sonnet \(.seven_day_sonnet.utilization | round)%" else empty end)
          ] | join(" | ")
        end
      ' "$cache"
      ;;
  esac
}

# Convenience helpers matching the claude-personal / claude-work wrappers
claude-usage-personal() { claude-usage --dir "$HOME/.claude-personal" "$@"; }
claude-usage-work()     { claude-usage --dir "$HOME/.claude"          "$@"; }
