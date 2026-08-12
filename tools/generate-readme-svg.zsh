#!/usr/bin/env zsh
# ---------------------------------------------------------------------------
# tools/generate-readme-svg.zsh — regenerate the README SVGs.
#
# Renders the REAL claude-auto-window into SVG terminal windows: builds a
# hermetic sandbox (a fake $HOME, a stub `curl` standing in for the OAuth usage
# endpoint, a stub `security` so the macOS Keychain is never touched, and — for
# the multi-account shot — a stub claude-profile), runs `--status` **unmodified**
# with CLAUDE_AUTO_WINDOW_COLOR=always, and lays its output out on a terminal
# grid. The text in the images is therefore genuine output, colour and all —
# not art. Only the window chrome around it is drawn.
#
# Sibling of ccfind's / claude-profile's tools/generate-readme-svg.zsh, from
# which the grid + emitter core here is borrowed; keep them roughly in sync.
# Two differences worth knowing:
#
#   * claude-auto-window has no TUI — there is no picker to stub and no cursor
#     addressing to replay. The whole capture is one command's stdout, so the
#     sandbox exists to fake the *network*, not the terminal: a stub `curl`
#     serves canned usage JSON, which is what makes the window state, the
#     percentages and the balance-gate verdict in the images deterministic.
#   * one image is not a capture at all. `timeline` is a schematic of the
#     daemon's sleep/fire cycle — there is no output to photograph, because the
#     thing worth showing is what happens across five hours. It is hand-authored
#     below and animated with a CSS keyframe timeline; prefers-reduced-motion
#     freezes it.
#
# Usage:  zsh tools/generate-readme-svg.zsh
#           → assets/{status,accounts,timeline}-<hash>.svg, older ones deleted,
#             README <img> references rewritten (the random hash busts GitHub's
#             camo image cache). Commit all three files.
#         zsh tools/generate-readme-svg.zsh OUTDIR
#           → fixed names in OUTDIR, README untouched (for eyeballing a change).
#
# Regenerate whenever the --status line format, the colours, or these demo
# values change.
# ---------------------------------------------------------------------------
emulate -L zsh
setopt extended_glob

zmodload zsh/datetime

here=${0:a:h}
root=${here:h}

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

# ---- hermetic sandbox ------------------------------------------------------
# A fake $HOME plus a stubbed PATH. Nothing here reads the operator's real
# ~/.claude, their Keychain, their config file, or the network.
fakehome="$tmp/home"
cfgdir="$fakehome/.claude"
mkdir -p "$cfgdir" "$tmp/bin" "$tmp/state" "$tmp/xdg"

export HOME="$fakehome"
export USER=demo
export XDG_CONFIG_HOME="$tmp/xdg"          # keeps the real config file out
export XDG_STATE_HOME="$tmp/state"
export CLAUDE_AUTO_WINDOW_STATE_DIR="$tmp/state/caw"
export CLAUDE_AUTO_WINDOW_COLOR=always     # capture is a pipe; force the colour
unset CLAUDE_CONFIG_DIR CLAUDE_AUTO_WINDOW_CONFIG CLAUDE_AUTO_WINDOW_PROFILES \
      CLAUDE_AUTO_WINDOW_CONFIG_DIR CLAUDE_AUTO_WINDOW_MODEL NO_COLOR

# A credential blob the script will accept: far-future expiry so it always wins
# the freshest-token race, and an obviously fake token.
print -r -- '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-DEMO-NOT-A-REAL-TOKEN","expiresAt":4102444800000}}' \
  > "$cfgdir/.credentials.json"

# stub curl: the OAuth usage endpoint, served from $CAW_FAKE_USAGE. The real
# script's argv is ignored — it only ever asks this one endpoint one way.
cat > "$tmp/bin/curl" <<'STUB'
#!/bin/sh
cat "$CAW_FAKE_USAGE"
STUB

# stub security: on macOS _caw_resolve_token also consults the Keychain. Return
# nothing, so the sandbox can never pick up a real credential.
cat > "$tmp/bin/security" <<'STUB'
#!/bin/sh
exit 1
STUB

chmod +x "$tmp/bin/curl" "$tmp/bin/security"
export PATH="$tmp/bin:$PATH"

# ---- canned usage payloads -------------------------------------------------
# The shape _caw_usage_json validates and _caw_status_line reads: a limits[]
# array carrying the session (5h) window plus the weekly buckets the balance
# gate consults, and the optional extra_usage credit block.
# The endpoint stamps resets_at in UTC, and the script compares it against
# `date -u`. zsh's strftime renders LOCAL time, so building the demo timestamps
# with it would label local time as +00:00 and put a just-expired window an
# hour or two in the "future" — i.e. show it open when it should read closed.
utc_iso() {   # <epoch> → 2026-08-12T13:02:38.000000+00:00
  local e=$1 o
  o=$(date -u -r "$e" +'%Y-%m-%dT%H:%M:%S' 2>/dev/null) \
    || o=$(date -u -d "@$e" +'%Y-%m-%dT%H:%M:%S' 2>/dev/null)
  print -r -- "${o}.000000+00:00"
}

usage_json() {   # <session-percent> <resets-in-seconds> <weekly-all-percent> [scoped-name] [scoped-percent]
  local pct=$1 resets_in=$2 wall=$3 sname=${4:-} spct=${5:-0}
  local resets; resets=$(utc_iso $(( EPOCHSECONDS + resets_in )))
  local scoped=""
  [[ -n $sname ]] && scoped=",{\"kind\":\"weekly_scoped\",\"percent\":$spct,\"severity\":\"normal\",\"scope\":{\"model\":{\"display_name\":\"$sname\"}}}"
  cat <<JSON
{"limits":[
  {"kind":"session","percent":$pct,"severity":"normal","resets_at":"$resets","is_active":false},
  {"kind":"weekly_all","percent":$wall,"severity":"normal"}$scoped
],
"extra_usage":{"is_enabled":true,"decimal_places":2,"used_credits":0,"monthly_limit":2500,"currency":"USD","utilization":0}}
JSON
}

# ---- capture the real output ----------------------------------------------
caw="$root/claude-auto-window"

# The ONE edit made to captured text: the sandbox lives under a mktemp path, so
# the profile dir would render as /private/var/folders/…/T/tmp.XXXX/home/.claude.
# Rewrite that prefix to a plain home. Nothing else in the capture is touched —
# the colours, the field order and the values are all the script's own.
demoize() { sed -e "s|$fakehome|/home/demo|g" }

capture() {   # <outfile> <usage-file> [extra args...]
  local out=$1 usage=$2; shift 2
  CAW_FAKE_USAGE="$usage" CLAUDE_AUTO_WINDOW_CLAUDE_PROFILE=off \
    zsh "$caw" --status "$@" 2>/dev/null | demoize > "$out"
}

# 1. the hero: a single profile, window open, plenty of plan left.
usage_json 34 9480 22 Fable 71 > "$tmp/usage-open.json"
rm -rf "$tmp/state/caw"
capture "$tmp/cap-status.txt" "$tmp/usage-open.json"

# ---- stub claude-profile: several subscriptions in one config dir ----------
# For the multi-account shot only. claude-auto-window shells out to
# `claude-profile.py usage-json --account X` and parses "<label>\t<json>", so a
# stub that serves canned JSON per account is enough to drive the real
# per-account status path end to end.
mkdir -p "$tmp/xdg/claude-profile" "$tmp/cp"
cat > "$tmp/xdg/claude-profile/config.json" <<JSON
{"profiles":{"personal":{"dir":"$fakehome/.claude","accounts":["max20x","max5x"]}}}
JSON

cat > "$tmp/bin/claude-profile.py" <<'STUB'
import os, sys
acct = sys.argv[sys.argv.index("--account") + 1]
body = open(os.environ["CAW_FAKE_CP_DIR"] + "/" + acct + ".json").read().strip()
sys.stdout.write(acct + "\t" + body + "\n")
STUB

# max20x: window open, on plan. max5x: window closed AND its weekly allowance
# spent — the balance gate standing down rather than burning credits, which is
# the state worth showing next to a healthy one.
usage_json 61 6120 44 Fable 80 | jq -c . > "$tmp/cp/max20x.json"
usage_json  0 -60  100 Fable 96 | jq -c . > "$tmp/cp/max5x.json"

rm -rf "$tmp/state/caw"
CAW_FAKE_CP_DIR="$tmp/cp" \
CLAUDE_AUTO_WINDOW_CLAUDE_PROFILE=on \
CLAUDE_AUTO_WINDOW_CLAUDE_PROFILE_PY="$tmp/bin/claude-profile.py" \
  zsh "$caw" --status 2>/dev/null | demoize > "$tmp/cap-accounts.txt"

# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------
# Catppuccin Mocha chrome, matching the sibling generators.
BG='#1e1e2e'  BAR='#181825'  FG='#cdd6f4'  DIMC='#9399b2'
DOT1='#f38ba8' DOT2='#f9e2af' DOT3='#a6e3a1'
ACC='#89dceb'                       # shell prompt
# The 8 normal + 8 bright ANSI foregrounds these images can contain.
typeset -a ANSI_N ANSI_B
ANSI_N=('#45475a' '#f38ba8' '#a6e3a1' '#f9e2af' '#89b4fa' '#f5c2e7' '#94e2d5' '#bac2de')
ANSI_B=('#585b70' '#f38ba8' '#a6e3a1' '#f9e2af' '#89b4fa' '#f5c2e7' '#94e2d5' '#a6adc8')
FONT="'Cascadia Code','Fira Code',SFMono-Regular,Consolas,Menlo,monospace"
integer FS=13 LH=20 TH=30 PX=20 PY=14 SLACK=24

# Terminal grid: every character is pinned to its own cell, so a row occupies
# exactly (columns × cw) in whichever font the renderer falls back to — which
# is what keeps the columns aligned in a browser that has none of these fonts.
typeset -a XCOL
local -F cw=7.85
integer k; local v
for (( k = 0; k <= 400; k++ )); do printf -v v '%.2f' $(( PX + k * cw )); XCOL[k+1]=$v; done
xrun() { print -rn -- "${(j: :)XCOL[$1+1,$1+$2]}" }
xat()  { print -rn -- "$XCOL[$1+1]" }
xesc() { local s=$1; s=${s//\&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; print -rn -- "$s" }

# Visible length of a line, ignoring SGR — what the grid must size to.
vlen() { local t=$1; t=${t//$'\e['[0-9;]#m/}; print -rn -- ${#t} }

# render_ansi <line> — SGR runs to <tspan>s, one x per character cell. Sets
# RENDERED rather than printing, so it can be called without a subshell.
typeset -g RENDERED
render_ansi() {
  local s=$1 out="" pre tail params pcode fill="" attrs=""
  integer col=0 bold=0 dim=0
  local cidx=""
  local -a parts
  recompute() {
    if [[ -n $cidx ]]; then (( bold )) && fill=$ANSI_B[cidx+1] || fill=$ANSI_N[cidx+1]
    elif (( dim )); then fill=$DIMC
    else fill=""; fi
  }
  while [[ -n $s ]]; do
    pre=${s%%$'\e'*}
    if [[ -n $pre ]]; then
      attrs=""
      [[ -n $fill ]] && attrs+=" fill=\"$fill\""
      (( bold )) && attrs+=' font-weight="bold"'
      out+="<tspan x=\"$(xrun col ${#pre})\"$attrs>$(xesc "$pre")</tspan>"
      (( col += ${#pre} ))
    fi
    s=${s[$(( ${#pre} + 1 )),-1]}
    [[ -n $s ]] || break
    if [[ ${s[2]} == '[' ]]; then
      tail=${s#$'\e['}; params=${tail%%m*}
      s=${tail[$(( ${#params} + 2 )),-1]}
      parts=(${(s:;:)params}); (( ${#parts} )) || parts=(0)
      for pcode in $parts; do
        case $pcode in
          0)  bold=0; dim=0; cidx="" ;;
          1)  bold=1 ;;
          2)  dim=1 ;;
          <30-37>) cidx=$(( pcode - 30 )) ;;
          <90-97>) cidx=$(( pcode - 90 )); bold=1 ;;
          39) cidx="" ;;
        esac
      done
      recompute
    else
      s=${s[3,-1]}
    fi
  done
  RENDERED="$out"
}

# emit_lines <array-name> <y0> — draw the pane. Entry format TYPE|content:
#   b = blank   t = plain   c = dim   a = ANSI (captured output)
#   d = shell command line: prompt in accent, command in FG, block cursor after
emit_lines() {
  local -a _l=("${(@P)1}")
  integer y0=$2
  local entry typ body T out=""
  integer i=0 y
  for entry in "${_l[@]}"; do
    typ=${entry%%\|*}; body=${entry#*|}
    y=$(( y0 + i * LH + FS ))
    T="  <text y=\"$y\" font-family=\"$FONT\" font-size=\"$FS\" xml:space=\"preserve\""
    case $typ in
      b) ;;
      t) out+="$T fill=\"$FG\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>"$'\n' ;;
      c) out+="$T fill=\"$DIMC\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>"$'\n' ;;
      a) render_ansi "$body"
         out+="$T fill=\"$FG\">$RENDERED</text>"$'\n' ;;
      d) out+="  <rect x=\"$(xat $(( ${#body} + 3 )))\" y=\"$(( y - FS + 1 ))\" width=\"8\" height=\"$(( FS + 3 ))\" fill=\"$FG\" opacity=\"0.75\"/>"$'\n'
         out+="$T><tspan x=\"$(xat 0)\" fill=\"$ACC\">$</tspan><tspan x=\"$(xrun 2 ${#body})\" fill=\"$FG\">$(xesc "$body")</tspan></text>"$'\n' ;;
    esac
    (( i++ ))
  done
  print -rn -- "$out"
}

# chrome <W> <H> <title> — the window: rounded body, title bar, traffic lights.
chrome() {
  integer W=$1 H=$2
  print -r -- "  <rect width=\"$W\" height=\"$H\" rx=\"10\" fill=\"$BG\"/>"
  print -r -- "  <rect width=\"$W\" height=\"$TH\" rx=\"10\" fill=\"$BAR\"/>"
  print -r -- "  <rect y=\"$(( TH - 6 ))\" width=\"$W\" height=\"6\" fill=\"$BAR\"/>"
  print -r -- "  <circle cx=\"18\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT1\"/><circle cx=\"36\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT2\"/><circle cx=\"54\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT3\"/>"
  print -r -- "  <text x=\"$(( W / 2 ))\" y=\"$(( TH / 2 + 5 ))\" text-anchor=\"middle\" font-family=\"$FONT\" font-size=\"12\" fill=\"$DIMC\">$3</text>"
}

svg_open() {
  print -r -- "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$1\" height=\"$2\" viewBox=\"0 0 $1 $2\" role=\"img\" aria-label=\"$(xesc "$3")\">"
}
svg_close() { print -r -- "</svg>" }

canvas_w() { print -rn -- $(( PX * 2 + $1 * cw + 6 + SLACK )) }
canvas_h() { print -rn -- $(( TH + PY + $1 * LH + PY )) }

# ---------------------------------------------------------------------------
# compose the two captures
# ---------------------------------------------------------------------------
# term_svg <capture-file> <title> <command> <aria> — one terminal window
# holding the command line and the output it produced.
term_svg() {
  local cap=$1 title=$2 cmd=$3 aria=$4
  local -a lines; lines=("d|$cmd" "b|")
  local ln; integer cols=$(( ${#cmd} + 4 ))
  while IFS= read -r ln; do
    lines+=("a|$ln")
    (( $(vlen "$ln") > cols )) && cols=$(vlen "$ln")
  done < "$cap"
  integer W=$(canvas_w $cols) H=$(canvas_h ${#lines})
  svg_open $W $H "$aria"
  chrome $W $H "$title"
  emit_lines lines $(( TH + PY ))
  svg_close
}

# ---------------------------------------------------------------------------
# the timeline: a schematic, not a capture
# ---------------------------------------------------------------------------
# The one thing about this tool that prose keeps needing a paragraph for is what
# it does across five hours: a window opens, the daemon SLEEPS through it rather
# than polling, wakes just after it expires, fires one starter, and the next
# window begins. There is no terminal output to photograph — the subject is the
# passage of time — so this image is drawn rather than captured.
#
# Animated with CSS keyframes rather than SMIL, for the same reason as ccfind's
# demo: an SVG in an <img> is rendered with scripting disabled but declarative
# animation live, and keyframes are the mechanism that reliably survives that
# trip. Every animated element's BASE state is the frame the animation would
# show at the moment the starter fires, so prefers-reduced-motion (which turns
# the animations off) freezes on a frame that still tells the whole story.
GREEN='#a6e3a1' YELLOW='#f9e2af' BLUE='#89b4fa' MAUVE='#cba6f7'

timeline_svg() {
  integer W=880 H=276
  integer X0=170 X1=850            # the time axis
  integer XM=$(( (X0 + X1) / 2 ))  # the boundary between the two windows
  integer SPAN=$(( X1 - X0 )) HALF=$(( (X1 - X0) / 2 ))
  integer YW=78  HW=26             # window row
  integer YD=134 HD=20             # daemon row
  integer YR=186                   # request row
  integer YA=216                   # axis

  svg_open $W $H "A timeline of two consecutive five-hour windows. The first window fills, and while it is open the daemon sleeps rather than polling. Just after it expires the daemon wakes, checks the usage endpoint, fires one starter, and a second window opens and begins filling. Two requests are spent per window."
  print -r -- "<defs><style>
    .lbl{font-family:$FONT;font-size:11px;fill:$DIMC}
    .txt{font-family:$FONT;font-size:11px;fill:$FG}
    .ttl{font-family:$FONT;font-size:13px;fill:$FG;font-weight:bold}
    .sub{font-family:$FONT;font-size:11px;fill:$DIMC}
    .fill{transform-box:fill-box;transform-origin:left center}
    /* Base state = the instant the starter fires: window 1 full, window 2 just
       starting, playhead and the fire pulse parked at the boundary. */
    .w1{transform:scaleX(1)}
    .w2{transform:scaleX(0)}
    .head{transform:translateX(${HALF}px)}
    @keyframes w1{0%{transform:scaleX(0)}50%{transform:scaleX(1)}100%{transform:scaleX(1)}}
    @keyframes w2{0%,50%{transform:scaleX(0)}100%{transform:scaleX(1)}}
    @keyframes head{0%{transform:translateX(0)}100%{transform:translateX(${SPAN}px)}}
    @keyframes pulse{0%,44%{opacity:0}48%,56%{opacity:1}62%,100%{opacity:0}}
    @keyframes sleep1{0%{opacity:1}48%{opacity:1}52%,100%{opacity:.25}}
    @keyframes sleep2{0%,48%{opacity:.25}52%{opacity:1}100%{opacity:1}}
    @media (prefers-reduced-motion: no-preference){
      .w1{animation:w1 12s linear infinite}
      .w2{animation:w2 12s linear infinite}
      .head{animation:head 12s linear infinite}
      .pulse{animation:pulse 12s linear infinite}
      .s1{animation:sleep1 12s linear infinite}
      .s2{animation:sleep2 12s linear infinite}
    }
  </style></defs>"
  print -r -- "  <rect width=\"$W\" height=\"$H\" rx=\"10\" fill=\"$BG\"/>"
  print -r -- "  <text x=\"20\" y=\"30\" class=\"ttl\">claude-auto-window --daemon</text>"
  print -r -- "  <text x=\"20\" y=\"48\" class=\"sub\">windows roll back to back — and the daemon sleeps through each one instead of polling it</text>"

  # ---- row labels ----
  print -r -- "  <text x=\"$(( X0 - 14 ))\" y=\"$(( YW + 17 ))\" class=\"lbl\" text-anchor=\"end\">5-hour window</text>"
  print -r -- "  <text x=\"$(( X0 - 14 ))\" y=\"$(( YD + 14 ))\" class=\"lbl\" text-anchor=\"end\">daemon</text>"
  print -r -- "  <text x=\"$(( X0 - 14 ))\" y=\"$(( YR + 4 ))\"  class=\"lbl\" text-anchor=\"end\">spend</text>"

  # ---- window row: two tracks, each with a fill that grows across its slice ----
  local w
  for w in 1 2; do
    integer bx=$(( w == 1 ? X0 : XM ))
    print -r -- "  <rect x=\"$bx\" y=\"$YW\" width=\"$HALF\" height=\"$HW\" rx=\"5\" fill=\"#313244\"/>"
    print -r -- "  <rect x=\"$bx\" y=\"$YW\" width=\"$HALF\" height=\"$HW\" rx=\"5\" fill=\"$GREEN\" opacity=\"0.30\" class=\"fill w$w\"/>"
    print -r -- "  <text x=\"$(( bx + HALF / 2 ))\" y=\"$(( YW + 17 ))\" class=\"txt\" text-anchor=\"middle\">window $w</text>"
  done

  # ---- daemon row: asleep, except for one wake at the boundary ----
  print -r -- "  <rect x=\"$X0\" y=\"$YD\" width=\"$(( HALF - 6 ))\" height=\"$HD\" rx=\"4\" fill=\"$BLUE\" opacity=\"0.16\" class=\"s1\"/>"
  print -r -- "  <text x=\"$(( X0 + HALF / 2 ))\" y=\"$(( YD + 14 ))\" class=\"lbl\" text-anchor=\"middle\">asleep until resets_at</text>"
  print -r -- "  <rect x=\"$(( XM + 6 ))\" y=\"$YD\" width=\"$(( HALF - 6 ))\" height=\"$HD\" rx=\"4\" fill=\"$BLUE\" opacity=\"0.16\" class=\"s2\"/>"
  print -r -- "  <text x=\"$(( XM + HALF / 2 ))\" y=\"$(( YD + 14 ))\" class=\"lbl\" text-anchor=\"middle\">asleep until resets_at</text>"

  # ---- the wake: one tick at the boundary, and the pulse that annotates it ----
  print -r -- "  <rect x=\"$(( XM - 2 ))\" y=\"$(( YD - 4 ))\" width=\"4\" height=\"$(( HD + 8 ))\" rx=\"2\" fill=\"$YELLOW\"/>"
  print -r -- "  <g class=\"pulse\">"
  print -r -- "    <circle cx=\"$XM\" cy=\"$YR\" r=\"5\" fill=\"$YELLOW\"/>"
  print -r -- "    <text x=\"$(( XM + 12 ))\" y=\"$(( YR + 4 ))\" class=\"txt\" fill=\"$YELLOW\">wake · check · fire one starter</text>"
  print -r -- "  </g>"

  # ---- spend row: the two requests a window actually costs ----
  print -r -- "  <circle cx=\"$(( X0 + 14 ))\" cy=\"$YR\" r=\"4\" fill=\"$MAUVE\"/>"
  print -r -- "  <text x=\"$(( X0 + 26 ))\" y=\"$(( YR + 4 ))\" class=\"lbl\">confirm the new window</text>"

  # ---- axis ----
  print -r -- "  <line x1=\"$X0\" y1=\"$YA\" x2=\"$X1\" y2=\"$YA\" stroke=\"#45475a\" stroke-width=\"1\"/>"
  local t
  for t in "$X0:0h" "$XM:5h" "$X1:10h"; do
    print -r -- "  <line x1=\"${t%%:*}\" y1=\"$YA\" x2=\"${t%%:*}\" y2=\"$(( YA + 5 ))\" stroke=\"#45475a\"/>"
    print -r -- "  <text x=\"${t%%:*}\" y=\"$(( YA + 18 ))\" class=\"lbl\" text-anchor=\"middle\">${t#*:}</text>"
  done

  # ---- footer: the cost claim the whole design exists to make ----
  print -r -- "  <text x=\"20\" y=\"$(( H - 14 ))\" class=\"sub\">≈2 requests per 5-hour window — one to confirm it opened, one at expiry. Nothing in between.</text>"

  # ---- playhead ----
  print -r -- "  <g class=\"head\">"
  print -r -- "    <line x1=\"$X0\" y1=\"$(( YW - 8 ))\" x2=\"$X0\" y2=\"$(( YA + 2 ))\" stroke=\"$FG\" stroke-width=\"1.5\" opacity=\"0.85\"/>"
  print -r -- "    <circle cx=\"$X0\" cy=\"$(( YW - 12 ))\" r=\"3.5\" fill=\"$FG\"/>"
  print -r -- "  </g>"
  svg_close
}

# ---------------------------------------------------------------------------
# write
# ---------------------------------------------------------------------------
outdir=${1:-}
if [[ -n $outdir ]]; then
  mkdir -p "$outdir"; hash=""
else
  outdir="$root/assets"; mkdir -p "$outdir"
  hash=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
fi
name() { [[ -n $hash ]] && print -rn -- "$1-$hash.svg" || print -rn -- "$1.svg" }

term_svg "$tmp/cap-status.txt" "claude-auto-window --status" \
  "claude-auto-window --status" \
  "A terminal showing claude-auto-window --status for one profile: the five-hour window is open at 34 percent with its reset time, the balance gate says it would fire a starter on the haiku model, and no usage credits have been spent." \
  > "$outdir/$(name status)"

term_svg "$tmp/cap-accounts.txt" "claude-auto-window --status — two subscriptions" \
  "claude-auto-window --status" \
  "A terminal showing claude-auto-window --status across two subscriptions held in one config dir: max20x has an open window and would fire, while max5x has a closed window but its weekly plan allowance is spent, so the balance gate reports WOULD SKIP rather than spending usage credits." \
  > "$outdir/$(name accounts)"

timeline_svg > "$outdir/$(name timeline)"

# ---- point the README at the new files, and drop the superseded ones --------
# The hash in each filename is cache-busting: GitHub proxies README images
# through camo, which caches hard, so a changed image at an unchanged URL can
# keep serving the old bytes for a long time. A new name sidesteps it entirely.
if [[ -n $hash ]]; then
  readme="$root/README.md"
  for base in status accounts timeline; do
    for old in "$outdir"/$base-*.svg(N); do
      [[ ${old:t} == "$base-$hash.svg" ]] || rm -f "$old"
    done
    if [[ -r $readme ]]; then
      perl -pi -e "s{assets/$base-[0-9a-f]+\\.svg}{assets/$base-$hash.svg}g" "$readme"
    fi
  done
fi

print -r -- "wrote:"
for f in "$outdir"/*.svg(N); do printf '  %-52s %s bytes\n' "${f:t}" "$(wc -c < "$f" | tr -d ' ')"; done
