#!/usr/bin/env bash
# wattun-manager: set up and run WatTunnel tunnels.
#   Kharej = the outside server (runs the real service, the tunnel SERVER)  -> set it up FIRST, it makes the token
#   Iran   = the inside server users connect to (the tunnel CLIENT)          -> paste the token there
# Each tunnel is /etc/wattun/NAME.yml + NAME.key (+ NAME.token on Kharej), run by systemd as wattun@NAME.
# Run it without arguments for the dashboard. Commands:
#   wattun-manager [new [kharej|iran]|kharej|iran|status|list|monitor|ports NAME|test NAME|
#                   speedtest NAME [MB]|logs NAME|token NAME|heal|update|rollback|help]
#   Censor starts blocking the tunnel (whitelist regime): blackout NAME [SNI] turns the resilience kit
#                   (fake-SNI desync + defaults) on with one command; profiles save/apply combinations.
#   Auto carrier (one token, Iran tests every connection type): auto-test NAME | auto-ip NAME IP |
#                   auto-watch NAME | auto-retest NAME   (the last two are run by systemd, not by hand)
#   CDN carriers (ws, wss, h2, h2c, grpc via Cloudflare; wattun >= 2.2.0): cdn-tune NAME [full]
#   Unattended (no tty, for scripts and test rigs): kharej --carrier C --name N --yes | iran --token T --map L:T --yes |
#                   cdn-tune NAME --yes | auto-test NAME --yes | delete NAME --yes | uninstall --yes   (see: help)
# Environment: WAT_NO_ANIM=1 (no animations), NO_COLOR=1 (no colours), WAT_REPO, WAT_PROXY, WAT_PREFIX (sandbox, see below).
set -uo pipefail
shopt -s extglob

# Sandbox: WAT_PREFIX=NAME (default wattun) moves every path and unit name this manager creates or controls:
#   $CONF=/etc/NAME  $RUN=/run/NAME  $AUTO_RUN=/run/NAME-auto  $BIN=/opt/NAME/wattun  units NAME@X, NAME-heal, NAME-autowatch-X.
# WAT_CONF / WAT_BIN / WAT_RUN / WAT_AUTO_RUN still override single paths. The manager itself is then THIS script file.
WAT_PREFIX=${WAT_PREFIX:-wattun}
case "$WAT_PREFIX" in ''|-*|*[!A-Za-z0-9_.]*|*-) printf 'WAT_PREFIX must be letters, digits, "_" or "." and may contain "-" inside (got "%s").\n' "$WAT_PREFIX" >&2; exit 1 ;; esac
SANDBOX=0; [ "$WAT_PREFIX" = wattun ] || SANDBOX=1
CONF=${WAT_CONF:-/etc/$WAT_PREFIX}
RUN=${WAT_RUN:-/run/$WAT_PREFIX}
if [ "$SANDBOX" = 1 ]; then
  BIN=${WAT_BIN:-/opt/$WAT_PREFIX/wattun}
  MGR=$(readlink -f "$0" 2>/dev/null || echo "$0")
  # a sandbox must never share a path with the production install
  if [ "$CONF" = /etc/wattun ] || [ "$BIN" = /usr/local/bin/wattun ] || [ "$RUN" = /run/wattun ]; then
    printf 'Sandbox %s refuses to use a production path (CONF=%s BIN=%s RUN=%s MGR=%s).\n' "$WAT_PREFIX" "$CONF" "$BIN" "$RUN" "$MGR" >&2; exit 1
  fi
  export WAT_PREFIX
else
  BIN=${WAT_BIN:-/usr/local/bin/wattun}
  MGR=/usr/local/bin/wattun-manager
fi
REPO=${WAT_REPO:-JohnWatsoon/WatTunnel}
MGR_VERSION=2026102201   # YYYYMMDDNN; install.sh refuses to replace a newer manager with an older one
HEAL_UNIT=$WAT_PREFIX-heal
MCONF=$CONF/.manager.conf
self_cmd() { # the command to type to start this manager (user-facing hints)
  if [ "$SANDBOX" = 1 ]; then printf 'WAT_PREFIX=%s %s' "$WAT_PREFIX" "$MGR"; else printf wattun; fi
}
SELF=$(self_cmd)
# Environment for units that call this manager again (heal timer, watcher, retest): same sandbox, same paths.
unit_env_lines() { # Environment= lines for a service file
  [ "$SANDBOX" = 1 ] && printf 'Environment="WAT_PREFIX=%s"\n' "$WAT_PREFIX"
  [ -n "${WAT_CONF:-}" ] && printf 'Environment="WAT_CONF=%s"\n' "$WAT_CONF"
  [ -n "${WAT_BIN:-}" ] && printf 'Environment="WAT_BIN=%s"\n' "$WAT_BIN"
  [ -n "${WAT_RUN:-}" ] && printf 'Environment="WAT_RUN=%s"\n' "$WAT_RUN"
  [ -n "${WAT_AUTO_RUN:-}" ] && printf 'Environment="WAT_AUTO_RUN=%s"\n' "$WAT_AUTO_RUN"
  return 0
}
run_env_args() { # --setenv arguments for systemd-run, one per line (read with mapfile)
  printf '%s\n' "--setenv=WAT_CONF=$CONF" "--setenv=WAT_RUN=$RUN" "--setenv=WAT_PREFIX=$WAT_PREFIX"
  [ -n "${WAT_BIN:-}" ] || [ "$SANDBOX" = 1 ] && printf '%s\n' "--setenv=WAT_BIN=$BIN"
  [ -n "${WAT_AUTO_RUN:-}" ] && printf '%s\n' "--setenv=WAT_AUTO_RUN=$WAT_AUTO_RUN"
  return 0
}
# The systemd template unit NAME@.service. install.sh writes wattun@.service; in a sandbox the manager writes its own.
ensure_template() {
  [ "$SANDBOX" = 1 ] || return 0
  local f="/etc/systemd/system/$WAT_PREFIX@.service"
  [ -f "$f" ] && return 0
  cat >"$f" <<EOF
[Unit]
Description=WatTunnel %i (sandbox $WAT_PREFIX)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$BIN -config $CONF/%i.yml
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitMEMLOCK=infinity
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$f" && systemctl daemon-reload && ok "Sandbox: created $f (ExecStart $BIN, configs in $CONF)"
}
LIB=${WAT_MANAGER_LIB:-0}

# Non-interactive mode: no tty, no stdin reads, no animation, no screen clearing, plain lines. Every prompt helper
# (ask, ask_ok, confirm, key_read, pick_carrier, port_editor, at_choose...) answers with its preset or default.
# On with --yes, or NONINTERACTIVE=1 in the environment, or when stdin is not a tty and a --flag is given.
NONINTERACTIVE=${NONINTERACTIVE:-0}
case "${1:-}" in kharej|iran|cdn-tune|auto-test|delete|uninstall|matrix|auto-retest)
  for _a in "$@"; do
    case "$_a" in --yes) NONINTERACTIVE=1 ;; --*) [ -t 0 ] || NONINTERACTIVE=1 ;; esac
  done ;;
esac
[ "$NONINTERACTIVE" = 1 ] || NONINTERACTIVE=0
# Answers set by flags (see ni_parse); empty = the wizard's own default
NI_CARRIER=''; NI_NAME=''; NI_LISTEN=''; NI_PATH=''; NI_ADDR=''; NI_SNI=''; NI_CDN=''; NI_PORTS=''; NI_MBPS=''; NI_FAKESNI=''; NI_FAKEMODE=''; NI_FAKETTL=''; NI_POOLROT=''; NI_POOLBYTES=''; NI_PRESET=''; NI_ECH=''; NI_GOVERNOR=''; NI_DNSLISTEN=''; NI_SRCIP=''
NI_TOKEN=''; NI_MAP=''; NI_PICK=best; NI_SESSIONS=''; NI_YES=0; NI_POS=()
ERRN=0

case "$(locale charmap 2>/dev/null)" in UTF-8) ;; *) export LC_ALL=C.UTF-8 ;; esac

# ======================================================================================
#  Terminal UI core: colours, cursor, animations, prompts
# ======================================================================================
IS_TTY=0; [ -t 1 ] && IS_TTY=1
[ "$NONINTERACTIVE" = 1 ] && IS_TTY=0
USE_COLOR=0
if [ "${WAT_FORCE_COLOR:-0}" = 1 ] || { [ "$IS_TTY" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }; then USE_COLOR=1; fi
[ "$NONINTERACTIVE" = 1 ] && USE_COLOR=0
NCOL=8
if [ "$USE_COLOR" = 1 ]; then
  NCOL=$(tput colors 2>/dev/null || echo 8)
  case "${TERM:-}" in *256color*) NCOL=256 ;; esac
  case "$NCOL" in ''|*[!0-9]*) NCOL=8 ;; esac
fi
if [ "$USE_COLOR" = 1 ]; then
  RST=$'\e[0m'; BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
  CYN=$'\e[36m'; BLU=$'\e[34m'; GRY=$'\e[90m'
else
  RST=''; BOLD=''; RED=''; GRN=''; YEL=''; CYN=''; BLU=''; GRY=''
fi

conf_get() { local v; v=$(sed -n "s/^$1=//p" "$MCONF" 2>/dev/null | tail -1); echo "${v:-$2}"; }
conf_set() {
  mkdir -p "$CONF"; touch "$MCONF"; chmod 600 "$MCONF"
  sed -i "/^$1=/d" "$MCONF"; echo "$1=$2" >>"$MCONF"
}
ANIM=0
if [ "$IS_TTY" = 1 ] && [ "${WAT_NO_ANIM:-0}" != 1 ] && [ "$(conf_get anim 1)" = 1 ]; then ANIM=1; fi

SPIN_PID=''
LOGF=''
LINK_RTT=''
IN_FLOW=0
INTRO_DONE=0
KEY=''
REPLY_V=''

cur_hide() { [ "$IS_TTY" = 1 ] && printf '\e[?25l'; return 0; }
cur_show() { [ "$IS_TTY" = 1 ] && printf '\e[?25h'; return 0; }
kill_spin() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; SPIN_PID=''; fi
  return 0
}
cleanup() { kill_spin; cur_show; [ -n "$LOGF" ] && rm -f "$LOGF"; at_cleanup; return 0; }
on_int() { [ "$IN_FLOW" = 1 ] && return 0; cleanup; printf '\n'; exit 130; }
eof_exit() { cleanup; echo; exit 0; }

rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
VLEN=0
vlen() { local s=${1//$'\e'\[*([0-9;?])[a-zA-Z]/}; VLEN=${#s}; }
strip_ansi() { printf '%s' "${1//$'\e'\[*([0-9;?])[a-zA-Z]/}"; }

# ---- plain messages ----
say()  { printf '%b\n' "$*"; }
ok()   { printf '  %s✔%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
err()  { ERRN=$((ERRN+1)); if [ "$NONINTERACTIVE" = 1 ]; then printf 'error: %s\n' "$*" >&2; else printf '  %s✘%s %s\n' "$RED" "$RST" "$*"; fi; }
hint() { printf '  %s%s%s\n' "$GRY" "$*" "$RST"; }
hr()   { printf '  %s%s%s\n' "$GRY" "$(rep ─ 74)" "$RST"; }
key_label() { printf '%s[%s]%s' "$CYN" "$1" "$RST"; }

# ---- gradient banner (cyan -> blue -> magenta), kite on the left ----
GR_N=(51 45 39 33 63 99 135 171)
GR_F=(36 36 36 34 34 35 35 35)
GFG=''
gfg() { # index -> GFG escape
  GFG=''; [ "$USE_COLOR" = 1 ] || return 0
  local i=$(( $1 % 8 ))
  if [ "$NCOL" -ge 256 ]; then printf -v GFG '\e[1;38;5;%sm' "${GR_N[$i]}"; else printf -v GFG '\e[1;%sm' "${GR_F[$i]}"; fi
}
WATTUN_BANNER=(
  '██     ██  ▄▄▄ ▄▄▄▄▄▄ ██████ ▄▄ ▄▄ ▄▄  ▄▄ ▄▄  ▄▄ '
  '██ ▄█▄ ██ ██▀██  ██     ██   ██ ██ ███▄██ ███▄██ '
  ' ▀██▀██▀  ██▀██  ██     ██   ▀███▀ ██ ▀██ ██ ▀██ '
)
META_GITHUB='https://github.com/JohnWatsoon'
META_TELEGRAM='@Watdevs'

banner() { # [1 = animated reveal]
  local i cols GFG
  cols=$(tput cols 2>/dev/null || echo 80)
  if [ "$cols" -ge 84 ]; then
    local side=(
      "┌─ WatTun Community ─────────┐"
      "│ GitHub:   github.com/JohnWatsoon"
      "│ Telegram: @Watdevs"
      "└────────────────────────────┘"
    )
    for i in 0 1 2; do
      gfg "$i"
      local left="${WATTUN_BANNER[$i]}"
      local right="${side[$i]}"
      if [ "$USE_COLOR" = 1 ]; then
        case "$i" in
          0) right="${GRY}┌─ ${CYN}WatTun Community${GRY} ─────────┐${RST}" ;;
          1) right="${GRY}│${RST} ${CYN}GitHub:${RST}   github.com/JohnWatsoon" ;;
          2) right="${GRY}│${RST} ${CYN}Telegram:${RST} ${BOLD}@Watdevs${RST}" ;;
        esac
      fi
      printf '  %s%s%s  %s\n' "$GFG" "$left" "$RST" "$right"
      [ "${1:-0}" = 1 ] && sleep 0.03
    done
    printf '  %*s  %s\n' 49 '' "${GRY}└────────────────────────────┘${RST}"
  elif [ "$cols" -ge 80 ]; then
    local side=(
      "┌─ WatTun Community ──────┐"
      "│ GitHub:   JohnWatsoon   │"
      "│ Telegram: @Watdevs      │"
      "└─────────────────────────┘"
    )
    for i in 0 1 2; do
      gfg "$i"
      local left="${WATTUN_BANNER[$i]}"
      local right="${side[$i]}"
      if [ "$USE_COLOR" = 1 ]; then
        case "$i" in
          0) right="${GRY}┌─ ${CYN}WatTun Community${GRY} ──────┐${RST}" ;;
          1) right="${GRY}│${RST} ${CYN}GitHub:${RST}   JohnWatsoon   ${GRY}│${RST}" ;;
          2) right="${GRY}│${RST} ${CYN}Telegram:${RST} ${BOLD}@Watdevs${RST}      ${GRY}│${RST}" ;;
        esac
      fi
      printf ' %s%s%s %s\n' "$GFG" "$left" "$RST" "$right"
      [ "${1:-0}" = 1 ] && sleep 0.03
    done
    printf ' %*s %s\n' 49 '' "${GRY}└─────────────────────────┘${RST}"
  else
    for i in 0 1 2; do
      gfg "$i"
      printf '  %s%s%s\n' "$GFG" "${WATTUN_BANNER[$i]}" "$RST"
      [ "${1:-0}" = 1 ] && sleep 0.03
    done
    printf '  %sGitHub:%s %s  •  %sTelegram:%s %s\n' "$CYN" "$RST" "$META_GITHUB" "$CYN" "$RST" "$META_TELEGRAM"
  fi
  return 0
}

VER=''
LOGO=''
make_logo() {
  local w=WatTun i
  LOGO=''
  for ((i=0; i<${#w}; i++)); do gfg $((i*8/${#w})); LOGO+="$GFG${w:i:1}"; done
  LOGO+=$RST
}
make_logo

EL=''; [ "$IS_TTY" = 1 ] && EL=$'\e[K'
clear_screen() { [ "$IS_TTY" = 1 ] && printf '\e[H\e[2J'; return 0; }

render_header() { # title [subtitle] [animated=0]
  if [ "$NONINTERACTIVE" = 1 ]; then printf '== %s%s ==\n' "$1" "${2:+ ($2)}"; return 0; fi
  clear_screen; echo
  banner "${3:-0}"
  echo
  printf '  %s◆%s %s%s%s %s›%s %s%s%s%s\n' "$CYN" "$RST" "$LOGO" "${VER:+ $GRY$VER$RST}" "" "$GRY" "$RST" "$BOLD" "$1" "$RST" "${2:+   ${GRY}$2${RST}}"
  hr; echo
}

render_subpage_header() { # title [subtitle]
  if [ "$NONINTERACTIVE" = 1 ]; then printf '== %s%s ==\n' "$1" "${2:+ ($2)}"; return 0; fi
  clear_screen; echo
  local cols w ctx pad
  cols=$(tput cols 2>/dev/null || echo 80)
  w=$((cols - 4))
  [ "$w" -gt 74 ] && w=74
  [ "$w" -lt 56 ] && w=56
  
  local ver_tag="WatTun"
  [ -n "$VER" ] && ver_tag="WatTun v$VER"
  local top_left="╭─ ${CYN}${BOLD}${ver_tag}${RST} "
  local top_mid="${GRY}── @Watdevs ── "
  local top_right="github.com/JohnWatsoon ─╮${RST}"
  
  local raw_left="╭─ ${ver_tag} "
  local raw_mid="── @Watdevs ── "
  local raw_right="github.com/JohnWatsoon ─╮"
  local fill_len=$((w - ${#raw_left} - ${#raw_mid} - ${#raw_right}))
  [ "$fill_len" -lt 1 ] && fill_len=1
  
  ctx="Context: $1${2:+ ($2)}"
  vlen "$ctx"
  pad=$((w - 2 - VLEN))
  [ "$pad" -lt 0 ] && pad=0

  printf '  %s%s%s%s\n' "$top_left" "${GRY}$(rep ─ $fill_len)${RST}" "$top_mid" "$top_right"
  printf '  %s│%s %s%s%s%*s %s│%s\n' "$GRY" "$RST" "$BOLD" "$ctx" "$RST" "$pad" '' "$GRY" "$RST"
  printf '  %s╰%s╯%s\n\n' "$GRY" "$(rep ─ "$w")" "$RST"
}

page_full() { # title [subtitle]
  local anim=0
  if [ "$ANIM" = 1 ] && [ "$INTRO_DONE" = 0 ]; then anim=1; fi
  INTRO_DONE=1
  render_header "$1" "${2:-}" "$anim"
}

page() { # title [subtitle]
  render_subpage_header "$1" "${2:-}"
}

# ---- boxes ----
BOXW=74
box_top() { printf '  %s╭─ %s%s%s%s %s╮%s\n' "$GRY" "$RST" "$BOLD$1" "$RST" "$GRY" "$(rep ─ $((BOXW-${#1}-3)))" "$RST"; }
box_mid() { printf '  %s├%s┤%s\n' "$GRY" "$(rep ─ "$BOXW")" "$RST"; }
box_row() { vlen "$1"; local pad=$((BOXW-2-VLEN)); [ "$pad" -lt 0 ] && pad=0; printf '  %s│%s %s%*s %s│%s\n' "$GRY" "$RST" "$1" "$pad" '' "$GRY" "$RST"; }
row_2col() {
  local left=$1 right=$2 w_left=36 pad
  vlen "$left"
  pad=$((w_left - VLEN))
  [ "$pad" -lt 0 ] && pad=0
  box_row "${left}$(rep ' ' "$pad")  ${right}"
}
box_bot() { printf '  %s╰%s╯%s\n' "$GRY" "$(rep ─ "$BOXW")" "$RST"; }

# ---- spinner / progress ----
SPIN_FR=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
spin_start() { # label : animate a spinner on the current line until spin_stop (foreground work continues)
  [ "$ANIM" = 1 ] || return 0
  cur_hide
  (
    local i=0 t0=$SECONDS
    while :; do
      printf '\r\e[K  %s%s%s %s %s(%ds)%s' "$CYN" "${SPIN_FR[$i]}" "$RST" "$1" "$GRY" $((SECONDS-t0)) "$RST"
      i=$(( (i+1) % 10 )); sleep 0.1
    done
  ) &
  SPIN_PID=$!
}
spin_stop() { kill_spin; [ "$ANIM" = 1 ] && { printf '\r\e[K'; cur_show; }; return 0; }
step() { # label cmd... : run silently under a spinner, print a done/failed line
  local label=$1 rc; shift
  [ -n "$LOGF" ] || LOGF=$(mktemp /tmp/wattun-manager.XXXXXX)
  : >"$LOGF"
  spin_start "$label"
  "$@" >>"$LOGF" 2>&1; rc=$?
  spin_stop
  if [ "$rc" -eq 0 ]; then ok "$label"; else err "$label"; tail -n 3 "$LOGF" 2>/dev/null | sed "s/^/      $GRY/; s/\$/$RST/"; fi
  return "$rc"
}
bar() { # cur max width -> [████░░░░]
  local c=$1 m=$2 w=${3:-20} f
  [ "$m" -gt 0 ] || m=1; [ "$c" -gt "$m" ] && c=$m
  f=$(( c * w / m ))
  printf '%s%s%s' "$(rep █ "$f")" "$GRY" "$(rep ░ $((w-f)))$RST"
}

celebrate() { # text : short success flourish
  local t=$1 i col
  if [ "$ANIM" != 1 ]; then ok "$t"; return 0; fi
  cur_hide
  for i in 0 1 2 3 4 5 6 7; do
    gfg "$i"; col=$GFG
    if [ $((i%2)) -eq 0 ]; then printf '\r\e[K  %s✦ ˚ %s ˚ ✧%s' "$col" "$t" "$RST"; else printf '\r\e[K  %s✧ · %s · ✦%s' "$col" "$t" "$RST"; fi
    sleep 0.06
  done
  printf '\r\e[K'; cur_show; ok "$t"
}

# ---- input ----
# shellcheck disable=SC2120
key_read() { # [timeout] -> KEY ; rc 0 key, 2 timeout ; EOF exits
  local rc k2 c i; KEY=''
  [ "$NONINTERACTIVE" = 1 ] && { KEY=enter; return 0; }
  while :; do
    if [ -n "${1:-}" ]; then IFS= read -rsn1 -t "$1" KEY; rc=$?; else IFS= read -rsn1 KEY; rc=$?; fi
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -gt 128 ] && { KEY=''; return 2; }
      eof_exit
    fi
    if [ "$KEY" = $'\e' ]; then
      # ESC followed by more bytes is an escape sequence (arrows, Home, F-keys): swallow it and read again.
      # A lone ESC stays "esc".
      if IFS= read -rsn1 -t 0.05 k2; then
        if [ "$k2" = '[' ] || [ "$k2" = O ]; then
          for ((i=0; i<8; i++)); do
            IFS= read -rsn1 -t 0.05 c || break
            case "$c" in [A-Za-z~@]) break ;; esac
          done
        fi
        KEY=''; continue
      fi
      KEY=esc
    fi
    break
  done
  [ -z "$KEY" ] && KEY=enter
  return 0
}
ask() { # prompt [default] -> REPLY_V (free text). Enter keeps the default.
  local d=${2:-} v
  if [ "$NONINTERACTIVE" = 1 ]; then REPLY_V=$d; return 0; fi
  printf '  %s?%s %s%s %s›%s ' "$CYN" "$RST" "$1" "${d:+ ${GRY}[$d]${RST}}" "$GRY" "$RST"
  IFS= read -r v || eof_exit
  v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
  REPLY_V=${v:-$d}
}
ask_ok() { # prompt default validator : up to 3 tries, validator prints its own error
  local t
  if [ "$NONINTERACTIVE" = 1 ]; then # the preset/default is the only answer: validate once and say what is wrong
    ask "$1" "$2"; "$3" "$REPLY_V" && return 0
    err "'$1': '$REPLY_V' is not accepted (set it with the matching command-line flag)"; return 1
  fi
  for t in 1 2 3; do
    ask "$1" "$2"
    if "$3" "$REPLY_V"; then return 0; fi
  done
  err "Too many invalid answers, going back."; return 1
}
confirm() { # prompt [y|n default]
  local def=${2:-y} t lab='Y/n'
  [ "$def" = y ] || def=n # anything but y is "no"
  [ "$def" = n ] && lab='y/N'
  if [ "$NONINTERACTIVE" = 1 ]; then
    echo "  ? $1 -> $([ "$def" = y ] && echo yes || echo no)" # the answer actually used
    [ "$def" = y ]; return
  fi
  for t in 1 2 3; do
    printf '  %s?%s %s %s[%s]%s ' "$CYN" "$RST" "$1" "$GRY" "$lab" "$RST"
    key_read
    case "$KEY" in
      y|Y) echo yes; return 0 ;;
      n|N) echo no; return 1 ;;
      enter) echo; [ "$def" = y ]; return ;;
      esc) echo; return 1 ;;
    esac
    echo
  done
  return 1
}
pause() { printf '\n  %sPress any key to go back...%s' "$GRY" "$RST"; key_read; echo; }
PMSG=''
flash() { PMSG=$*; } # shown after the next prompt caret

run_flow() { # fn args... : run in a subshell; Ctrl+C cancels just this flow
  local rc
  IN_FLOW=1
  ( trap 'kill_spin; cur_show; exit 130' INT; trap 'kill_spin; cur_show; at_cleanup' EXIT; "$@" )
  rc=$?
  IN_FLOW=0
  [ "$rc" -eq 130 ] && { echo; warn "Cancelled."; [ "$IS_TTY" = 1 ] && sleep 0.8; }
  return "$rc"
}

# ======================================================================================
#  Pure helpers: config, tokens, port specs
# ======================================================================================
tunnels() { local f b; for f in "$CONF"/*.yml; do [ -e "$f" ] || continue; b=${f##*/}; echo "${b%.yml}"; done; }
cfg()     { sed -n "s/^$2:[[:space:]]*//p" "$CONF/$1.yml" 2>/dev/null | head -1 | tr -d "\"'"; }
role()    { [ "$(cfg "$1" mode)" = server ] && echo Kharej || echo Iran; }
stats()   { local m; m=$(cfg "$1" metrics); [ -n "$m" ] && curl -fs --noproxy '*' --max-time 2 "http://$m/stats"; }
ms()      { printf "%.1f" "${1:-0}"; }
jget()    { grep -o "\"$2\": *[^,}]*" <<<"$1" | head -1 | sed 's/.*: *//; s/"//g'; }
human()   { awk -v b="${1:-0}" 'BEGIN{s="B KB MB GB TB";split(s,u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.1f %s",b,u[i]}'; }
ipv4_ok() { # is $1 a dotted IPv4 with every octet 0-255 ?
  local a b c d
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}; d=${BASH_REMATCH[4]}
  [ "$((10#$a))" -le 255 ] && [ "$((10#$b))" -le 255 ] && [ "$((10#$c))" -le 255 ] && [ "$((10#$d))" -le 255 ]
}
ip_is_private() { # RFC1918, CGNAT 100.64/10, loopback, link-local
  local a b
  ipv4_ok "$1" || return 1
  a=${1%%.*}; b=${1#*.}; b=${b%%.*}; a=$((10#$a)); b=$((10#$b))
  case "$a" in 10|127) return 0 ;; esac
  [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
  [ "$a" = 192 ] && [ "$b" = 168 ] && return 0
  [ "$a" = 169 ] && [ "$b" = 254 ] && return 0
  [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
  return 1
}
public_ip() { # prints a valid IPv4 or nothing. A public address on an interface comes first (no third-party
  # lookup); NAT'd servers (the public IP is nowhere on the box) fall back to ipify/ifconfig.me, then to hostname -I
  local ip u
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\) .*/\1/p')
  if ipv4_ok "$ip" && ! ip_is_private "$ip"; then echo "$ip"; return 0; fi
  for u in https://api.ipify.org https://ifconfig.me; do
    ip=$(curl -fs4 --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
    ipv4_ok "$ip" && { echo "$ip"; return 0; }
  done
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ipv4_ok "$ip" && echo "$ip"
  return 0
}
new_key() { head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40; }
uptime_of() { local t; t=$(systemctl show "${WAT_PREFIX}@$1" -p ActiveEnterTimestamp --value 2>/dev/null); [ -n "$t" ] && echo "since $t" || echo "-"; }

free_metrics_port() { # first free port from WAT_METRICS_BASE (default 19750, sandbox 19850); never 19700-19709 or 18990-18999
  local p=${WAT_METRICS_BASE:-}
  [[ "$p" =~ ^[0-9]{4,5}$ ]] || { p=19750; [ "$SANDBOX" = 1 ] && p=19850; }
  while [ "$p" -lt 20400 ]; do
    if { [ "$p" -ge 19700 ] && [ "$p" -le 19709 ]; } || { [ "$p" -ge 18990 ] && [ "$p" -le 18999 ]; }; then p=$((p+1)); continue; fi
    port_busy "$p" tcp || grep -qhE "^metrics:.*:$p\"?[[:space:]]*\$" "$CONF"/*.yml 2>/dev/null || break
    p=$((p+1))
  done
  echo "$p"
}
valid_name() { [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] && [ ! -e "$CONF/$1.yml" ]; }
suggest_name() { # kharej|iran -> kharej, kharej-2, kharej-3 ...
  local base=$1 n=1 c=$1
  while [ -e "$CONF/$c.yml" ] && [ "$n" -lt 99 ]; do n=$((n+1)); c="$base-$n"; done
  echo "$c"
}

# ---- port busy / ownership ----
port_busy() { # port [tcp|udp|any] : is something listening on it on this server?
  local pr=${2:-any} f fl=-Hltnu hex files=()
  if command -v ss >/dev/null 2>&1; then
    case "$pr" in tcp) fl=-Hltn ;; udp) fl=-Hlun ;; esac
    ss "$fl" "( sport = :$1 )" 2>/dev/null | grep -q .; return
  fi
  printf -v hex '%04X' "$1"   # no ss on this system: read /proc/net directly
  case "$pr" in tcp) files=(tcp tcp6) ;; udp) files=(udp udp6) ;; *) files=(tcp tcp6 udp udp6) ;; esac
  for f in "${files[@]}"; do
    awk -v h=":$hex" -v u="${f:0:3}" 'NR>1 && substr($2, length($2)-4) == h && (u=="udp" || $4=="0A") {found=1} END{exit !found}' "/proc/net/$f" 2>/dev/null && return 0
  done
  return 1
}
port_user() { # port proto -> process name and PID or empty
  local f=-Hltnp; [ "${2:-tcp}" = udp ] && f=-Hlunp
  local line u pid
  line=$(ss "$f" "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*",pid=[0-9]*' | head -1)
  if [ -n "$line" ]; then
    u=$(echo "$line" | cut -d'"' -f2)
    pid=$(echo "$line" | grep -o 'pid=[0-9]*' | cut -d= -f2)
    if [ -n "$pid" ] && [ -n "$u" ]; then echo "$u (PID $pid)"; return; fi
    [ -n "$u" ] && { echo "$u"; return; }
  fi
  ss "$f" "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2
}

# ---- port specs. Canonical form: LISTEN:TARGET/proto (proto = tcp|udp) ----
NS_OUT=(); NS_ERR=''
norm_spec() { # "8443->443/udp" "443" "53/both" -> NS_OUT=(canonical...) ; rc 1 + NS_ERR on bad input
  NS_OUT=(); NS_ERR=''
  local s=$1 body proto=tcp L T
  s=${s//->/:}; s=${s//→/:}; s=${s//=>/:}; s=${s//=/:}; s=${s//[[:space:]]/}
  [ -n "$s" ] || { NS_ERR='empty entry'; return 1; }
  body=$s
  if [[ $s == */* ]]; then body=${s%%/*}; proto=${s#*/}; fi
  proto=${proto,,}
  case $proto in
    tcp|udp|both) ;;
    tcp+udp|udp+tcp|tcpudp|udptcp) proto=both ;;
    *) NS_ERR="unknown protocol '$proto' (use tcp, udp or both)"; return 1 ;;
  esac
  if [[ $body == *:*:* ]]; then NS_ERR="'$1' has too many ':'"; return 1; fi
  if [[ $body == *:* ]]; then L=${body%%:*}; T=${body##*:}; else L=$body; T=$body; fi
  if ! [[ $L =~ ^[0-9]{1,5}$ && $T =~ ^[0-9]{1,5}$ ]]; then NS_ERR="'$1' is not a port"; return 1; fi
  L=$((10#$L)); T=$((10#$T))
  if [ "$L" -lt 1 ] || [ "$L" -gt 65535 ] || [ "$T" -lt 1 ] || [ "$T" -gt 65535 ]; then NS_ERR="'$1': ports must be 1-65535"; return 1; fi
  case $proto in both) NS_OUT=("$L:$T/tcp" "$L:$T/udp") ;; *) NS_OUT=("$L:$T/$proto") ;; esac
}
spec_L() { local x=${1%%/*}; echo "${x%%:*}"; }
spec_T() { local x=${1%%/*}; echo "${x##*:}"; }
spec_P() { echo "${1##*/}"; }
spec_yaml() { # canonical -> YAML list item text (L:T only when they differ)
  local L T P out
  L=$(spec_L "$1"); T=$(spec_T "$1"); P=$(spec_P "$1")
  if [ "$L" = "$T" ]; then out=$L; else out="$L:$T"; fi
  [ "$P" = udp ] && out="$out/udp"
  echo "$out"
}
spec_human() { # canonical -> "443" / "8443→443" / "53/udp"
  local L T P out
  L=$(spec_L "$1"); T=$(spec_T "$1"); P=$(spec_P "$1")
  if [ "$L" = "$T" ]; then out=$L; else out="$L→$T"; fi
  [ "$P" = udp ] && out="$out/udp"
  echo "$out"
}
maps_yaml_block() { # prints the ports: block for the array MAPS (nothing when empty)
  local i
  [ "${#MAPS[@]}" -gt 0 ] || return 0
  echo "ports:"
  for ((i=0; i<${#MAPS[@]}; i++)); do echo "  - $(spec_yaml "${MAPS[$i]}")"; done
}
maps_allow_str() { # MAPS -> "443,53/udp" (target ports only, as embedded in the token)
  local i out='' t p
  for ((i=0; i<${#MAPS[@]}; i++)); do
    t=$(spec_T "${MAPS[$i]}"); p=$(spec_P "${MAPS[$i]}")
    [ "$p" = udp ] && t="$t/udp"
    case ",$out," in *",$t,"*) continue ;; esac
    out="${out:+$out,}$t"
  done
  echo "$out"
}
allow_to_array() { # "443,53/udp" -> PE_ALLOW=(443:443/tcp 53:53/udp)
  local it; PE_ALLOW=()
  for it in ${1//,/ }; do norm_spec "$it" && PE_ALLOW+=("${NS_OUT[@]}"); done
  return 0
}
allowed_has() { # target proto : 0 if allowed or the allow list is unknown/empty
  local i
  [ "${#PE_ALLOW[@]}" -gt 0 ] || return 0
  for ((i=0; i<${#PE_ALLOW[@]}; i++)); do
    [ "$(spec_T "${PE_ALLOW[$i]}")" = "$1" ] && [ "$(spec_P "${PE_ALLOW[$i]}")" = "$2" ] && return 0
  done
  return 1
}
yml_ports_raw() { # name -> one raw ports: item per line
  sed -n '/^ports:/,/^[^ #\t-]/{/^[[:space:]]*-[[:space:]]/{s/^[[:space:]]*-[[:space:]]*//;s/[[:space:]]*#.*//;s/["'"'"']//g;p}}' "$CONF/$1.yml" 2>/dev/null
}
yml_maps() { # name -> canonical items, one per line
  local it
  while IFS= read -r it; do [ -n "$it" ] && norm_spec "$it" && printf '%s\n' "${NS_OUT[@]}"; done < <(yml_ports_raw "$1")
}
load_maps() { # name -> MAPS
  MAPS=()
  local it
  while IFS= read -r it; do [ -n "$it" ] && MAPS+=("$it"); done < <(yml_maps "$1")
}
cfg_ports() { # legacy one-line list: "443 8443→443 53/udp"
  local it out=''
  while IFS= read -r it; do [ -n "$it" ] && out="$out $(spec_human "$it")"; done < <(yml_maps "$1")
  echo "${out# }"
}
write_ports() { # name : replace the ports: block of NAME.yml with the array MAPS
  local f="$CONF/$1.yml" tmp
  tmp=$(mktemp "$CONF/.tmp.XXXXXX") || return 1
  awk '
    /^ports:/ {skip=1; next}
    skip && /^[[:space:]]+(-|#)/ {next}
    skip && /^[[:space:]]*$/ {next}
    {skip=0; print}' "$f" >"$tmp"
  maps_yaml_block >>"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$f"
}
set_value() { # name key value : set or add a top-level key
  local f="$CONF/$1.yml" tmp
  tmp=$(mktemp "$CONF/.tmp.XXXXXX") || return 1
  grep -v "^$2:" "$f" | awk -v k="$2" -v v="$3" '/^(metrics|ports):/ && !d {print k ": " v; d=1} {print} END{if(!d) print k ": " v}' >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$f"
}
unset_value() { # same tmp+mv pattern as set_value: the 3 s hot-reloader must never see an interleaved rewrite
  local f="$CONF/$1.yml" tmp
  tmp=$(mktemp "$CONF/.tmp.XXXXXX") || return 1
  grep -v "^$2:" "$f" >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$f"
}
set_port_limit() { # name port rate quota
  local f="$CONF/$1.yml" lp=$2 lr=$3 lq=$4 tmp
  [ -f "$f" ] || return 1
  tmp=$(mktemp "$CONF/.tmp.XXXXXX") || return 1
  awk -v lp="$lp" -v lr="$lr" -v lq="$lq" '
    BEGIN { in_lim=0; wrote=0 }
    /^limits:/ { in_lim=1; print; next }
    in_lim && /^[a-zA-Z0-9_-]+:/ {
      if (!wrote && ((lr != "" && lr != "0") || (lq != "" && lq != "0"))) {
        s = "  - " lp
        if (lr != "" && lr != "0") s = s " rate=" lr
        if (lq != "" && lq != "0") s = s " quota=" lq
        print s
        wrote = 1
      }
      in_lim = 0
      print
      next
    }
    in_lim && $1 == "-" && $2 ~ ("^" lp "([[:space:]]|$)") {
      if (!wrote && ((lr != "" && lr != "0") || (lq != "" && lq != "0"))) {
        s = "  - " lp
        if (lr != "" && lr != "0") s = s " rate=" lr
        if (lq != "" && lq != "0") s = s " quota=" lq
        print s
        wrote = 1
      }
      next
    }
    { print }
    END {
      if (!wrote && ((lr != "" && lr != "0") || (lq != "" && lq != "0"))) {
        if (!in_lim) print "limits:"
        s = "  - " lp
        if (lr != "" && lr != "0") s = s " rate=" lr
        if (lq != "" && lq != "0") s = s " quota=" lq
        print s
      }
    }
  ' "$f" >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$f"
}

# Connection token: wat1:BASE64("carrier|peer|key|path|sni|icmp-type|allowed-ports[|reverse]")
# Field 7 (allowed ports on Kharej, comma list, empty = any) was added in 1.9.0; 6-field tokens still parse.
# Field 8 ("1" = reverse ICMP, wattun >= 2.0.0) is written only when set, so every other token stays 7 fields.
# Field 9 (auto plan) is written only for carrier "auto" tokens; field 8 stays empty there. Format:
#   d=udp:4443,tcp:4443,...;r=tcp:24431,...   d = Kharej listen ports (direct), r = ports Iran listens on during the
#   reverse test. Only ; , : = are used, never '|'. 7/8-field tokens still parse.
make_token() {
  local f; f=$(printf '%s|%s|%s|%s|%s|%s|%s' "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}")
  if [ -n "${9:-}" ]; then f="$f|${8:-}|$9"; elif [ "${8:-}" = 1 ]; then f="$f|1"; fi
  printf 'wat1:%s' "$(printf '%s' "$f" | base64 -w0)"
}
T_CARRIER=''; T_PEER=''; T_KEY=''; T_PATH=''; T_SNI=''; T_ICMP=''; T_PORTS=''; T_REV=''; T_AUTO=''
read_token() { # token -> T_CARRIER T_PEER T_KEY T_PATH T_SNI T_ICMP T_PORTS T_REV T_AUTO
  local raw
  T_CARRIER=''; T_PEER=''; T_KEY=''; T_PATH=''; T_SNI=''; T_ICMP=''; T_PORTS=''; T_REV=''; T_AUTO=''
  [[ "$1" == wat1:* ]] || return 1
  raw=$(printf '%s' "${1#wat1:}" | base64 -d 2>/dev/null) || return 1
  IFS='|' read -r T_CARRIER T_PEER T_KEY T_PATH T_SNI T_ICMP T_PORTS T_REV T_AUTO <<<"$raw"
  [ -n "$T_CARRIER" ] && [ -n "$T_PEER" ] && [ -n "$T_KEY" ]
}
is_reverse() { [ "$(cfg "$1" reverse)" = true ]; }

# Reverse ICMP on Iran: Linux answers every tunnel request with its own full-size copy, which doubles Iran's upload.
# Rate-limiting the kernel's echo and timestamp replies (icmp_ratemask bits 0 and 14, 10 per second per sender) drops
# those copies and keeps ordinary pings answered. The tunnel's replies are raw-socket sends and are not limited.
# Measured on the real path: without it OutEchoReps = 2 x InEchos. The old values are kept and restored when the
# last reverse Iran tunnel is gone.
KREPLY_CONF=/etc/sysctl.d/90-$WAT_PREFIX-reverse.conf
kreply_on() { [ -f "$KREPLY_CONF" ]; }
kreply_apply() {
  local mask lim
  mask=$(sysctl -n net.ipv4.icmp_ratemask 2>/dev/null) && lim=$(sysctl -n net.ipv4.icmp_ratelimit 2>/dev/null) || return 1
  [ -f "$CONF/.kreply.orig" ] || printf 'net.ipv4.icmp_ratemask = %s\nnet.ipv4.icmp_ratelimit = %s\n' "$mask" "$lim" >"$CONF/.kreply.orig"
  {
    echo "# wattun-manager: reverse ICMP on this Iran server. The kernel's ping replies are rate-limited so it stops"
    echo "# sending a copy of every tunnel packet. Removed when no reverse Iran tunnel is left."
    echo "net.ipv4.icmp_ratemask = $((mask | 1 | 16384))"
    echo "net.ipv4.icmp_ratelimit = 100"
  } >"$KREPLY_CONF"
  sysctl -q -p "$KREPLY_CONF" >/dev/null
}
kreply_restore() {
  [ -f "$KREPLY_CONF" ] || return 0
  rm -f "$KREPLY_CONF"
  [ -f "$CONF/.kreply.orig" ] && sysctl -q -p "$CONF/.kreply.orig" >/dev/null && rm -f "$CONF/.kreply.orig"
  ok "Restored the kernel's normal ping replies (no reverse Iran tunnel left)."
}
reverse_iran_left() {
  local n
  for n in $(tunnels); do [ "$(role "$n")" = Iran ] && [ "$(cfg "$n" carrier)" = icmp ] && is_reverse "$n" && return 0; done
  return 1
}
kreply_needed() { ! kreply_on && [ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" != 1 ]; }
kreply_offer() {
  kreply_needed || return 0
  hint "Reverse mode: Linux here also answers every tunnel packet with a full-size copy, doubling this server's upload."
  [ "$SANDBOX" = 1 ] && warn "Sandbox: this changes GLOBAL kernel settings (net.ipv4.icmp_ratemask |= 16385, icmp_ratelimit = 100) via $KREPLY_CONF; original values saved in $CONF/.kreply.orig."
  step "Limiting the kernel's ping replies (normal pings keep working)" kreply_apply \
    && hint "Undo: remove $KREPLY_CONF and run: sysctl --system (it is also undone when the last reverse Iran tunnel is deleted)."
  return 0
}
refresh_token() { # name : keep NAME.token in step with the allowed ports in NAME.yml
  local f="$CONF/$1.token" allow
  [ -f "$f" ] && read_token "$(cat "$f")" || return 0
  load_maps "$1"; allow=$(maps_allow_str)
  [ -f "$CONF/$1-r.yml" ] && is_auto_kharej "$1" && write_ports "$1-r" # the auto reverse companion allows the same ports
  [ "$allow" = "$T_PORTS" ] && return 0
  make_token "$T_CARRIER" "$T_PEER" "$T_KEY" "$T_PATH" "$T_SNI" "$T_ICMP" "$allow" "$T_REV" "$T_AUTO" >"$f"
}

# ---- cross-tunnel conflict checks ----
tunnel_using_public() { # port proto [exclude] -> name of another Iran tunnel publishing it
  local n it
  for n in $(tunnels); do
    [ "$n" = "${3:-}" ] && continue
    [ "$(role "$n")" = Iran ] || continue
    while IFS= read -r it; do
      [ -n "$it" ] && [ "$(spec_L "$it")" = "$1" ] && [ "$(spec_P "$it")" = "$2" ] && { echo "$n"; return 0; }
    done < <(yml_maps "$n")
  done
  return 1
}
tunnel_using_listen() { # port [exclude] -> name of a tunnel (Kharej, or Iran in reverse) listening on it
  local n
  for n in $(tunnels); do
    [ "$n" = "${2:-}" ] && continue
    [[ "$(cfg "$n" listen)" == *:"$1" ]] && { echo "$n"; return 0; }
  done
  return 1
}
listen_blocked() { # proto port
  port_busy "$2" "$1" || tunnel_using_listen "$2" >/dev/null
}
listen_conflict_desc() { # proto port -> explanation string
  local proto=${1:-tcp} port=$2
  local tun u
  tun=$(tunnel_using_listen "$port")
  if [ -n "$tun" ]; then echo "tunnel '$tun'"; return; fi
  u=$(port_user "$port" "$proto")
  if [ -n "$u" ]; then echo "$u"; return; fi
  echo "another process or tunnel"
}
default_listen() { # carrier -> a free listen port
  local base proto=tcp c
  case "$1" in ws|h2c) base=8080 ;; wss|tls|grpc|h2) base=443 ;; *) base=4443 ;; esac
  [ "$1" = udp ] && proto=udp
  for c in "$base" 8443 2053 2083 2087 2096 $((base+1)) $((base+2)) $((base+3)); do
    listen_blocked "$proto" "$c" || { echo "$c"; return; }
  done
  echo "$base"
}

# ---- validators (print their own error, rc 1 when bad) ----
v_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ] && return 0; err "Enter a port between 1 and 65535."; return 1; }
v_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { err "Use 1-32 letters, digits, - or _."; return 1; }
  [ ! -e "$CONF/$1.yml" ] || { err "A tunnel named '$1' already exists."; return 1; }
}
v_host() { [[ "$1" =~ ^[A-Za-z0-9._:-]{1,253}$ ]] && return 0; err "Enter an IP address or a domain name."; return 1; }
v_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0; err "Enter the server's IPv4 address, such as 198.51.100.20."; return 1; }
is_pool() { case "$1" in tcp|tls|ws|wss|h2|h2c|grpc) return 0 ;; esac; return 1; }
rev_capable() { [ "$1" = icmp ] || is_pool "$1"; }
reverse_hint() { # [carrier]
  if is_pool "${1:-}"; then
    hint "Reverse: Kharej connects out to Iran and Iran listens. Use it when Iran cannot reach Kharej's port but Kharej"
    hint "can reach Iran. Both sides must use it."
  else
    hint "Reverse: Kharej sends the pings to Iran and Iran answers. Use it when Iran cannot ping Kharej but Kharej CAN"
    hint "ping Iran (a one-way block on Iran's IP). Both sides must use it, and both need wattun 2.0.0 or newer."
  fi
}
v_icmp() { case "$1" in echo|timestamp|info|mask) return 0 ;; esac; err "Use echo, timestamp, info or mask."; return 1; }
v_mbps_adv() { case "$1" in -|0|default) return 0 ;; esac; v_mbps "$1"; }
v_mbps() { [ -z "$1" ] && return 0; [[ "$1" =~ ^[0-9]{1,4}$ ]] && [ "$1" -ge 1 ] && return 0; err "Enter a number of MB/s (1-9999)."; return 1; }
v_sessions() { [ -z "$1" ] && return 0; case "$1" in -|0|default) return 0 ;; esac; [[ "$1" =~ ^[0-9]{1,3}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 64 ] && return 0; err "Enter sessions count 1-64 (or 0/default to unset)."; return 1; }
v_conns() { [ -z "$1" ] && return 0; case "$1" in -|0|default) return 0 ;; esac; [[ "$1" =~ ^[0-9]{1,3}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 128 ] && return 0; err "Enter conns count 1-128 (or 0/default to unset)."; return 1; }
v_mtu() { [ -z "$1" ] && return 0; case "$1" in -|0|default) return 0 ;; esac; [[ "$1" =~ ^[0-9]{3,5}$ ]] && [ "$1" -ge 576 ] && [ "$1" -le 65535 ] && return 0; err "Enter MTU 576-65535 (or 0/default to unset)."; return 1; }
v_num() { [[ "$1" =~ ^[0-9]+$ ]] && return 0; err "Enter a valid positive number."; return 1; }
v_bind() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0; err "Enter an IPv4 address such as 0.0.0.0 or 10.0.0.5."; return 1; }
v_fec() { case "$1" in off|auto) return 0 ;; esac; err "Use off or auto."; return 1; }
v_fake_mode() { case "$1" in seq|ttl|sum|seqsum|auto|rst) return 0 ;; esac; err "Use seq, ttl, sum, seqsum, auto or rst."; return 1; }
v_fake_ttl() { [ -z "$1" ] && return 0; [[ "$1" =~ ^[0-9]{1,3}$ ]] && [ "$1" -le 255 ] && return 0; err "Enter a hop count 1-255 (or leave empty for auto)."; return 1; }
v_pool_rotate() { [ -z "$1" ] && return 0; case "$1" in 0|off) return 0 ;; esac; [[ "$1" =~ ^[0-9]+(ms|s|m|h)$ ]] && return 0; err "Enter a lifetime such as 90s, 30m or 4h (or 0 to turn it off)."; return 1; }
v_pool_bytes() { local s=${1,,}; [ -z "$s" ] && return 0; case "$s" in 0|0b|off) return 0 ;; esac; [[ "$s" =~ ^[0-9]+(\.[0-9]+)?(k|m|g|t)b?$ ]] && return 0; err "Enter a byte count such as 500MB, 4G or 300k (or 0 to turn it off)."; return 1; }
v_sni_name() {
  local part parts
  local IFS=','
  read -ra parts <<< "$1"
  [ "${#parts[@]}" -gt 0 ] || { err "Enter a server name such as mci.ir."; return 1; }
  for part in "${parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { err "Enter a server name such as mci.ir."; return 1; }
  done
  return 0
}
v_ech() {
  [ -z "$1" ] && return 0
  local v=${1,,}
  case "$v" in off|auto|ladder) return 0 ;; esac
  if [[ "$1" =~ ^[A-Za-z0-9+/=_-]{16,}$ ]]; then return 0; fi
  err "--ech: use off, auto, ladder or a base64 ECHConfigList (got '$1')."
  return 1
}
v_governor() {
  [ -z "$1" ] && return 0
  local v=${1,,}
  case "$v" in on|off|true|false|1|0) return 0 ;; esac
  err "--governor: use on, off, true or false (got '$1')."
  return 1
}
v_preset() {
  [ -z "$1" ] && return 0
  local v=${1,,}
  case "$v" in
    mci|irancell|mokhaberat|tci|blackout|emergency|strict|conservative|low-churn|off|clear|none) return 0 ;;
    "iran whitelist - mci"|"iran whitelist - irancell/mokhaberat"|"emergency blackout mode"|"conservative / low-churn"|"conservative/low-churn") return 0 ;;
  esac
  err "Unknown preset '$1'. Available: mci, irancell, blackout, conservative"
  return 1
}
v_dns_listen() {
  local a=${1,,}
  [ -z "$a" ] && return 0
  case "$a" in 0|off) return 0 ;; esac
  if [[ "$1" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}):([0-9]{1,5})$ ]]; then
    local ip="${BASH_REMATCH[1]}"
    local port="${BASH_REMATCH[2]}"
    ipv4_ok "$ip" || { err "DNS listen IP is invalid."; return 1; }
    v_port "$port" || return 1
    return 0
  fi
  err "--dns-listen: enter an address like 127.0.0.1:53 or 127.0.0.1:5353 (or off)."
  return 1
}
v_src_ip() {
  local ip=${1,,}
  [ -z "$ip" ] && return 0
  case "$ip" in 0|off) return 0 ;; esac
  ipv4_ok "$1" || { err "--src-ip: enter a valid IPv4 address (or off)."; return 1; }
  return 0
}
v_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]*$ ]] && return 0; err "The path must start with / (example: /wat)."; return 1; }
v_token() {
  if read_token "$1"; then return 0; fi
  err "That is not a valid token. It starts with wat1: and is one long line."; return 1
}
v_key() { [ "${#1}" -ge 8 ] && [[ "$1" =~ ^[^[:space:]]+$ ]] && return 0; err "The key is at least 8 characters, no spaces."; return 1; }
v_domain_opt() {
  [ -z "$1" ] && return 0
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] && [[ "$1" == *.* ]] && return 0
  err "Enter a domain name such as vpn.example.com (or press Enter to skip)."; return 1
}
v_nonempty() { [ -n "$1" ] && return 0; err "This value is required."; return 1; }

# ======================================================================================
#  Diagrams
# ======================================================================================
step_diagram() { # [1|2 highlight]
  local hl=${1:-0} c1=$BOLD c2=$BOLD e=$RST
  [ "$hl" = 2 ] && c1=$GRY; [ "$hl" = 1 ] && c2=$GRY
  [ "$hl" = 1 ] && c1=$BOLD$CYN; [ "$hl" = 2 ] && c2=$BOLD$CYN
  local top bot; top=$(rep ─ 27); bot=$top
  printf '  %s┌%s┐%s          %s┌%s┐%s\n' "$c1" "$top" "$e" "$c2" "$top" "$e"
  printf '  %s│ %-25s │%s %s─token─►%s %s│ %-25s │%s\n' "$c1" "STEP 1  Kharej (outside)" "$e" "$GRY" "$e" "$c2" "STEP 2  Iran (inside)" "$e"
  printf '  %s│ %-25s │%s          %s│ %-25s │%s\n' "$c1" "do this one FIRST" "$e" "$c2" "paste the token here" "$e"
  printf '  %s└%s┘%s          %s└%s┘%s\n' "$c1" "$bot" "$e" "$c2" "$bot" "$e"
}
conn_diagram() { # carrier canonical... : users ──► Iran :8443 ══ icmp ══► Kharej ──► 127.0.0.1:443
  local cr=$1 it n=0 L T P sfx; shift
  for it in "$@"; do
    n=$((n+1)); [ "$n" -gt 4 ] && continue
    L=$(spec_L "$it"); T=$(spec_T "$it"); P=$(spec_P "$it"); sfx=''; [ "$P" = udp ] && sfx=/udp
    printf '  users %s──►%s Iran :%s%s %s══ %s ══►%s Kharej %s──►%s 127.0.0.1:%s%s\n' "$GRY" "$RST" "$L" "$sfx" "$CYN" "$cr" "$RST" "$GRY" "$RST" "$T" "$sfx"
  done
  [ "$n" -gt 4 ] && hint "  ... and $((n-4)) more"
  return 0
}

# ======================================================================================
#  Tunnel info & telemetry
# ======================================================================================
TI_STATE=stopped; TI_RTT=0; TI_STREAMS=0; TI_SESS=0; TI_IN=0; TI_OUT=0; TI_RATE=0; TI_RAW=''
TI_CAR_COUNT=0; TI_CAR_ALIVE=0; TI_CAR_MUTED=0
CAR_COUNT=0; CAR_NAME=(); CAR_ALIVE=(); CAR_RTT=(); CAR_LOSS=(); CAR_SHARE=(); CAR_MUTED=()
parse_carriers() { # json
  local json=$1 carr_block item
  CAR_COUNT=0; CAR_NAME=(); CAR_ALIVE=(); CAR_RTT=(); CAR_LOSS=(); CAR_SHARE=(); CAR_MUTED=()
  carr_block=$(grep -o '"carriers": *\[[^]]*\]' <<<"$json" | head -1)
  [ -n "$carr_block" ] || return 0
  while read -r item; do
    [ -n "$item" ] || continue
    local nm al rtt ls sh mu
    nm=$(grep -o '"name": *"[^"]*"' <<<"$item" | head -1 | cut -d'"' -f4)
    al=$(grep -o '"alive": *[^,}]*' <<<"$item" | head -1 | sed 's/.*: *//; s/"//g')
    rtt=$(grep -o '"srtt_ms": *[^,}]*' <<<"$item" | head -1 | sed 's/.*: *//; s/"//g')
    ls=$(grep -o '"loss": *[^,}]*' <<<"$item" | head -1 | sed 's/.*: *//; s/"//g')
    sh=$(grep -o '"share": *[^,}]*' <<<"$item" | head -1 | sed 's/.*: *//; s/"//g')
    mu=$(grep -o '"muted": *[^,}]*' <<<"$item" | head -1 | sed 's/.*: *//; s/"//g')
    CAR_NAME+=("${nm:-unknown}")
    CAR_ALIVE+=("${al:-false}")
    CAR_RTT+=("${rtt:-0}")
    CAR_LOSS+=("${ls:-0}")
    CAR_SHARE+=("${sh:-0}")
    CAR_MUTED+=("${mu:-false}")
    CAR_COUNT=$((CAR_COUNT+1))
  done < <(grep -o '{[^{}]*}' <<<"$carr_block")
}
tinfo() { # name -> TI_*  (state: up | degraded | down | stopped)
  TI_STATE=stopped; TI_RTT=0; TI_STREAMS=0; TI_SESS=0; TI_IN=0; TI_OUT=0; TI_RATE=0; TI_RAW=''
  TI_CAR_COUNT=0; TI_CAR_ALIVE=0; TI_CAR_MUTED=0
  systemctl is-active -q "${WAT_PREFIX}@$1" 2>/dev/null || return 0
  TI_RAW=$(stats "$1")
  if [ "$(jget "$TI_RAW" alive)" = true ]; then TI_STATE=up; else TI_STATE=down; fi
  TI_RTT=$(jget "$TI_RAW" srtt_ms); TI_STREAMS=$(jget "$TI_RAW" streams); TI_SESS=$(jget "$TI_RAW" sessions)
  TI_IN=$(jget "$TI_RAW" bytes_in_total); TI_OUT=$(jget "$TI_RAW" bytes_out_total); TI_RATE=$(jget "$TI_RAW" rate_bps)
  [ -n "$TI_IN" ] || { TI_IN=$(jget "$TI_RAW" bytes_in); TI_OUT=$(jget "$TI_RAW" bytes_out); } # before 2.4.19: since the last restart
  : "${TI_RTT:=0}" "${TI_STREAMS:=0}" "${TI_SESS:=0}" "${TI_IN:=0}" "${TI_OUT:=0}" "${TI_RATE:=0}"
  parse_carriers "$TI_RAW"
  TI_CAR_COUNT=$CAR_COUNT
  if [ "$TI_STATE" = up ] && [ "$CAR_COUNT" -gt 0 ]; then
    local i unmuted_live=0 unmuted_total=0
    for ((i=0; i<CAR_COUNT; i++)); do
      if [ "${CAR_MUTED[$i]}" = true ]; then
        TI_CAR_MUTED=$((TI_CAR_MUTED+1))
      else
        unmuted_total=$((unmuted_total+1))
        [ "${CAR_ALIVE[$i]}" = true ] && unmuted_live=$((unmuted_live+1))
      fi
    done
    TI_CAR_ALIVE=$unmuted_live
    if [ "$unmuted_total" -gt 1 ] && [ "$unmuted_live" -lt "$unmuted_total" ]; then
      TI_STATE=degraded
    fi
  fi
  if [ "$TI_STATE" = up ]; then
    local loss
    loss=$(jget "$TI_RAW" loss_pct)
    if [ -n "$loss" ] && [ "${loss%.*}" -ge 5 ] 2>/dev/null; then
      TI_STATE=degraded
    fi
  fi
}
SC_COL=''; SC_TXT=''; SC_DOT='●'
state_cell() { # role state
  case "$2" in
    up) SC_COL=$GRN; SC_DOT='●'; SC_TXT=UP ;;
    degraded) SC_COL=$YEL; SC_DOT='◐'; SC_TXT=DEGRADED ;;
    down) SC_COL=$RED; SC_DOT='○'; if [ "$1" = Kharej ]; then SC_TXT=WAITING; else SC_TXT=DOWN; fi ;;
    *) SC_COL=$GRY; SC_DOT='◌'; SC_TXT=STOPPED ;;
  esac
}
ports_summary() { # name [maxlen] -> "443 · 8443→443 · 53/udp"
  local n=$1 max=${2:-50} out='' piece it cnt=0 total=0
  while IFS= read -r it; do
    [ -n "$it" ] || continue
    total=$((total+1))
    piece=$(spec_human "$it")
    [ "$(role "$n")" = Kharej ] && { piece=$(spec_T "$it"); [ "$(spec_P "$it")" = udp ] && piece="$piece/udp"; }
    if [ $(( ${#out} + ${#piece} + 5 )) -gt "$max" ]; then continue; fi
    out="${out:+$out · }$piece"; cnt=$((cnt+1))
  done < <(yml_maps "$n")
  if [ "$total" -eq 0 ]; then [ "$(role "$n")" = Kharej ] && echo "any port" || echo "no ports yet"; return; fi
  [ "$cnt" -lt "$total" ] && out="$out +$((total-cnt))"
  echo "$out"
}

# ---- dashboard ----
DASH_N=()
dash_row() { # idx name
  local i=$1 n=$2 r cr load rtt tr pl par cols car_display
  cols=$(tput cols 2>/dev/null || echo 80)
  r=$(role "$n"); cr=$(carrier_label "$n"); par=$(companion_of "$n")
  tinfo "$n"; state_cell "$r" "$TI_STATE"
  load=''; rtt=''
  if [ "$TI_STATE" != stopped ]; then
    if [ "$r" = Kharej ]; then load="$TI_SESS clients"; else load="$TI_STREAMS streams"; fi
    { [ "$TI_STATE" = up ] || [ "$TI_STATE" = degraded ]; } && rtt="$(printf '%.0f' "$TI_RTT") ms"
  fi
  tr='-'; [ "$TI_STATE" != stopped ] && tr="↓$(human "$TI_IN") ↑$(human "$TI_OUT")"
  [ "$r" = Kharej ] && pl="allows $(ports_summary "$n" 40)" || pl="ports $(ports_summary "$n" 42)"
  [ -n "$par" ] && pl="auto: reverse side of $par"
  pl="$pl$(cs=$(cdn_summary "$n" short); [ -n "$cs" ] && printf '  %s[%s]' "$CYN" "$cs$RST")"

  if [ "$cols" -ge 100 ]; then
    car_display="${cr:0:16}"
  elif [ "$cols" -lt 70 ]; then
    if [[ "$cr" == *"+"* ]]; then
      local -a bcnt; IFS='+' read -ra bcnt <<<"$cr"; car_display="bond[${#bcnt[@]}]"
    elif is_auto_kharej "$n" || [ -f "$CONF/$n.auto" ]; then
      car_display="[AUTO]"
    else
      car_display="${cr:0:6}"
    fi
  else
    car_display="${cr:0:8}"
  fi

  printf ' %s%2s%s  %-13s %-6s %-10s %s%s%s %s%-9s%s %6s  %s\n' "$BOLD$CYN" "$i" "$RST" "${n:0:13}" "$r" "$car_display" \
    "$SC_COL" "$SC_DOT" "$RST" "$SC_COL" "$SC_TXT" "$RST" "$rtt" "$load"
  printf '     %s%s   %s%s\n' "$GRY" "$tr" "$pl" "$RST"
}
dash_table() {
  local n i=0; DASH_N=()
  for n in $(tunnels); do DASH_N+=("$n"); done
  if [ "${#DASH_N[@]}" -eq 0 ]; then
    printf '  %sWelcome! No tunnels yet. A tunnel needs two servers, set up in this order:%s\n\n' "$BOLD" "$RST"
    step_diagram
    printf '\n  %sStep 1%s  on Kharej: run %s%s%s, press %s[n]%s, choose Kharej.\n' "$BOLD" "$RST" "$CYN" "$SELF" "$RST" "$CYN" "$RST"
    printf '  %sStep 2%s  on Iran: press %s[n]%s, choose Iran, paste the token from step 1.\n\n' "$BOLD" "$RST" "$CYN" "$RST"
    printf '  Press %s[n]%s to create your first tunnel.\n' "$CYN$BOLD" "$RST"
    return 0
  fi
  printf ' %s%2s  %-13s %-6s %-10s   %-9s %6s  %s%s\n' "$GRY" '#' NAME ROLE CARRIER STATE RTT LOAD "$RST"
  printf ' %s%s%s\n' "$GRY" "$(rep ─ 74)" "$RST"
  for n in "${DASH_N[@]}"; do i=$((i+1)); dash_row "$i" "$n"; done
}
dash_actions() {
  local cnt=${#DASH_N[@]} range
  echo
  if [ "$cnt" -gt 0 ]; then
    [ "$cnt" -eq 1 ] && range=1 || range="1-$cnt"
    printf '  %s▸ Press %s%s%s%s to manage a tunnel%s %s(status, ports, token, logs, restart)%s\n' "$BOLD" "$CYN" "$range" "$RST" "$BOLD" "$RST" "$GRY" "$RST"
  fi
  hr
  printf '  %s new tunnel   %s batch actions   %s live monitor   %s update   %s settings   %s quit\n' \
    "$(key_label n)" "$(key_label a)" "$(key_label m)" "$(key_label u)" "$(key_label s)" "$(key_label q)"
}

# ======================================================================================
#  Firewall, service helpers
# ======================================================================================
fw_open() { # "443/tcp 53/udp" ...
  local list=$* fw='' p
  [ -n "$list" ] || return 0
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then fw=ufw
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then fw=firewalld; fi
  if [ -z "$fw" ]; then
    warn "No active ufw/firewalld found on this server."
    hint "If a cloud firewall is in front, open: $list"; return 0
  fi
  for p in $list; do
    if [ "$fw" = ufw ]; then ufw allow "$p" >/dev/null && ok "ufw: allowed $p"
    else firewall-cmd -q --permanent --add-port="$p" && ok "firewalld: allowed $p"; fi
  done
  [ "$fw" = firewalld ] && firewall-cmd -q --reload
  return 0
}
fw_kind() { # prints ufw, firewalld or nothing
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then echo ufw
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then echo firewalld; fi
}
fw_close() { # "443/tcp 53/udp" ... : mirror of fw_open, never asks
  local fw p; fw=$(fw_kind); [ -n "$fw" ] || return 0
  for p in $*; do
    if [ "$fw" = ufw ]; then ufw delete allow "$p" >/dev/null 2>&1 && ok "ufw: closed $p"
    else firewall-cmd -q --permanent --remove-port="$p" 2>/dev/null && ok "firewalld: closed $p"; fi
  done
  [ "$fw" = firewalld ] && firewall-cmd -q --reload
  return 0
}
unit_up() { # name : enable + start, wait up to 10 s for "active"
  local i
  ensure_template || return 1
  systemctl enable --now "${WAT_PREFIX}@$1" || return 1
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    systemctl is-active -q "${WAT_PREFIX}@$1" && { sleep 1; systemctl is-active -q "${WAT_PREFIX}@$1" && return 0; }
    sleep 0.5
  done
  return 1
}
start_unit() { # name : with feedback
  if step "Starting ${WAT_PREFIX}@$1" unit_up "$1"; then return 0; fi
  err "Tunnel '$1' failed to start. Last log lines:"; journalctl -u "${WAT_PREFIX}@$1" -n 15 --no-pager -o cat 2>/dev/null; return 1
}
link_alive() { [ "$(jget "$(stats "$1")" alive)" = true ]; }
wait_link() { # name seconds : spinner + progress bar while waiting for the link
  local n=$1 max=${2:-25} t0=$SECONDS el i=0 f
  [ "$ANIM" = 1 ] && cur_hide || printf '  Waiting for the link (up to %ss)...\n' "$max"
  while :; do
    if link_alive "$n"; then
      [ "$ANIM" = 1 ] && { printf '\r\e[K'; cur_show; }
      LINK_RTT=$(ms "$(jget "$(stats "$n")" srtt_ms)"); return 0
    fi
    el=$((SECONDS-t0))
    if [ "$el" -ge "$max" ] || ! systemctl is-active -q "${WAT_PREFIX}@$n" 2>/dev/null; then break; fi
    if [ "$ANIM" = 1 ]; then
      for f in 1 2 3 4; do
        printf '\r\e[K  %s%s%s Waiting for the link  [%s]  %ds / %ds' "$CYN" "${SPIN_FR[$((i%10))]}" "$RST" "$(bar "$el" "$max" 20)" "$el" "$max"
        i=$((i+1)); sleep 0.12
      done
    else sleep 1; fi
  done
  [ "$ANIM" = 1 ] && { printf '\r\e[K'; cur_show; }
  return 1
}

# ======================================================================================
#  Port mapping editor
#    uses: MAPS (canonical items), PE_ROLE (Iran|Kharej), PE_TUNNEL (name or ''),
#          PE_ALLOW (Kharej's allow list from the token, may be empty), PE_OWNED (ports this tunnel already owns)
# ======================================================================================
MAPS=(); PE_ROLE=Iran; PE_TUNNEL=''; PE_ALLOW=(); PE_OWNED=(); PE_MSG=''
pe_owned_has() { local o; for o in ${PE_OWNED[@]+"${PE_OWNED[@]}"}; do [ "$o" = "$1" ] && return 0; done; return 1; }
pe_msg() { PE_MSG+="$1"$'\n'; }
pe_try_add() { # canonical [replace-index] : validate and add/replace ; rc 1 + message when rejected
  local item=$1 idx=${2:--1} i L T P who u
  L=$(spec_L "$item"); T=$(spec_T "$item"); P=$(spec_P "$item")
  if [ "$PE_ROLE" = Kharej ] && [ "$L" != "$T" ]; then
    pe_msg "${RED}✘${RST} $(spec_human "$item"): on Kharej list only the port your service uses (like 443 or 53/udp)."; return 1
  fi
  for ((i=0; i<${#MAPS[@]}; i++)); do
    [ "$i" = "$idx" ] && continue
    if [ "$PE_ROLE" = Iran ]; then
      [ "$(spec_L "${MAPS[$i]}")" = "$L" ] && [ "$(spec_P "${MAPS[$i]}")" = "$P" ] && { pe_msg "${RED}✘${RST} Iran port $L/$P is already mapped (row $((i+1)))."; return 1; }
    else
      [ "$(spec_T "${MAPS[$i]}")" = "$T" ] && [ "$(spec_P "${MAPS[$i]}")" = "$P" ] && { pe_msg "${RED}✘${RST} Port $T/$P is already in the list (row $((i+1)))."; return 1; }
    fi
  done
  if [ "$PE_ROLE" = Iran ]; then
    if ! pe_owned_has "$L/$P" && port_busy "$L" "$P"; then
      u=$(port_user "$L" "$P"); pe_msg "${RED}✘${RST} Port $L/$P is already in use on this server${u:+ by $u}. Pick another Iran port."; return 1
    fi
    who=$(tunnel_using_public "$L" "$P" "$PE_TUNNEL") && { pe_msg "${RED}✘${RST} Port $L/$P is already published by tunnel '$who'."; return 1; }
    allowed_has "$T" "$P" || pe_msg "${YEL}!${RST} Kharej does not allow $T/$P. Add it to Kharej's ports or it will be refused."
  else
    if [ "$P" = tcp ] && ! timeout 1 bash -c "</dev/tcp/127.0.0.1/$T" 2>/dev/null; then
      pe_msg "${YEL}!${RST} Nothing answers on 127.0.0.1:$T yet. Fine if you start your service later."
    fi
  fi
  if [ "$idx" -ge 0 ]; then MAPS[idx]=$item; else MAPS+=("$item"); fi
  return 0
}
pe_draw() {
  local i it L T P mark warned=0 bad
  page "Port mappings" "${PE_TUNNEL:-new tunnel} · $PE_ROLE"
  if [ "$PE_ROLE" = Iran ]; then
    printf '  %s%3s  %-19s      %-23s %s%s\n' "$GRY" '#' 'Iran port (users)' 'Kharej port (service)' proto "$RST"
    printf '  %s%s%s\n' "$GRY" "$(rep ─ 70)" "$RST"
  else
    printf '  %s%3s  %-31s %s%s\n' "$GRY" '#' 'Port on this server (service)' proto "$RST"
    printf '  %s%s%s\n' "$GRY" "$(rep ─ 70)" "$RST"
  fi
  if [ "${#MAPS[@]}" -eq 0 ]; then
    printf '  %s  (empty)%s\n' "$GRY" "$RST"
    [ "$PE_ROLE" = Kharej ] && printf '  %s  An empty list means Iran may reach ANY port on this server.%s\n' "$GRY" "$RST"
  fi
  for ((i=0; i<${#MAPS[@]}; i++)); do
    it=${MAPS[$i]}; L=$(spec_L "$it"); T=$(spec_T "$it"); P=$(spec_P "$it"); mark=' '
    if [ "$PE_ROLE" = Iran ]; then
      allowed_has "$T" "$P" || { mark="${YEL}!${RST}"; warned=1; }
      printf '  %s%3s%s  %-19s ──►  %-23s %-5s %s\n' "$BOLD$CYN" $((i+1)) "$RST" "$L" "$T" "$P" "$mark"
    else
      printf '  %s%3s%s  %-31s %s\n' "$BOLD$CYN" $((i+1)) "$RST" "$T" "$P"
    fi
  done
  [ "$warned" = 1 ] && hint "  ! = this target is not in Kharej's allowed ports (from the token)"
  if [ "$PE_ROLE" = Iran ] && [ "${#PE_ALLOW[@]}" -gt 0 ]; then
    bad=''; for it in "${PE_ALLOW[@]}"; do bad="$bad $(spec_T "$it")/$(spec_P "$it")"; done
    hint "  Kharej allows:${bad//\/tcp/}"
  fi
  echo
  if [ -n "$PE_MSG" ]; then printf '%b' "${PE_MSG}" | sed 's/^/  /'; echo; PE_MSG=''; fi
  if [ "$PE_ROLE" = Iran ]; then
    hint "Type ports to add:  443, 8443:443, 53/udp, 5353->53/udp   (users:service)"
  else
    hint "Type ports to add:  443, 8443, 53/udp   (empty list = any port)"
  fi
  printf '  %s add  %s edit #  %s remove #  %s clear  %s done  %s cancel\n' "$(key_label a)" "$(key_label e)" "$(key_label r)" "$(key_label c)" "$(key_label Enter)" "$(key_label q)"
}
pe_bulk() {
  local line=$1 tok toks=() before=${#MAPS[@]} it
  read -ra toks <<<"${line//[,;]/ }"
  for tok in "${toks[@]}"; do
    if norm_spec "$tok"; then for it in "${NS_OUT[@]}"; do pe_try_add "$it"; done
    else pe_msg "${RED}✘${RST} $NS_ERR"; fi
  done
  [ "${#MAPS[@]}" -gt "$before" ] && pe_msg "${GRN}✔${RST} Added $((${#MAPS[@]}-before))."
  return 0
}
pe_guided_add() {
  local l t p it
  if [ "$PE_ROLE" = Iran ]; then
    echo; ask_ok "Iran port (users connect here)" "" v_port || { pe_msg "Cancelled."; return; }; l=$((10#$REPLY_V))
    ask_ok "Kharej port (where your service listens)" "$l" v_port || { pe_msg "Cancelled."; return; }; t=$((10#$REPLY_V))
  else
    echo; ask_ok "Port of your service on this server" "" v_port || { pe_msg "Cancelled."; return; }; t=$((10#$REPLY_V)); l=$t
  fi
  ask "Protocol: tcp, udp or both" tcp; p=${REPLY_V,,}
  if norm_spec "$l:$t/$p"; then for it in "${NS_OUT[@]}"; do pe_try_add "$it"; done; else pe_msg "${RED}✘${RST} $NS_ERR"; fi
}
pe_pick_index() { # arg -> PE_IDX (0-based) ; asks when missing
  local a=$1
  if [ -z "$a" ]; then ask "Row number" ""; a=$REPLY_V; fi
  if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#MAPS[@]}" ]; then PE_IDX=$((a-1)); return 0; fi
  pe_msg "${RED}✘${RST} No such row '$a'."; return 1
}
PE_IDX=0
pe_edit() {
  local l t p it cur
  pe_pick_index "$1" || return 0
  cur=${MAPS[$PE_IDX]}; p=$(spec_P "$cur")
  echo
  if [ "$PE_ROLE" = Iran ]; then
    ask_ok "Iran port" "$(spec_L "$cur")" v_port || return 0; l=$((10#$REPLY_V))
    ask_ok "Kharej port" "$(spec_T "$cur")" v_port || return 0; t=$((10#$REPLY_V))
  else
    ask_ok "Port" "$(spec_T "$cur")" v_port || return 0; t=$((10#$REPLY_V)); l=$t
  fi
  ask "Protocol: tcp or udp" "$p"; p=${REPLY_V,,}
  case $p in tcp|udp) ;; *) pe_msg "${RED}✘${RST} Protocol must be tcp or udp here (to get both, add a second row)."; return 0 ;; esac
  norm_spec "$l:$t/$p" && { pe_try_add "${NS_OUT[0]}" "$PE_IDX" && pe_msg "${GRN}✔${RST} Row $((PE_IDX+1)) updated."; }
  return 0
}
pe_remove() {
  local a=$1 x out=() i keep drop=()
  if [ -z "$a" ]; then ask "Row number(s) to remove (e.g. 2 or 1,3)" ""; a=$REPLY_V; fi
  [ -n "$a" ] || return 0
  for x in ${a//,/ }; do
    if [[ "$x" =~ ^[0-9]+$ ]] && [ "$x" -ge 1 ] && [ "$x" -le "${#MAPS[@]}" ]; then drop+=("$x"); else pe_msg "${RED}✘${RST} No such row '$x'."; fi
  done
  [ "${#drop[@]}" -gt 0 ] || return 0
  for ((i=0; i<${#MAPS[@]}; i++)); do
    keep=1; for x in "${drop[@]}"; do [ "$x" = $((i+1)) ] && keep=0; done
    [ "$keep" = 1 ] && out+=("${MAPS[$i]}")
  done
  MAPS=("${out[@]+"${out[@]}"}")
  pe_msg "${GRN}✔${RST} Removed."
}
port_editor() { # rc 0 = done (MAPS ready), 1 = cancelled
  local line cmd arg msg
  if [ "$NONINTERACTIVE" = 1 ]; then # --map replaces what the token pre-filled; otherwise keep the pre-filled rows
    if [ -n "$NI_MAP" ]; then MAPS=(); PE_MSG=''; pe_bulk "$NI_MAP"; fi
    msg=$PE_MSG; PE_MSG=''
    [ -n "$msg" ] && printf '%b' "$msg" | sed 's/^/  /'
    if [[ "$msg" == *✘* ]]; then err "Some ports were rejected (see above). Fix them with --map LISTEN:TARGET[,..]"; return 1; fi
    if [ "$PE_ROLE" = Iran ] && [ "${#MAPS[@]}" -eq 0 ]; then err "No ports to publish: give --map LISTEN:TARGET[,..] (example: --map 8443:443)"; return 1; fi
    return 0
  fi
  while :; do
    pe_draw
    printf '  %s▸%s ' "$CYN" "$RST"
    IFS= read -r line || eof_exit
    line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
    cmd=${line%% *}; arg=''; [[ "$line" == *" "* ]] && arg=${line#* }
    case "${cmd,,}" in
      ''|d|done|ok)
        if [ "$PE_ROLE" = Iran ] && [ "${#MAPS[@]}" -eq 0 ]; then pe_msg "${YEL}!${RST} Add at least one port first (example: 443)."; continue; fi
        if [ "$PE_ROLE" = Kharej ] && [ "${#MAPS[@]}" -eq 0 ]; then
          if ! confirm "The list is empty: Iran can reach ANY port on this server. Continue?" n; then continue; fi
        fi
        return 0 ;;
      q|quit|cancel|esc|b|back) return 1 ;;
      a|add) pe_guided_add ;;
      e|edit) pe_edit "$arg" ;;
      r|rm|remove|del|delete) pe_remove "$arg" ;;
      c|clear) MAPS=(); pe_msg "Cleared." ;;
      '?'|h|help) pe_msg "Examples: 443   8443:443   8443->443/udp   53/both   (several at once: 443, 8443:443, 53/udp)"; pe_msg "Iran port = what users connect to on this server. Kharej port = your service." ;;
      *) if [[ "$line" == *[0-9]* ]]; then pe_bulk "$line"; else pe_msg "${YEL}!${RST} Not understood: '$line'. Type ports like 443 or 8443:443, or ? for help."; fi ;;
    esac
  done
}

# ======================================================================================
#  Wizards
# ======================================================================================
CARRIER=''
pick_carrier() { # [auto] : with "auto" (Kharej wizard) the first choice is the auto carrier
  local t i n opts=() descs=()
  if [ "${1:-}" = auto ]; then
    opts+=(auto); descs+=("${BOLD}Auto (recommended)${RST}: this server accepts every type; the Iran server tests them all and
        keeps the best. Later, on the Iran server, you can switch to another type or join several (tunnel page, m).")
  fi
  opts+=(icmp udp tcp tls wss ws grpc h2)
  descs+=("icmp  ping packets; works when everything else is blocked (the usual case on filtered routes)"
    "udp   fastest and lowest latency, if UDP passes" "tcp   plain TCP, if TCP passes"
    "tls   TCP that looks like a normal HTTPS site" "wss   WebSocket over TLS; works behind Cloudflare or another CDN"
    "ws    WebSocket without TLS (CDN on port 80, or a proxy that adds TLS)" "grpc  gRPC, for CDNs that allow it" "h2    HTTP/2")
  n=${#opts[@]}
  if [ "$NONINTERACTIVE" = 1 ]; then
    CARRIER=${NI_CARRIER:-${opts[0]}}
    for t in "${opts[@]}"; do [ "$t" = "$CARRIER" ] && { echo "  carrier: $CARRIER"; return 0; }; done
    err "Carrier '$CARRIER' is not available here (use: ${opts[*]})"; return 1
  fi
  say "  ${BOLD}Connection type${RST}: how the two servers talk to each other"
  for ((i=0; i<n; i++)); do
    case "${opts[$i]}" in
      icmp) [ "${opts[0]}" = auto ] && say "  ${GRY}Or choose one type yourself (fixed; to change it later, make a new tunnel):${RST}"
            say "   ${GRY}Gets through the strictest filters${RST}" ;;
      udp) say "   ${GRY}Fast and simple, if your route lets them through${RST}" ;;
      tls) say "   ${GRY}Looks like web traffic: harder to block, and the only kind a CDN carries${RST}" ;;
    esac
    say "    ${CYN}$((i+1))${RST} ${descs[$i]}"
  done
  for t in 1 2 3; do
    printf '  %s?%s Press a number %s[1 = %s]%s ' "$CYN" "$RST" "$GRY" "${opts[0]}" "$RST"
    key_read
    case "$KEY" in
      enter) CARRIER=${opts[0]} ;;
      [1-9]) if [ "$KEY" -le "$n" ]; then CARRIER=${opts[$((KEY-1))]}; else echo; warn "Press a number from 1 to $n."; continue; fi ;;
      esc|q) echo; return 1 ;;
      *) echo; warn "Press a number from 1 to $n."; continue ;;
    esac
    echo "$CARRIER"; return 0
  done
  return 1
}
summary_line() { printf '    %s%-14s%s %s\n' "$GRY" "$1" "$RST" "$2"; }

wizard_kharej() {
  local name cr listen='' path='' sni='' itype='' mbps='' fec='' addr key m peer allow t rev='' iranip='' advdef=n
  page "New tunnel" "STEP 1 · Kharej (outside server)"
  step_diagram 1
  echo
  say "  Run this on the server where your ${BOLD}real service${RST} lives (Xray, a panel...)."
  say "  It creates a ${BOLD}token${RST}; you paste that token on the Iran server next."
  hint "Ctrl+C cancels at any time."
  echo
  name=$(suggest_name kharej); [ -n "$NI_NAME" ] && name=$NI_NAME
  pick_carrier auto || return 1
  cr=$CARRIER
  if [ "$cr" = auto ]; then wizard_kharej_auto "$name"; return; fi
  [ "$cr" != icmp ] && listen=$(default_listen "$cr")
  case "$cr" in ws|wss|grpc|h2|h2c) path=/wat; [ -n "$NI_PATH" ] && path=$NI_PATH ;; esac
  [ "$cr" != icmp ] && [ -n "$NI_LISTEN" ] && listen=$NI_LISTEN
  sni=$NI_SNI; mbps=$NI_MBPS
  advdef=n; [ -n "$NI_LISTEN$NI_PATH$NI_SNI$NI_MBPS" ] && advdef=y # a flag for an advanced setting opens that block (defaults = the flags)

  # allowed ports: all unless --ports is given (the port editor stays in the tunnel menu)
  MAPS=(); PE_ROLE=Kharej; PE_TUNNEL=$name; PE_ALLOW=(); PE_OWNED=(); PE_MSG=''
  allow=''
  if [ -n "$NI_PORTS" ]; then ni_kharej_ports || return 1; allow=$(maps_allow_str); fi

  # address Iran connects to
  page "New tunnel" "STEP 1 · Kharej (outside server)"
  if [ -n "$NI_ADDR" ]; then addr=$NI_ADDR
  else spin_start "Detecting this server's public IP"; addr=$(public_ip); spin_stop; fi
  if [ -z "$NI_ADDR" ] && [ -n "$addr" ] && ip_is_private "$addr"; then
    warn "$addr looks like a private address; Iran cannot reach it."
    confirm "Use $addr anyway? (n = enter the public IP yourself)" n || addr=''
    [ -z "$addr" ] && hint "Behind NAT or a cloud 1:1 mapping? Enter the public IP shown in your provider's panel."
  elif [ -z "$addr" ]; then
    warn "Could not detect this server's public IP."
    [ "$NONINTERACTIVE" = 1 ] && hint "Give it with --addr HOST"
  fi
  if [ -z "$addr" ]; then
    ask_ok "Public IP or domain of this server" "" v_host || return 1; addr=$REPLY_V
  else
    ok "Public address: $addr"
  fi
  case "$cr" in
    wss|grpc|h2) # these usually sit behind a CDN, where Iran must use the domain
      hint "Behind Cloudflare/a CDN? Enter your domain. Otherwise press Enter to keep the IP."
      ask_ok "Address Iran connects to" "$addr" v_host || return 1; addr=$REPLY_V ;;
  esac

  # advanced
  echo
  hint "Automatic: name $name, address $addr${listen:+, port $listen}${path:+, path $path}, no speed limit, FEC off."
  if confirm "Change advanced settings? (Enter = no, keep the automatic ones)" "$advdef"; then
    ask_ok "Tunnel name" "$name" v_name && name=$REPLY_V || return 1
    ask_ok "Address Iran connects to (IP or domain)" "$addr" v_host || return 1; addr=$REPLY_V
    if [ "$cr" = icmp ]; then
      hint "Keep echo unless ping echo is blocked on your route."
      ask_ok "ICMP type (echo, timestamp, info, mask)" echo v_icmp || return 1; itype=$REPLY_V
      echo; reverse_hint icmp
      if confirm "Reverse direction (this server sends the pings to Iran)?" n; then
        ask_ok "Iran server IPv4 address" "" v_ipv4 || return 1; iranip=$REPLY_V; rev=1
      fi
    else
      while :; do
        ask_ok "Listen port" "$listen" v_port || return 1
        if listen_blocked "$([ "$cr" = udp ] && echo udp || echo tcp)" "$REPLY_V"; then err "Port $REPLY_V is already used by $(listen_conflict_desc "$([ "$cr" = udp ] && echo udp || echo tcp)" "$REPLY_V")."; else listen=$((10#$REPLY_V)); break; fi
        t=$((${t:-0}+1)); [ "$t" -ge 3 ] && { err "Too many tries, going back."; return 1; }
      done
      if is_pool "$cr"; then
        echo; reverse_hint "$cr"
        if confirm "Reverse direction (this server connects out to Iran on port $listen)?" n; then
          ask_ok "Iran server IPv4 address" "" v_ipv4 || return 1; iranip=$REPLY_V; rev=1
        fi
      fi
    fi
    case "$cr" in ws|wss|grpc|h2|h2c) ask_ok "URL path" "$path" v_path || return 1; path=$REPLY_V ;; esac
    case "$cr" in wss|tls|grpc|h2) ask "Domain / SNI sent by Iran (empty = none)" "$sni"; sni=$REPLY_V ;; esac
    ask_ok "Speed ceiling in MB/s (empty = default 16)" "$mbps" v_mbps || return 1; mbps=$REPLY_V
    ask_ok "FEC: off or auto (auto needs auto on both ends)" off v_fec || return 1; fec=$REPLY_V
  fi
  valid_name "$name" || { err "The name '$name' is not available."; return 1; }
  case "$cr" in wss|grpc|h2|tls) [ -z "$sni" ] && ! [[ "$addr" =~ ^[0-9.]+$ ]] && sni=$addr ;; esac

  # summary
  page "New tunnel" "review"
  say "  ${BOLD}Ready to create${RST}"
  summary_line "Name" "$name  (Kharej, tunnel server)"
  summary_line "Carrier" "$cr${itype:+ ($itype)}${listen:+ on port $listen}${path:+ path $path}"
  summary_line "Address" "$addr"
  if [ "$rev" = 1 ]; then
    if [ "$cr" = icmp ]; then summary_line "Direction" "reverse: this server pings Iran at $iranip"
    else summary_line "Direction" "reverse: this server connects to Iran at $iranip:$listen"; fi
  fi
  summary_line "Allowed ports" "${allow:-any (no allow list: everything on 127.0.0.1 of this server is reachable through the tunnel)}"
  [ -n "$mbps" ] && summary_line "Speed limit" "$mbps MB/s"
  [ "$fec" = auto ] && summary_line "FEC" auto
  echo
  confirm "Create this tunnel?" y || { warn "Nothing was created."; return 1; }
  echo

  key=$(new_key); m=$(free_metrics_port)
  peer=$addr; [ -n "$listen" ] && peer="$addr:$listen"
  write_server() {
    local old; old=$(umask); umask 077
    printf '%s\n' "$key" >"$CONF/$name.key" || return 1
    {
      echo "# WatTunnel - Kharej (server). Created by wattun-manager."
      echo "mode: server"
      echo "key-file: $CONF/$name.key"
      echo "carrier: $cr"
      [ -n "$listen" ] && [ "$rev" != 1 ] && echo "listen: \":$listen\""
      [ -n "$path" ] && echo "path: $path"
      [ -n "$itype" ] && [ "$itype" != echo ] && echo "icmp-type: $itype"
      if [ "$rev" = 1 ]; then
        echo "reverse: true"
        if is_pool "$cr"; then
          echo "peer: $iranip:$listen"
          [ -n "$sni" ] && { echo "sni: $sni"; echo "host: $sni"; }
        else echo "peer: $iranip"; fi
      fi
      [ -n "$mbps" ] && echo "max-mbps: $mbps"
      [ "$fec" = auto ] && echo "fec: auto"
      echo "metrics: 127.0.0.1:$m"
      maps_yaml_block
    } >"$CONF/$name.yml"
    make_token "$cr" "$peer" "$key" "$path" "$sni" "$itype" "$allow" "$rev" >"$CONF/$name.token"
    umask "$old"
  }
  mkdir -p "$CONF"; chmod 700 "$CONF"
  step "Writing key, config and token" write_server || return 1
  start_unit "$name" || return 1
  [ -n "$listen" ] && [ "$rev" != 1 ] && fw_open "$listen/$([ "$cr" = udp ] && echo udp || echo tcp)"
  if [ "$rev" = 1 ] && is_pool "$cr"; then hint "Reverse: Iran listens on port $listen (the Iran wizard opens it). Kharej must be allowed to connect out to $iranip:$listen."
  elif [ "$rev" = 1 ]; then hint "Reverse ICMP: Iran must answer ping from this server. Do not block ICMP in either cloud firewall."
  elif [ "$cr" = icmp ]; then hint "ICMP: this server must answer ping. Do not block ICMP in the cloud firewall."; fi
  case "$cr" in tls|wss|grpc|h2) hint "TLS: the certificate is self-signed and unchecked by default. Pin it with tls-pin on the dialing side (docs/TECHNICAL.md, 'Certificates')." ;; esac

  echo
  celebrate "Kharej tunnel '$name' is ready"
  echo
  say "  ${BOLD}Your connection token${RST} (copy the whole line):"
  echo
  printf '%s%s%s\n\n' "$BOLD$YEL" "$(cat "$CONF/$name.token")" "$RST"
  step_diagram 2
  echo
  say "  ${BOLD}Now, STEP 2${RST}: on the ${BOLD}Iran${RST} server run ${CYN}${SELF}${RST}, press ${CYN}[n]${RST},"
  say "  choose Iran and paste the token."
  hint "Show it again any time: $SELF token $name"
  warn "The token contains the key — treat it like a password: anyone who sees it can use the tunnel. Share it only over a private channel."
  [ "$NONINTERACTIVE" = 1 ] && printf 'TUNNEL=%s\nTOKEN=%s\n' "$name" "$(cat "$CONF/$name.token")"
  return 0
}

ni_kharej_ports() { # --ports "18999,2000,53/udp" -> MAPS (Kharej side: the service ports Iran may reach)
  local msg
  pe_bulk "$NI_PORTS"
  msg=$PE_MSG; PE_MSG=''
  [ -n "$msg" ] && printf '%b' "$msg" | sed 's/^/  /'
  if [[ "$msg" == *✘* ]]; then err "--ports '$NI_PORTS' was rejected (see above)"; return 1; fi
  return 0
}

# ======================================================================================
#  Anti-Censorship Presets, Selection Helpers, and Numbered Pickers
# ======================================================================================
preset_canonical() {
  local p="${1,,}"
  case "$p" in
    mci|mci-whitelist|hamrah|hamrah-aval) echo mci ;;
    irancell|mokhaberat|tci|irancell-whitelist) echo irancell ;;
    blackout|emergency|strict) echo blackout ;;
    conservative|low-churn|mild) echo conservative ;;
    "iran whitelist - mci") echo mci ;;
    "iran whitelist - irancell/mokhaberat"|"iran whitelist - irancell"|"iran whitelist - mokhaberat") echo irancell ;;
    "emergency blackout mode") echo blackout ;;
    "conservative / low-churn"|"conservative/low-churn") echo conservative ;;
    off|clear|none) echo off ;;
    *) echo "$1" ;;
  esac
}

is_builtin_preset() {
  case "$(preset_canonical "$1")" in
    mci|irancell|blackout|conservative) return 0 ;;
  esac
  return 1
}

show_builtin_preset() {
  local p; p=$(preset_canonical "$1")
  case "$p" in
    mci)
      cat <<'EOF'
# WatTunnel built-in preset: Iran Whitelist - MCI
# Optimized for Hamrah Aval (MCI) whitelist restrictions
FAKESNI=mci.ir
FAKEMODE=seqsum
FAKETTL=
POOLROT=30m
POOLBYTES=500MB
ECH=ladder
GOVERNOR=true
EOF
      ;;
    irancell)
      cat <<'EOF'
# WatTunnel built-in preset: Iran Whitelist - Irancell/Mokhaberat
# Optimized for MTN Irancell and TCI allowlist bypass
FAKESNI=irancell.ir
FAKEMODE=seq
FAKETTL=
POOLROT=20m
POOLBYTES=300MB
ECH=ladder
GOVERNOR=true
EOF
      ;;
    blackout)
      cat <<'EOF'
# WatTunnel built-in preset: Emergency Blackout Mode
# Aggressive anti-censorship settings for strict national intranet / blackout regimes
FAKESNI=mci.ir
FAKEMODE=auto
FAKETTL=
POOLROT=90s
POOLBYTES=100MB
ECH=ladder
GOVERNOR=true
EOF
      ;;
    conservative)
      cat <<'EOF'
# WatTunnel built-in preset: Conservative / Low-Churn
# Low reconnect churn for stable connections under mild DPI filtering
FAKESNI=mci.ir
FAKEMODE=seq
FAKETTL=
POOLROT=4h
POOLBYTES=4GB
ECH=auto
GOVERNOR=true
EOF
      ;;
  esac
}

detect_preset() {
  local n=$1 fs fm rot rbytes cr
  cr=$(cfg "$n" carrier)
  if [ "$cr" = icmp ]; then
    if [ "$(cfg "$n" governor)" = true ]; then
      echo "${GRN}Governor Active (ICMP Pacer)${RST}"
    else
      echo "${GRY}none / disabled${RST}"
    fi
    return
  fi
  fs=$(cfg "$n" fake-sni)
  fm=$(cfg "$n" fake-mode); [ -z "$fm" ] && [ -n "$fs" ] && fm=seq
  rot=$(cfg "$n" pool-rotate)
  rbytes=$(cfg "$n" pool-rotate-bytes)
  if [ -z "$fs" ] && [ -z "$rot" ] && [ "$(cfg "$n" governor)" != true ]; then
    echo "${GRY}none / disabled${RST}"; return
  fi
  if [ "$fs" = "mci.ir" ] && [ "$fm" = "seqsum" ] && [ "$rot" = "30m" ]; then
    echo "${GRN}Iran Whitelist - MCI${RST}"; return
  fi
  if [ "$fs" = "irancell.ir" ] && [ "$fm" = "seq" ] && [ "$rot" = "20m" ]; then
    echo "${GRN}Iran Whitelist - Irancell/Mokhaberat${RST}"; return
  fi
  if [ "$fs" = "mci.ir" ] && [ "$fm" = "auto" ] && [ "$rot" = "90s" ]; then
    echo "${RED}Emergency Blackout Mode${RST}"; return
  fi
  if [ "$fs" = "mci.ir" ] && [ "$fm" = "seq" ] && [ "$rot" = "4h" ]; then
    echo "${BLU}Conservative / Low-Churn${RST}"; return
  fi
  echo "${CYN}Custom${RST}"
}

pick_preset() { # [default] -> REPLY_V
  local def=${1:-mci}
  if [ "$NONINTERACTIVE" = 1 ]; then
    REPLY_V=${NI_PRESET:-$def}
    return 0
  fi
  say "  ${BOLD}Select Built-in Anti-Censorship Preset${RST}:"
  say "    ${CYN}1${RST}  Iran Whitelist - MCI          (mci.ir, seqsum mode, 30m / 500MB churn, ECH ladder)"
  say "    ${CYN}2${RST}  Iran Whitelist - Irancell     (irancell.ir, seq mode, 20m / 300MB churn, ECH ladder)"
  say "    ${CYN}3${RST}  Emergency Blackout Mode       (mci.ir, auto probe, 90s / 100MB rapid churn, ECH ladder)"
  say "    ${CYN}4${RST}  Conservative / Low-Churn      (mci.ir, seq mode, 4h / 4GB, ECH auto)"
  say "    ${CYN}5${RST}  Disabled / Clear              (turn off all anti-censorship features)"
  echo
  printf '  %s?%s Press a number %s[1 = MCI]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read
  case "$KEY" in
    1|enter) REPLY_V="mci" ;;
    2) REPLY_V="irancell" ;;
    3) REPLY_V="blackout" ;;
    4) REPLY_V="conservative" ;;
    5) REPLY_V="off" ;;
    esc|q) echo; return 1 ;;
    *) REPLY_V="$def" ;;
  esac
  echo "$REPLY_V"
  return 0
}

pick_sni_preset() { # [default] -> REPLY_V
  local def=${1:-mci.ir}
  if [ "$NONINTERACTIVE" = 1 ]; then
    REPLY_V=${NI_FAKESNI:-$def}
    return 0
  fi
  say "  ${BOLD}Select Allowlisted SNI Domain${RST} (curated presets):"
  say "    ${CYN}0${RST}  off               Turn Fake-SNI OFF (disabled)"
  say "    ${CYN}1${RST}  mci.ir            MCI / Hamrah Aval (Portal)"
  say "    ${CYN}2${RST}  shop.mci.ir       MCI Online Store"
  say "    ${CYN}3${RST}  irancell.ir       Irancell (Portal)"
  say "    ${CYN}4${RST}  my.irancell.ir    MyIrancell"
  say "    ${CYN}5${RST}  tci.ir            Mokhaberat (TCI)"
  say "    ${CYN}6${RST}  rightel.ir        RighTel"
  say "    ${CYN}7${RST}  divar.ir          Divar Classifieds"
  say "    ${CYN}8${RST}  digikala.com      Digikala E-Commerce"
  say "    ${CYN}9${RST}  bale.ai           Bale Messenger"
  say "    ${CYN}s${RST}  srbiau.ac.ir      Academic / EDU Portal"
  say "    ${CYN}c${RST}  Custom SNI        (type domain manually)"
  echo
  printf '  %s?%s Press a number %s[1 = mci.ir]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read
  case "$KEY" in
    0) REPLY_V="off" ;;
    1) REPLY_V="mci.ir" ;;
    2) REPLY_V="shop.mci.ir" ;;
    3) REPLY_V="irancell.ir" ;;
    4) REPLY_V="my.irancell.ir" ;;
    5) REPLY_V="tci.ir" ;;
    6) REPLY_V="rightel.ir" ;;
    7) REPLY_V="divar.ir" ;;
    8) REPLY_V="digikala.com" ;;
    9) REPLY_V="bale.ai" ;;
    s|S) REPLY_V="srbiau.ac.ir" ;;
    c|C) echo; ask_ok "Allowlisted SNI domain" "$def" v_sni_name || return 1 ;;
    enter) REPLY_V="$def" ;;
    esc|q) echo; return 1 ;;
    *) REPLY_V="$def" ;;
  esac
  echo "$REPLY_V"
  return 0
}

pick_fake_mode() { # [default] -> REPLY_V
  local def=${1:-seqsum}
  if [ "$NONINTERACTIVE" = 1 ]; then
    REPLY_V=${NI_FAKEMODE:-$def}
    return 0
  fi
  say "  ${BOLD}Select Fake Desync Mode${RST}:"
  say "    ${CYN}1${RST}  auto    Probe link on startup, auto-select optimal mode (2.9.0+, recommended)"
  say "    ${CYN}2${RST}  seqsum  Dual marker: seq desync + bad checksum (2.8.0+, best all-round bypass)"
  say "    ${CYN}3${RST}  sum     In-window segment, bad TCP checksum (2.7.1+, stateful NATs)"
  say "    ${CYN}4${RST}  seq     Out-of-window sequence marker (2.7.0+, standard default)"
  say "    ${CYN}5${RST}  ttl     Hop-count distance calibration (2.7.0+)"
  say "    ${CYN}6${RST}  rst     Corrupted-checksum RST packet (2.9.0+, middlebox state confusion)"
  echo
  printf '  %s?%s Press a number %s[1 = auto]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read
  case "$KEY" in
    1) REPLY_V="auto" ;;
    2) REPLY_V="seqsum" ;;
    3) REPLY_V="sum" ;;
    4) REPLY_V="seq" ;;
    5) REPLY_V="ttl" ;;
    6) REPLY_V="rst" ;;
    enter) REPLY_V="$def" ;;
    esc|q) echo; return 1 ;;
    *) REPLY_V="$def" ;;
  esac
  echo "$REPLY_V"
  return 0
}

pick_pool_rotate() { # [default] -> REPLY_V
  local def=${1:-30m}
  if [ "$NONINTERACTIVE" = 1 ]; then
    REPLY_V=${NI_POOLROT:-$def}
    return 0
  fi
  say "  ${BOLD}Select Pool Rotation Lifetime${RST} (recycles connections to avoid long-lived flows):"
  say "    ${CYN}1${RST}  off   Disabled (connections stay open indefinitely)"
  say "    ${CYN}2${RST}  30m   30 minutes (recommended / standard)"
  say "    ${CYN}3${RST}  90s   90 seconds (aggressive / blackout evasion)"
  say "    ${CYN}4${RST}  10m   10 minutes"
  say "    ${CYN}5${RST}  2h    2 hours"
  say "    ${CYN}6${RST}  4h    4 hours (conservative)"
  say "    ${CYN}c${RST}  Custom lifetime (e.g. 15m, 1h)"
  echo
  printf '  %s?%s Press a number %s[2 = 30m]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read
  case "$KEY" in
    1) REPLY_V="off" ;;
    2) REPLY_V="30m" ;;
    3) REPLY_V="90s" ;;
    4) REPLY_V="10m" ;;
    5) REPLY_V="2h" ;;
    6) REPLY_V="4h" ;;
    enter) REPLY_V="$def" ;;
    c|C) echo; ask_ok "Pool rotation lifetime" "$def" v_pool_rotate || return 1 ;;
    esc|q) echo; return 1 ;;
    *) REPLY_V="$def" ;;
  esac
  echo "$REPLY_V"
  return 0
}

pick_pool_rotate_bytes() { # [default] -> REPLY_V
  local def=${1:-500MB}
  if [ "$NONINTERACTIVE" = 1 ]; then
    REPLY_V=${NI_POOLBYTES:-$def}
    return 0
  fi
  say "  ${BOLD}Select Pool Rotation Byte Budget${RST} (recycles after traffic volume):"
  say "    ${CYN}1${RST}  off    Disabled (byte limit off)"
  say "    ${CYN}2${RST}  500MB  500 Megabytes (recommended / standard)"
  say "    ${CYN}3${RST}  100MB  100 Megabytes (aggressive / blackout evasion)"
  say "    ${CYN}4${RST}  1GB    1 Gigabyte"
  say "    ${CYN}5${RST}  4GB    4 Gigabytes (conservative)"
  say "    ${CYN}c${RST}  Custom byte count (e.g. 250MB, 2GB)"
  echo
  printf '  %s?%s Press a number %s[2 = 500MB]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read
  case "$KEY" in
    1) REPLY_V="off" ;;
    2) REPLY_V="500MB" ;;
    3) REPLY_V="100MB" ;;
    4) REPLY_V="1GB" ;;
    5) REPLY_V="4GB" ;;
    enter) REPLY_V="$def" ;;
    c|C) echo; ask_ok "Pool rotation byte budget" "$def" v_pool_bytes || return 1 ;;
    esc|q) echo; return 1 ;;
    *) REPLY_V="$def" ;;
  esac
  echo "$REPLY_V"
  return 0
}

pick_ech() { # [default] -> REPLY_V
  local def=${1:-ladder}
  if [ "$NONINTERACTIVE" = 1 ]; then
    REPLY_V=${NI_ECH:-$def}
    return 0
  fi
  say "  ${BOLD}Select Encrypted Client Hello (ECH) Mode${RST}:"
  say "    ${CYN}1${RST}  ladder  ECH Bootstrap Ladder (2.9.0+, DoH queries relayed via Kharej DNS)"
  say "    ${CYN}2${RST}  auto    Direct DoH parallel race (Cloudflare/Google/Quad9)"
  say "    ${CYN}3${RST}  off     Disabled"
  say "    ${CYN}c${RST}  Custom  Base64 ECHConfigList"
  echo
  printf '  %s?%s Press a number %s[1 = ladder]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read
  case "$KEY" in
    1) REPLY_V="ladder" ;;
    2) REPLY_V="auto" ;;
    3) REPLY_V="off" ;;
    enter) REPLY_V="$def" ;;
    c|C) echo; ask_ok "ECH config (ladder, auto, off, or base64)" "$def" v_ech || return 1 ;;
    esc|q) echo; return 1 ;;
    *) REPLY_V="$def" ;;
  esac
  echo "$REPLY_V"
  return 0
}

pick_dns_listen() { # [default] -> REPLY_V
  local def=${1:-off}
  if [ "$NONINTERACTIVE" = 1 ]; then
    REPLY_V=${NI_DNSLISTEN:-$def}
    return 0
  fi
  say "  ${BOLD}Select DNS Forwarder Listener${RST} (in-band relay to bypass domestic DNS hijacking):"
  say "    ${CYN}1${RST}  off            Disabled"
  say "    ${CYN}2${RST}  127.0.0.1:53   Standard local DNS resolver"
  say "    ${CYN}3${RST}  127.0.0.1:5353 Alternative unprivileged local port"
  say "    ${CYN}4${RST}  0.0.0.0:53     LAN-wide DNS relay for home/office devices"
  say "    ${CYN}c${RST}  Custom         Enter custom address:port"
  echo
  printf '  %s?%s Press a number %s[1 = off]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read
  case "$KEY" in
    1) REPLY_V="off" ;;
    2) REPLY_V="127.0.0.1:53" ;;
    3) REPLY_V="127.0.0.1:5353" ;;
    4) REPLY_V="0.0.0.0:53" ;;
    c|C) echo; ask_ok "Custom DNS listen address:port" "127.0.0.1:53" v_dns_listen || return 1 ;;
    enter) REPLY_V="$def" ;;
    esc|q) echo; return 1 ;;
    *) REPLY_V="$def" ;;
  esac
  echo "$REPLY_V"
  return 0
}

pick_src_ip() { # [default] -> REPLY_V
  local def=${1:-off}
  if [ "$NONINTERACTIVE" = 1 ]; then
    REPLY_V=${NI_SRCIP:-$def}
    return 0
  fi
  say "  ${BOLD}Select Carrier Source IP Binding${RST} (for multi-WAN / cellular APN routing):"
  say "    ${CYN}0${RST}  off  Default kernel routing (system routing table)"
  local ips=() idx=1
  if command -v ip >/dev/null 2>&1; then
    while read -r _ _ _ ifa _ _ ifn _; do
      local clean_ip="${ifa%%/*}"
      [ "$clean_ip" = "127.0.0.1" ] && continue
      ips+=("$clean_ip ($ifn)")
      printf '    %s%d%s  %s\n' "$CYN" "$idx" "$RST" "$clean_ip ($ifn)"
      idx=$((idx+1))
    done < <(ip -4 -o addr show 2>/dev/null)
  fi
  printf '    %sc%s  Custom IPv4 address\n' "$CYN" "$RST"
  echo
  printf '  %s?%s Press a number %s[0 = off]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read
  case "$KEY" in
    0) REPLY_V="off" ;;
    c|C) echo; ask_ok "Custom IPv4 address" "" v_src_ip || return 1 ;;
    enter) REPLY_V="$def" ;;
    esc|q) echo; return 1 ;;
    *)
      if [[ "$KEY" =~ ^[1-9]$ ]] && [ "$KEY" -le "${#ips[@]}" ]; then
        local sel="${ips[$((KEY-1))]}"
        REPLY_V="${sel%% *}"
      else
        REPLY_V="$def"
      fi
      ;;
  esac
  echo "$REPLY_V"
  return 0
}

apply_preset() { # tunnel preset
  local tun=$1 raw_preset=$2 pr changed=0
  pr=$(preset_canonical "$raw_preset")
  local cr; cr=$(cfg "$tun" carrier)
  local r; r=$(role "$tun")
  [ "$r" = Iran ] || { err "'$tun' is not an Iran tunnel (anti-censorship presets are client-only)."; return 1; }
  [ "$(bin_ver_ok 2.7.0)" = 1 ] || { err "Anti-censorship features need wattun 2.7.0 or newer (run: $SELF update)."; return 1; }
  if is_pool "$cr" && is_reverse "$tun"; then
    err "'$tun' is a reverse pool tunnel (Kharej dials in to Iran). Anti-censorship desync is dialer-side only."; return 1
  fi
  if [ "$cr" != icmp ] && ! is_pool "$cr"; then
    err "Carrier '$cr' does not support anti-censorship features (only pool carriers and icmp are supported)."; return 1
  fi

  local fs='' fm='' ft='' rot='' rbytes='' ech='' gov=''
  case "$pr" in
    mci)
      fs="mci.ir"; fm="seqsum"; ft=""; rot="30m"; rbytes="500MB"; ech="ladder"; gov="true" ;;
    irancell)
      fs="irancell.ir"; fm="seq"; ft=""; rot="20m"; rbytes="300MB"; ech="ladder"; gov="true" ;;
    blackout)
      fs="mci.ir"; fm="auto"; ft=""; rot="90s"; rbytes="100MB"; ech="ladder"; gov="true" ;;
    conservative)
      fs="mci.ir"; fm="seq"; ft=""; rot="4h"; rbytes="4GB"; ech="auto"; gov="true" ;;
    off|clear|none)
      fs=""; fm=""; ft=""; rot=""; rbytes=""; ech=""; gov="" ;;
    *) err "Unknown preset '$raw_preset'. Available: mci, irancell, blackout, conservative"; return 1 ;;
  esac

  if [ "$cr" = icmp ]; then
    if [ "$gov" = true ]; then
      set_value "$tun" governor true; changed=1
    elif [ "$pr" = off ]; then
      unset_value "$tun" governor; changed=1
    fi
  fi

  if is_pool "$cr"; then
    if [ -n "$fs" ]; then
      set_value "$tun" fake-sni "$fs"; changed=1
      set_value "$tun" fake-mode "$fm"; changed=1
      if [ -n "$ft" ]; then set_value "$tun" fake-ttl "$ft"; else unset_value "$tun" fake-ttl; fi
    elif [ -n "$(cfg "$tun" fake-sni)" ]; then
      unset_value "$tun" fake-sni; unset_value "$tun" fake-mode; unset_value "$tun" fake-ttl; changed=1
    fi

    if [ -n "$rot" ]; then set_value "$tun" pool-rotate "$rot"; changed=1
    elif [ -n "$(cfg "$tun" pool-rotate)" ]; then unset_value "$tun" pool-rotate; changed=1; fi

    if [ -n "$rbytes" ]; then set_value "$tun" pool-rotate-bytes "$rbytes"; changed=1
    elif [ -n "$(cfg "$tun" pool-rotate-bytes)" ]; then unset_value "$tun" pool-rotate-bytes; changed=1; fi

    case "$cr" in
      tls|wss|h2|grpc)
        if [ -n "$ech" ]; then set_value "$tun" ech "$ech"; changed=1
        elif [ -n "$(cfg "$tun" ech)" ]; then unset_value "$tun" ech; changed=1; fi
        ;;
    esac
  fi

  [ "$changed" = 1 ] || { hint "Preset '$pr' already matches current settings."; return 0; }
  ok "Applied anti-censorship preset '$pr' to $tun."
  if step "Restarting ${WAT_PREFIX}@$tun" systemctl restart "${WAT_PREFIX}@$tun"; then ok "Restart applied."
  else err "Restart failed: run  systemctl restart ${WAT_PREFIX}@$tun"; return 1; fi
  return 0
}

wizard_iran() {
  local name tok have manual=0 bind='' mbps='' fec='' itype='' sni='' path='' m i allow_note it new_pub=() t=0 rport='' advdef=n linkok=1 askres
  local T_FAKESNI='' T_FAKEMODE='' T_FAKETTL='' T_POOLROT='' T_POOLBYTES='' T_ECH='' T_GOVERNOR='' T_DNSLISTEN='' T_SRCIP=''
  page "New tunnel" "STEP 2 · Iran (inside server)"
  step_diagram 2
  echo
  say "  This is the server your ${BOLD}users connect to${RST}. It needs the token made on Kharej."
  echo
  name=$(suggest_name iran); [ -n "$NI_NAME" ] && name=$NI_NAME
  mbps=$NI_MBPS; [ -n "$mbps" ] && advdef=y
  T_CARRIER=''; T_PEER=''; T_KEY=''; T_PATH=''; T_SNI=''; T_ICMP=''; T_PORTS=''; T_REV=''; T_AUTO=''
  AUTO_TOKEN=''; AT_EXTRA=''; CT_DESC=''
  confirm "Do you have the token from the Kharej server?" y && have=y || have=n
  if [ "$have" = n ]; then
    echo
    say "  ${BOLD}Get the token first${RST}"
    say "    1. Log in to the ${BOLD}Kharej${RST} (outside) server"
    say "    2. Run  ${CYN}${SELF}${RST}  then press ${CYN}[n]${RST} and choose ${BOLD}Kharej${RST}"
    say "    3. Copy the token it prints (one long line starting with ${BOLD}wat1:${RST})"
    echo
    printf '  %s[Enter]%s I have it now   %s[m]%s enter the details by hand (advanced)   %s[q]%s go back\n  ' "$CYN" "$RST" "$CYN" "$RST" "$CYN" "$RST"
    key_read; echo
    case "$KEY" in m|M) manual=1 ;; enter) ;; *) return 1 ;; esac
  fi
  if [ "$manual" = 0 ]; then
    echo
    ask_ok "Paste the connection token" "$NI_TOKEN" v_token || return 1
    tok=$REPLY_V; read_token "$tok"
    echo
    ok "Token accepted"
    if [ "$T_CARRIER" = auto ]; then
      auto_iran_front "$tok" || return 1
    else
      summary_line "Carrier" "$T_CARRIER${T_ICMP:+ ($T_ICMP)}"
      summary_line "Kharej" "$T_PEER"
      summary_line "Kharej allows" "${T_PORTS:-any port}"
      if [ "$T_REV" = 1 ]; then
        if is_pool "$T_CARRIER"; then summary_line "Direction" "reverse (Kharej connects to this server on port ${T_PEER##*:})"
        else summary_line "Direction" "reverse: Kharej sends the pings, this server answers"; fi
      fi
      cdn_wizard_tune # CDN carrier + domain: automatic edge / TLS tuning (wattun >= 2.2.0), silent otherwise
    fi
  else
    echo
    pick_carrier || return 1; T_CARRIER=$CARRIER
    ask_ok "Kharej address (IP or domain)" "" v_host || return 1; T_PEER=$REPLY_V
    if [ "$T_CARRIER" != icmp ]; then
      ask_ok "Kharej listen port" "$(default_listen "$T_CARRIER")" v_port || return 1; T_PEER="$T_PEER:$((10#$REPLY_V))"
    fi
    ask_ok "Key (the same as on Kharej)" "" v_key || return 1; T_KEY=$REPLY_V
    case "$T_CARRIER" in ws|wss|grpc|h2|h2c) ask_ok "URL path" /wat v_path || return 1; T_PATH=$REPLY_V ;; esac
    case "$T_CARRIER" in wss|tls|grpc|h2) ask "Domain / SNI (empty = none; used by Kharej when reverse)" ""; T_SNI=$REPLY_V ;; esac
    if [ "$T_CARRIER" = icmp ]; then
      ask_ok "ICMP type (must match Kharej)" echo v_icmp || return 1; T_ICMP=$REPLY_V
      confirm "Reverse direction (only if Kharej is set to reverse too)?" n && T_REV=1
    elif is_pool "$T_CARRIER"; then
      echo; reverse_hint "$T_CARRIER"
      confirm "Reverse direction (only if Kharej is set to reverse too)?" n && T_REV=1
    fi
  fi
  rport=''
  if [ "$T_REV" = 1 ] && is_pool "$T_CARRIER"; then
    rport=${T_PEER##*:}
    v_port "$rport" >/dev/null 2>&1 && [ "$rport" != "$T_PEER" ] || { err "The Kharej address has no valid carrier port, so reverse cannot be set up."; return 1; }
    rport=$((10#$rport))
  fi
  sleep 0.4

  # port mappings
  MAPS=(); PE_ROLE=Iran; PE_TUNNEL=$name; PE_OWNED=()
  allow_to_array "$T_PORTS"
  PE_MSG=''
  if [ "${#PE_ALLOW[@]}" -gt 0 ]; then
    local skipped=0
    PE_MSG="${GRN}✔${RST} Pre-filled from the token: every port Kharej allows is published on the same port here."$'\n'
    PE_MSG+="  Edit a row to publish it on another Iran port (e.g. users on 8443, service on 443)."$'\n'
    # same checks as a hand-typed row: busy port, another tunnel publishing it
    for it in "${PE_ALLOW[@]}"; do pe_try_add "$(spec_T "$it"):$(spec_T "$it")/$(spec_P "$it")" || skipped=$((skipped+1)); done
    [ "$skipped" -gt 0 ] && pe_msg "${YEL}!${RST} $skipped port(s) from the token were skipped because they conflict (see above). Add each one on another Iran port (e.g. 8443:443)."
  fi
  port_editor || { warn "Cancelled."; return 1; }
  if [ -n "$rport" ]; then
    if listen_blocked tcp "$rport"; then
      err "Port $rport/tcp is already in use here by $(listen_conflict_desc tcp "$rport"). Reverse needs it free: pick another carrier port on Kharej and make a new token."
      return 1
    fi
    for ((i=0; i<${#MAPS[@]}; i++)); do
      if [ "$(spec_L "${MAPS[$i]}")" = "$rport" ] && [ "$(spec_P "${MAPS[$i]}")" = tcp ]; then
        err "Port $rport/tcp is also a port you publish here. The carrier port must differ: pick another one on Kharej and make a new token."
        return 1
      fi
    done
  fi

  # advanced
  echo
  hint "Automatic: name $name, listen on all addresses, no speed limit, FEC off."
  if confirm "Change advanced settings? (Enter = no, keep the automatic ones)" "$advdef"; then
    ask_ok "Tunnel name" "$name" v_name && name=$REPLY_V || return 1
    ask_ok "Bind address for the public ports" 0.0.0.0 v_bind || return 1; bind=$REPLY_V
    ask_ok "Speed ceiling in MB/s (empty = default 16)" "$mbps" v_mbps || return 1; mbps=$REPLY_V
    ask_ok "FEC: off or auto (auto needs auto on both ends)" off v_fec || return 1; fec=$REPLY_V
    if [ "$T_CARRIER" = icmp ]; then ask_ok "ICMP type (must match Kharej)" "${T_ICMP:-echo}" v_icmp || return 1; T_ICMP=$REPLY_V; fi
    case "$T_CARRIER" in wss|tls|grpc|h2) ask "Domain / SNI (empty = none)" "$T_SNI"; T_SNI=$REPLY_V ;; esac
    case "$T_CARRIER" in ws|wss|grpc|h2|h2c) ask_ok "URL path" "${T_PATH:-/wat}" v_path || return 1; T_PATH=$REPLY_V ;; esac
  fi
  # Resilience options (2.6.0-2.8.1): fake-sni (name, mode, ttl) and pool-rotate churn — the
  # blackout/whitelisting survival kit (docs/TECHNICAL.md). Strictly for censored routes, so NOT part
  # of the plain-tunnel flow: one explicit ask, then the same prompts as before. Unattended flags or a
  # saved profile prefill it and skip the ask — a preset IS the ask.
  # Anti-censorship & resilience options (2.6.0-2.9.0): presets, fake-sni, pool-rotate, ech, governor
  if [ "$T_REV" != 1 ] && [ -z "$T_AUTO" ] && [ "$(uname -s)" = Linux ]; then
    prof_pick_defaults
    # Unattended preset or flags
    if [ -n "$NI_PRESET" ]; then
      case "$NI_PRESET" in
        mci) T_FAKESNI="mci.ir"; T_FAKEMODE="seqsum"; T_POOLROT="30m"; T_POOLBYTES="500MB"; T_ECH="ladder"; T_GOVERNOR="true" ;;
        irancell) T_FAKESNI="irancell.ir"; T_FAKEMODE="seq"; T_POOLROT="20m"; T_POOLBYTES="300MB"; T_ECH="ladder"; T_GOVERNOR="true" ;;
        blackout) T_FAKESNI="mci.ir"; T_FAKEMODE="auto"; T_POOLROT="90s"; T_POOLBYTES="100MB"; T_ECH="ladder"; T_GOVERNOR="true" ;;
        conservative) T_FAKESNI="mci.ir"; T_FAKEMODE="seq"; T_POOLROT="4h"; T_POOLBYTES="4GB"; T_ECH="auto"; T_GOVERNOR="true" ;;
      esac
    fi
    [ -n "$NI_ECH" ] && T_ECH=$NI_ECH
    [ -n "$NI_GOVERNOR" ] && T_GOVERNOR=$NI_GOVERNOR
    [ -n "$NI_DNSLISTEN" ] && T_DNSLISTEN=$NI_DNSLISTEN
    [ -n "$NI_SRCIP" ] && T_SRCIP=$NI_SRCIP

    askres=y
    if [ -z "$NI_FAKESNI$NI_FAKEMODE$NI_FAKETTL$NI_POOLROT$NI_POOLBYTES$NI_PRESET$NI_ECH$NI_GOVERNOR$NI_DNSLISTEN$NI_SRCIP$T_FAKESNI$T_FAKEMODE$T_FAKETTL$T_POOLROT$T_POOLBYTES$T_ECH$T_GOVERNOR$T_DNSLISTEN$T_SRCIP" ]; then
      confirm "Configure anti-censorship / blackout resilience? Only for censored routes; Enter = no" n || askres=n
      [ "$askres" = n ] && hint "Fine for a normal route. If a censor starts blocking this tunnel: tunnel page -> o -> k."
    fi

    if [ "$askres" = y ] && [ -z "$NI_FAKESNI$NI_PRESET" ] && [ -z "$T_FAKESNI" ]; then
      echo
      say "  ${BOLD}Anti-Censorship Profile${RST}:"
      say "    ${CYN}1${RST}  Iran Whitelist - MCI          (mci.ir, seqsum mode, 30m / 500MB churn, ECH ladder)"
      say "    ${CYN}2${RST}  Iran Whitelist - Irancell     (irancell.ir, seq mode, 20m / 300MB churn, ECH ladder)"
      say "    ${CYN}3${RST}  Emergency Blackout Mode       (mci.ir, auto probe, 90s / 100MB rapid churn, ECH ladder)"
      say "    ${CYN}4${RST}  Conservative / Low-Churn      (mci.ir, seq mode, 4h / 4GB, ECH auto)"
      say "    ${CYN}5${RST}  Custom Configuration          (select SNI, mode, and rotation step-by-step)"
      say "    ${CYN}6${RST}  Skip                          (keep anti-censorship disabled)"
      printf '  %s?%s Choose profile %s[1 = MCI]%s ' "$CYN" "$RST" "$GRY" "$RST"
      key_read
      case "$KEY" in
        1|enter) T_FAKESNI="mci.ir"; T_FAKEMODE="seqsum"; T_POOLROT="30m"; T_POOLBYTES="500MB"; T_ECH="ladder"; T_GOVERNOR="true" ;;
        2) T_FAKESNI="irancell.ir"; T_FAKEMODE="seq"; T_POOLROT="20m"; T_POOLBYTES="300MB"; T_ECH="ladder"; T_GOVERNOR="true" ;;
        3) T_FAKESNI="mci.ir"; T_FAKEMODE="auto"; T_POOLROT="90s"; T_POOLBYTES="100MB"; T_ECH="ladder"; T_GOVERNOR="true" ;;
        4) T_FAKESNI="mci.ir"; T_FAKEMODE="seq"; T_POOLROT="4h"; T_POOLBYTES="4GB"; T_ECH="auto"; T_GOVERNOR="true" ;;
        5) # Custom step-by-step
           if is_pool "$T_CARRIER"; then
             pick_sni_preset "${T_FAKESNI:-mci.ir}" || return 1; T_FAKESNI=$REPLY_V
             if [ "$T_FAKESNI" = off ] || [ "$T_FAKESNI" = 0 ]; then T_FAKESNI=''; fi
             if [ -n "$T_FAKESNI" ]; then
               pick_fake_mode "${T_FAKEMODE:-seqsum}" || return 1; T_FAKEMODE=$REPLY_V
               if [ "$T_FAKEMODE" = ttl ]; then
                 ask "Fake TTL (hop count, empty = auto-calibrate)" "${T_FAKETTL:-}"; T_FAKETTL=$REPLY_V
                 v_fake_ttl "$T_FAKETTL" || return 1
               fi
             fi
             pick_pool_rotate "${T_POOLROT:-30m}" || return 1; T_POOLROT=$REPLY_V
             if [ "$T_POOLROT" = off ] || [ "$T_POOLROT" = 0 ]; then T_POOLROT=''; fi
             pick_pool_rotate_bytes "${T_POOLBYTES:-500MB}" || return 1; T_POOLBYTES=$REPLY_V
             if [ "$T_POOLBYTES" = off ] || [ "$T_POOLBYTES" = 0 ]; then T_POOLBYTES=''; fi
             case "$T_CARRIER" in
               tls|wss|h2|grpc)
                 pick_ech "${T_ECH:-ladder}" || return 1; T_ECH=$REPLY_V
                 if [ "$T_ECH" = off ]; then T_ECH=''; fi
                 ;;
             esac
           elif [ "$T_CARRIER" = icmp ]; then
             confirm "Enable ICMP volume governor (prevents reroute blackouts)?" y && T_GOVERNOR=true || T_GOVERNOR=false
           fi
           ;;
        6|esc|q) T_FAKESNI=''; T_FAKEMODE=''; T_POOLROT=''; T_POOLBYTES=''; T_ECH=''; T_GOVERNOR='' ;;
      esac
    fi

    # Fallback validation for any flags that were passed explicitly (e.g. --fake-sni mci.ir)
    if [ -n "$NI_FAKESNI" ] && [ -z "$T_FAKESNI" ]; then
      T_FAKESNI=$NI_FAKESNI
    fi
    if [ "$T_FAKESNI" = off ] || [ "$T_FAKESNI" = 0 ]; then T_FAKESNI=''; fi
    if [ -n "$T_FAKESNI" ]; then
      v_sni_name "$T_FAKESNI" || return 1
      [ "$(bin_ver_ok 2.7.0)" = 1 ] || err "fake-sni needs wattun 2.7.0 or newer on this server (run: $SELF update)."
      [ -n "${NI_FAKEMODE:-}" ] && T_FAKEMODE=$NI_FAKEMODE
      [ -n "$T_FAKEMODE" ] || T_FAKEMODE=seqsum
      v_fake_mode "$T_FAKEMODE" || return 1
      T_FAKETTL=${NI_FAKETTL:-${T_FAKETTL:-}}
      if [ "$T_FAKEMODE" = ttl ] && [ -n "$T_FAKETTL" ]; then v_fake_ttl "$T_FAKETTL" || return 1; fi
    fi
    if [ -n "$NI_POOLROT" ]; then T_POOLROT=$NI_POOLROT; fi
    if [ -n "$NI_POOLBYTES" ]; then T_POOLBYTES=$NI_POOLBYTES; fi
    if [ -n "$T_POOLROT" ] && [ "$T_POOLROT" != 0 ] && [ "$T_POOLROT" != off ]; then
      [ "$(bin_ver_ok 2.8.0)" = 1 ] || { err "pool-rotate needs wattun 2.8.0 or newer on this server (run: $SELF update)."; return 1; }
    fi
    if [ -n "$T_POOLBYTES" ] && [ "$T_POOLBYTES" != 0 ] && [ "$T_POOLBYTES" != off ]; then
      [ "$(bin_ver_ok 2.8.1)" = 1 ] || { err "pool-rotate-bytes needs wattun 2.8.1 or newer on this server (run: $SELF update)."; return 1; }
    fi
  fi
  valid_name "$name" || { err "The name '$name' is not available."; return 1; }

  # summary
  page "New tunnel" "review"
  say "  ${BOLD}Ready to create${RST}"
  summary_line "Name" "$name  (Iran, tunnel client)"
  summary_line "Carrier" "$T_CARRIER${T_ICMP:+ ($T_ICMP)}"
  summary_line "Kharej" "$T_PEER"
  [ -n "$CT_DESC" ] && summary_line "CDN tuning" "$CT_DESC"
  if [ -n "$T_FAKESNI" ]; then
    local fsum="Fake SNI" fsv="$T_FAKESNI (${T_FAKEMODE:-seq} mode)"
    [ "$T_FAKEMODE" = ttl ] && [ -n "$T_FAKETTL" ] && fsv="$fsv, ttl $T_FAKETTL"
    summary_line "$fsum" "$fsv"
  fi
  [ -n "$T_POOLROT" ] && [ "$T_POOLROT" != 0 ] && [ "$T_POOLROT" != off ] && summary_line "Pool rotate" "$T_POOLROT${T_POOLBYTES:+ / $T_POOLBYTES}"
  [ -n "$T_ECH" ] && [ "$T_ECH" != off ] && summary_line "ECH" "$T_ECH"
  [ "$T_GOVERNOR" = true ] && summary_line "Governor" "on"
  if [ "$T_REV" = 1 ]; then
    if [ -n "$rport" ]; then summary_line "Direction" "reverse (Kharej connects to this server on port $rport)"
    else summary_line "Direction" "reverse (Kharej sends the pings)"; fi
  fi
  allow_note=''; for ((i=0; i<${#MAPS[@]}; i++)); do allow_note="$allow_note $(spec_human "${MAPS[$i]}")"; done
  summary_line "Publishes" "${allow_note# }"
  [ -n "$bind" ] && [ "$bind" != 0.0.0.0 ] && summary_line "Bind" "$bind"
  [ -n "$mbps" ] && summary_line "Speed limit" "$mbps MB/s"
  [ "$fec" = auto ] && summary_line "FEC" auto
  # wss/grpc/h2 are the "through Cloudflare" carriers. If the peer is a raw IP and no CDN edges were tuned in, Iran
  # dials the origin directly (the domain is only an SNI/Host string), which works only where that IP is reachable
  # from the user's network - the usual cause of "runs on some servers, not others". Flag it before creating.
  case "$T_CARRIER" in
    wss|grpc|h2)
      if [ "$T_REV" != 1 ] && [ -z "$CT_DESC" ] && { ph=${T_PEER%%,*}; ipv4_ok "${ph%:*}"; }; then
        echo
        warn "peer is a direct IP (${ph%:*}) - this tunnel does NOT go through Cloudflare."
        hint "A direct IP works only where it is reachable from Iran, so it fails on some networks."
        hint "For Cloudflare: proxy a domain to this server (orange cloud) and enter that DOMAIN as the"
        hint "Kharej address, or run  wattun-manager cdn-tune $name  after creating it."
      fi ;;
  esac
  echo
  confirm "Create this tunnel?" y || { warn "Nothing was created."; return 1; }
  echo

  m=$(free_metrics_port)
  write_client() {
    local old; old=$(umask); umask 077
    printf '%s\n' "$T_KEY" >"$CONF/$name.key" || return 1
    {
      echo "# WatTunnel - Iran (client). Created by wattun-manager."
      echo "mode: client"
      echo "key-file: $CONF/$name.key"
      echo "carrier: $T_CARRIER"
      echo "peer: $T_PEER"
      [ -n "$T_PATH" ] && echo "path: $T_PATH"
      [ -n "$T_SNI" ] && { echo "sni: $T_SNI"; echo "host: $T_SNI"; }
      [ -n "$T_FAKESNI" ] && { echo "fake-sni: $T_FAKESNI"; [ -n "$T_FAKEMODE" ] && echo "fake-mode: $T_FAKEMODE"; [ "$T_FAKEMODE" = ttl ] && [ -n "$T_FAKETTL" ] && echo "fake-ttl: $T_FAKETTL"; }
      [ -n "$T_POOLROT" ] && [ "$T_POOLROT" != 0 ] && [ "$T_POOLROT" != off ] && echo "pool-rotate: $T_POOLROT"
      [ -n "$T_POOLBYTES" ] && [ "$T_POOLBYTES" != 0 ] && [ "$T_POOLBYTES" != off ] && echo "pool-rotate-bytes: $T_POOLBYTES"
      if [ -n "$T_ECH" ]; then
        [ "$T_ECH" != off ] && echo "ech: $T_ECH"
        [ -n "$AT_EXTRA" ] && AT_EXTRA=$(printf '%s\n' "$AT_EXTRA" | grep -v '^ech:' || true)
      fi
      [ "$T_GOVERNOR" = true ] && echo "governor: true"
      [ -n "$T_DNSLISTEN" ] && [ "$T_DNSLISTEN" != off ] && echo "dns-listen: $T_DNSLISTEN"
      [ -n "$T_SRCIP" ] && [ "$T_SRCIP" != off ] && echo "src-ip: $T_SRCIP"
      [ -n "$T_ICMP" ] && [ "$T_ICMP" != echo ] && echo "icmp-type: $T_ICMP"
      [ "$T_REV" = 1 ] && echo "reverse: true"
      [ -n "$rport" ] && echo "listen: \":$rport\""
      [ -n "$AT_EXTRA" ] && printf '%s\n' "$AT_EXTRA"
      ech_cache_line "$name"
      [ -n "$bind" ] && [ "$bind" != 0.0.0.0 ] && echo "bind: $bind"
      [ -n "$mbps" ] && echo "max-mbps: $mbps"
      [ "$fec" = auto ] && echo "fec: auto"
      sessions_line
      conns_line
      mtu_line
      echo "metrics: 127.0.0.1:$m"
      maps_yaml_block
    } >"$CONF/$name.yml"
    umask "$old"
  }
  mkdir -p "$CONF"; chmod 700 "$CONF"
  sessions_check
  step "Writing key and config" write_client || return 1
  if [ -n "$AUTO_TOKEN" ]; then # kept so auto-test / auto-heal can test again later
    ( umask 077; printf '%s\n' "$AUTO_TOKEN" >"$CONF/$name.auto" ); chmod 600 "$CONF/$name.auto"
  fi
  start_unit "$name" || return 1
  [ "$T_CARRIER" = icmp ] && [ "$T_REV" = 1 ] && kreply_offer
  [ -n "$rport" ] && fw_open "$rport/tcp" # before the link check: Kharej cannot connect until it is open
  for ((i=0; i<${#MAPS[@]}; i++)); do new_pub+=("$(spec_L "${MAPS[$i]}")/$(spec_P "${MAPS[$i]}")"); done
  echo
  if wait_link "$name" 25; then
    celebrate "CONNECTED (RTT ${LINK_RTT} ms)"
    echo
    say "  ${BOLD}Users can now connect to this server${RST}:"
    conn_diagram "$T_CARRIER" "${MAPS[@]}"
  else
    linkok=0
    err "Not connected yet. Running a diagnosis..."
    test_tunnel "$name"
  fi
  echo
  fw_open "${new_pub[*]}"
  if ! systemctl is-enabled -q "$HEAL_UNIT.timer" 2>/dev/null; then
    heal_enable >/dev/null && ok "Auto-heal enabled (turn off: $SELF → s settings → h)"
  fi
  echo
  hint "Manage this tunnel any time: $SELF"
  if [ "$linkok" = 1 ] && [ "$T_REV" != 1 ] && is_pool "$T_CARRIER" && [ "$(uname -s)" = Linux ] && [ -z "$T_FAKESNI$T_POOLROT$T_POOLBYTES" ]; then
    hint "If a censor starts blocking this tunnel: tunnel page -> o (advanced settings) -> resilience (fake-SNI, pool-rotate)."
  fi
  if [ "$NONINTERACTIVE" = 1 ]; then
    printf 'LINK=%s\nTUNNEL=%s\n' "$([ "$linkok" = 1 ] && echo up || echo down)" "$name"
    [ "$linkok" = 1 ] || return 1
  fi
  return 0
}

SESS_USE=''
sessions_check() { # --sessions N: only when the installed wattun knows the key (>= 2.3.0; older engines reject unknown keys)
  SESS_USE=''
  [ -n "$NI_SESSIONS" ] || return 0
  if ver_ge "$(bin_ver || true)" 2.3.0 2>/dev/null; then SESS_USE=$NI_SESSIONS
  else warn "--sessions $NI_SESSIONS ignored: it needs wattun 2.3.0 or newer (this is ${VER:-unknown}); run: $SELF update"; fi
  return 0
}
sessions_line() { # the engine refuses sessions with icmp, bonded carriers, reverse, or more than 16
  if [ -z "$SESS_USE" ] && [ "$T_REV" != 1 ] && ver_ge "$(bin_ver || true)" 2.3.0 2>/dev/null; then
    # default for pool carriers: 4 sessions (field, Iran-CF-Kharej wss: 1 = 19, 4 = 52 MB/s down at 91% of 2 cores)
    case "$T_CARRIER" in tcp|tls|ws|wss|h2|h2c|grpc) SESS_USE=4 ;; esac
  fi
  [ -n "$SESS_USE" ] || return 0
  case "$T_CARRIER" in icmp|*,*) warn "--sessions ignored: not supported with carrier '$T_CARRIER'" >&2; return 0 ;; esac
  [ "$T_REV" = 1 ] && { warn "--sessions ignored: not supported in reverse mode" >&2; return 0; }
  echo "sessions: $(( SESS_USE > 16 ? 16 : SESS_USE ))"; return 0
}
conns_line() {
  [ -n "${NI_CONNS:-}" ] && echo "conns: $NI_CONNS"
  return 0
}
mtu_line() {
  [ -n "${NI_MTU:-}" ] && echo "mtu: $NI_MTU"
  return 0
}

# ======================================================================================
#  Auto carrier: one token, Iran tests every connection type and keeps the best
#    Kharej: unit NAME (all carriers at once) + NAME-r (the reverse side, written by a watcher as soon as Iran's IP
#    is known). Iran: auto_test runs one throw-away client per variant and uses the built-in /speedtest.
#    Token field 9 (the plan): "d=udp:4443,tcp:4443,...;r=tcp:24431,..." (see make_token).
# ======================================================================================
AUTO_RUN=${WAT_AUTO_RUN:-/run/$WAT_PREFIX-auto}
AUTO_RPLAN='tcp:24431,tls:24432,ws:24433,wss:24434,h2:24435,h2c:24436,grpc:24437'
AUTO_D=''; AUTO_NOTE=''; AUTO_ADDR=''
plan_part() { # plan d|r -> "udp:4443,tcp:4443,..."
  local x
  for x in ${1//;/ }; do [ "${x%%=*}" = "$2" ] && { echo "${x#*=}"; return 0; }; done
  return 0
}
plan_port() { # list carrier -> port
  local x
  for x in ${1//,/ }; do [ "${x%%:*}" = "$2" ] && { echo "${x#*:}"; return 0; }; done
  return 0
}
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; } # $1 >= $2
bin_ver_ok() { # min-version -> 1 when the installed wattun is new enough (empty output = not ok)
  ver_ge "$(bin_ver || true)" "$1" 2>/dev/null && echo 1
  return 0
}
is_auto_kharej() { # name : does NAME.token carry carrier "auto"?
  local raw
  [ -f "$CONF/$1.token" ] || return 1
  raw=$(sed 's/^wat1://' "$CONF/$1.token" | base64 -d 2>/dev/null) || return 1
  [ "${raw%%|*}" = auto ]
}
companion_of() { # name -> parent name when NAME is an auto reverse companion (NAME-r)
  local p=${1%-r}
  [ "$p" != "$1" ] && [ -f "$CONF/$p.yml" ] && is_auto_kharej "$p" && echo "$p"
  return 0
}
carrier_label() { # name -> short carrier text for lists
  if is_auto_kharej "$1"; then echo auto; elif [ -n "$(companion_of "$1")" ]; then echo auto-r; else cfg "$1" carrier; fi
}

# ---- Kharej side ----
auto_pick_ports() { # -> AUTO_D "udp:4443,tcp:4443,..." and AUTO_NOTE ; rc 1 when no free port is left
  local c want fb p proto pick used=' ' cdnok=' 443 2053 2083 2087 2096 8443 ' list=''
  AUTO_NOTE=''
  for c in udp tcp tls ws wss h2 h2c grpc; do
    case "$c" in
      wss) want=2053; fb="2096 8443 443 2083 2087" ;;
      grpc) want=2083; fb="2087 2096 8443 2053 443" ;;
      h2) want=2087; fb="2096 8443 2083 2053 443" ;;
      ws) want=2052; fb="2082 2086 2095 8080 8880" ;;
      h2c) want=2082; fb="2086 2095 8080 8880 2052" ;;
      tls) want=8443; fb="8444 8445 9443 2096" ;;
      *) want=4443; fb="4444 4445 9444 9445" ;;
    esac
    proto=tcp; [ "$c" = udp ] && proto=udp
    pick=''
    for p in $want $fb; do
      case "$used" in *" $proto$p "*) continue ;; esac
      listen_blocked "$proto" "$p" && continue
      pick=$p; break
    done
    if [ -z "$pick" ]; then # every usual port is taken (often by an x-ui/v2ray panel): any free high port will do
      for p in $(seq 24440 24999); do
        case "$used" in *" $proto$p "*) continue ;; esac
        listen_blocked "$proto" "$p" && continue
        pick=$p; break
      done
    fi
    [ -n "$pick" ] || { AUTO_FAIL="$c ($proto $want $fb)"; return 1; }
    used+="$proto$pick "
    list="${list:+$list,}$c:$pick"
    if [ "$pick" != "$want" ]; then
      AUTO_NOTE+="  $c: port $want is busy, using $pick."
      case "$c" in
        wss|grpc|h2) case "$cdnok" in *" $pick "*) ;; *) AUTO_NOTE+=" (not a Cloudflare port: the CDN test of $c may not work)" ;; esac ;;
        ws|h2c) case " 80 8080 8880 2052 2082 2086 2095 " in *" $pick "*) ;; *) AUTO_NOTE+=" (not a Cloudflare port: the CDN test of $c may not work)" ;; esac ;;
      esac
      AUTO_NOTE+=$'\n'
    fi
  done
  AUTO_D=$list
}
ask_public_addr() { # -> AUTO_ADDR ; rc 1 when cancelled
  local addr
  if [ -n "$NI_ADDR" ]; then addr=$NI_ADDR
  else spin_start "Detecting this server's public IP"; addr=$(public_ip); spin_stop; fi
  if [ -z "$NI_ADDR" ] && [ -n "$addr" ] && ip_is_private "$addr"; then
    warn "$addr looks like a private address; Iran cannot reach it."
    confirm "Use $addr anyway? (n = enter the public IP yourself)" n || addr=''
    [ -z "$addr" ] && hint "Behind NAT or a cloud 1:1 mapping? Enter the public IP shown in your provider's panel."
  elif [ -z "$addr" ]; then
    warn "Could not detect this server's public IP."
    [ "$NONINTERACTIVE" = 1 ] && hint "Give it with --addr HOST"
  fi
  if [ -z "$addr" ]; then
    ask_ok "Public IP or domain of this server" "" v_host || return 1; addr=$REPLY_V
  else
    ok "Public address: $addr"
  fi
  AUTO_ADDR=$addr
}
start_watcher() { # name : transient unit that waits for Iran's first connection, then writes NAME-r
  local u="${WAT_PREFIX}-autowatch-$1" m=$MGR renv
  mapfile -t renv < <(run_env_args)
  [ -x "$m" ] || m=$(readlink -f "$0")
  systemctl stop "$u.service" >/dev/null 2>&1; systemctl reset-failed "$u.service" >/dev/null 2>&1
  systemd-run --quiet --collect --unit "$u" --property=RuntimeMaxSec=3600 "${renv[@]}" \
    "$m" auto-watch "$1" >/dev/null 2>&1
}
wizard_kharej_auto() { # suggested-name : called from wizard_kharej when the carrier is "auto"
  local name=$1 n=1 cdn='' key m allow plan c p cars='' fwl='' ver line
  ver=$(bin_ver)
  if ! ver_ge "${ver:-0}" 2.1.0; then
    err "Auto needs wattun 2.1.0 or newer on this server (found ${ver:-none})."; hint "Update first: $SELF update"; return 1
  fi
  command -v systemd-run >/dev/null 2>&1 || { err "Auto needs systemd (systemd-run) on this server."; return 1; }
  if [ -n "$NI_NAME" ]; then
    { [ -e "$CONF/$name.yml" ] || [ -e "$CONF/$name-r.yml" ]; } && { err "A tunnel named '$name' (or '$name-r') already exists."; return 1; }
  fi
  while { [ -e "$CONF/$name.yml" ] || [ -e "$CONF/$name-r.yml" ]; } && [ "$n" -lt 99 ]; do n=$((n+1)); name="kharej-$n"; done
  echo
  say "  ${BOLD}Auto${RST}: Iran tests every connection type against this server and keeps the best one."
  hint "This server opens one port per carrier. A second unit, ${name}-r, is added by itself once Iran connects."
  echo
  hint "Cloudflare-proxied domain for the CDN tests (optional; used only to test wss/grpc through Cloudflare."
  hint "Point it at this server with the orange cloud on, SSL mode Full). Press Enter to skip."
  ask_ok "CDN domain (optional)" "$NI_CDN" v_domain_opt || return 1; cdn=$REPLY_V
  auto_pick_ports || { err "Could not find a free port for $AUTO_FAIL on this server."; hint "Check what listens there: ss -ltnup"; return 1; }

  MAPS=(); PE_ROLE=Kharej; PE_TUNNEL=$name; PE_ALLOW=(); PE_OWNED=(); PE_MSG=''
  allow='' # all ports allowed (unless --ports); edit later from the tunnel menu
  if [ -n "$NI_PORTS" ]; then ni_kharej_ports || return 1; allow=$(maps_allow_str); fi

  ask_public_addr || return 1
  plan="d=$AUTO_D;r=$AUTO_RPLAN"

  page "New tunnel" "review"
  say "  ${BOLD}Ready to create${RST}"
  summary_line "Name" "$name  (Kharej, auto: all carriers at once)"
  line=''; for c in ${AUTO_D//,/ }; do line="$line ${c%%:*} ${c##*:} ·"; done
  summary_line "Ports" "icmp ·${line% ·}"
  [ -n "$AUTO_NOTE" ] && printf '%s' "$AUTO_NOTE" | sed "s/^/    $GRY/; s/\$/$RST/"
  summary_line "Address" "$AUTO_ADDR"
  summary_line "CDN domain" "${cdn:-none (CDN tests skipped)}"
  summary_line "Allowed ports" "${allow:-any (no allow list: everything on 127.0.0.1 of this server is reachable through the tunnel)}"
  echo
  confirm "Create this tunnel?" y || { warn "Nothing was created."; return 1; }
  echo

  key=$(new_key); m=$(free_metrics_port)
  for c in ${AUTO_D//,/ }; do cars="$cars+${c%%:*}"; done
  write_auto_server() {
    local old; old=$(umask); umask 077
    printf '%s\n' "$key" >"$CONF/$name.key" || return 1
    {
      echo "# WatTunnel - Kharej (server), auto: every carrier at once. Created by wattun-manager."
      echo "mode: server"
      echo "key-file: $CONF/$name.key"
      echo "carrier: icmp$cars"
      for c in ${AUTO_D//,/ }; do echo "listen-${c%%:*}: \":${c##*:}\""; done
      echo "path: /wat"
      echo "metrics: 127.0.0.1:$m"
      maps_yaml_block
    } >"$CONF/$name.yml"
    make_token auto "$AUTO_ADDR" "$key" /wat "$cdn" "" "$allow" "" "$plan" >"$CONF/$name.token"
    umask "$old"
  }
  mkdir -p "$CONF"; chmod 700 "$CONF"
  step "Writing key, config and token" write_auto_server || return 1
  start_unit "$name" || return 1
  for c in ${AUTO_D//,/ }; do
    p=${c##*:}; fwl="$fwl $p/$([ "${c%%:*}" = udp ] && echo udp || echo tcp)"
  done
  fw_open "${fwl# }"
  hint "ICMP: this server must answer ping. Do not block ICMP in the cloud firewall."
  start_watcher "$name" && ok "Watching for Iran (creates ${name}-r by itself, no action needed)" \
    || warn "Could not start the watcher. After Iran connects run: $SELF auto-ip $name IRAN_IP"

  echo
  celebrate "Kharej auto tunnel '$name' is ready"
  echo
  say "  ${BOLD}Your connection token${RST} (copy the whole line):"
  echo
  printf '%s%s%s\n\n' "$BOLD$YEL" "$(cat "$CONF/$name.token")" "$RST"
  step_diagram 2
  echo
  say "  ${BOLD}Now paste this token on Iran.${RST} It tests every connection type by itself (about 2-3 minutes)."
  hint "Show it again any time: $SELF token $name"
  hint "If the reverse tests fail because this server never learned Iran's IP: $SELF auto-ip $name IRAN_IP"
  warn "The token contains the key — treat it like a password: anyone who sees it can use the tunnel. Share it only over a private channel."
  [ "$NONINTERACTIVE" = 1 ] && printf 'TUNNEL=%s\nTOKEN=%s\n' "$name" "$(cat "$CONF/$name.token")"
  return 0
}

# Reverse companion: written once Iran's IP is known. Only the first Iran client matters; with a CDN domain the
# client list shows Cloudflare's IP for ws/wss/h2/h2c/grpc, so only icmp/udp/tcp/tls clients are trusted then.
companion_create() { # name ip
  local n=$1 ip=$2 r="$1-r" f="$CONF/$1-r.yml" m rp c p cars=icmp old tmp
  if [ -f "$f" ] && [ "$(cfg "$r" peer-icmp)" = "$ip" ]; then return 0; fi
  if ! { [ -f "$CONF/$n.token" ] && read_token "$(cat "$CONF/$n.token")" && [ -n "$T_AUTO" ]; }; then
    err "No auto token for '$n'."; return 1
  fi
  rp=$(plan_part "$T_AUTO" r)
  m=$(cfg "$r" metrics); m=${m##*:}; [ -n "$m" ] || m=$(free_metrics_port)
  for c in ${rp//,/ }; do cars="$cars+${c%%:*}"; done
  load_maps "$n"
  old=$(umask); umask 077
  tmp=$(mktemp "$CONF/.tmp.XXXXXX") || { umask "$old"; return 1; }
  {
    echo "# WatTunnel - Kharej reverse side of auto tunnel '$n' (Iran $ip). Written by wattun-manager."
    echo "mode: server"
    echo "key-file: $CONF/$n.key"
    echo "carrier: $cars"
    echo "reverse: true"
    echo "peer-icmp: $ip"
    for c in ${rp//,/ }; do echo "peer-${c%%:*}: $ip:${c##*:}"; done
    echo "path: ${T_PATH:-/wat}"
    echo "metrics: 127.0.0.1:$m"
    maps_yaml_block
  } >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$f"; umask "$old"
  ensure_template >/dev/null
  systemctl enable "${WAT_PREFIX}@$r" >/dev/null 2>&1
  systemctl restart "${WAT_PREFIX}@$r" >/dev/null 2>&1
  logger -t wattun-auto "learned Iran IP $ip for $n; started ${WAT_PREFIX}@$r (reverse side)"
  return 0
}
auto_watch() { # name : run by systemd-run; poll /stats clients, write the companion on the first usable Iran client
  local n=$1 s cl ip='' cdn='' obj car
  [ -f "$CONF/$n.token" ] && read_token "$(cat "$CONF/$n.token")" && cdn=$T_SNI
  logger -t wattun-auto "watching $n for Iran's first connection"
  while [ -f "$CONF/$n.yml" ]; do
    s=$(stats "$n")
    cl=$(grep -o '"clients": *\[[^]]*\]' <<<"$s")
    ip=''
    while IFS= read -r obj; do
      [ -n "$obj" ] || continue
      car=$(grep -o '"carrier": *"[^"]*"' <<<"$obj" | head -1 | cut -d'"' -f4)
      if [ -n "$cdn" ]; then case "$car" in icmp|udp|tcp|tls) ;; *) continue ;; esac; fi
      ip=$(grep -o '"ip": *"[^"]*"' <<<"$obj" | head -1 | cut -d'"' -f4)
      ipv4_ok "$ip" && break
      ip=''
    done < <(sed 's/},[[:space:]]*{/}\n{/g' <<<"$cl")
    if [ -n "$ip" ]; then companion_create "$n" "$ip"; return $?; fi
    sleep 2
  done
  return 0
}
auto_ip() { # name ip : the manual fallback of auto_watch
  local n=$1 ip=${2:-}
  is_auto_kharej "$n" || { err "'$n' is not an auto Kharej tunnel."; return 1; }
  ipv4_ok "$ip" || { err "Usage: $SELF auto-ip $n IRAN_IPV4"; return 1; }
  companion_create "$n" "$ip" || return 1
  systemctl stop "${WAT_PREFIX}-autowatch-$n.service" >/dev/null 2>&1
  ok "Reverse side ${n}-r is set for Iran $ip. Run the test again on Iran."
}

# ---- Iran side: test runner ----
AV_LABEL=(); AV_CAR=(); AV_KIND=(); AV_PEER=(); AV_PORT=(); AV_SNI=(); AV_FP=(); AV_ECH=(); AV_FRAG=()
AV_FS=(); AV_FM=() # fake-sni / fake-mode per variant (anti-censor matrix, 2.10.2)
AR_OK=(); AR_DOWN=(); AR_UP=(); AR_RTT=(); AR_WHY=()
AT_QUIET=0; AT_MB=2; AT_DIR=''; AT_PID=''; AT_FW=''; AT_ADDR=''; AT_SKIP=''; AT_DLINK=0; AT_SECS=0
AT_RANK=(); AT_SEL=(); AT_SEL_LABEL=''; AT_SEL_KEY=''; AT_EXTRA=''; AUTO_TOKEN=''
av_add() { # label carrier kind(d|c|r) peer port sni [fp ech tls-frag [fake-sni fake-mode]] (the last three: CDN variants, wattun >= 2.2.0; last two: matrix)
  AV_LABEL+=("$1"); AV_CAR+=("$2"); AV_KIND+=("$3"); AV_PEER+=("$4"); AV_PORT+=("$5"); AV_SNI+=("$6")
  AV_FP+=("${7:-}"); AV_ECH+=("${8:-}"); AV_FRAG+=("${9:-}")
  AV_FS+=("${10:-}"); AV_FM+=("${11:-}")
}
av_key() { echo "${AV_CAR[$1]}/${AV_KIND[$1]}"; }
auto_variants() { # T_* from the auto token -> AV_*
  local d r c p
  AV_LABEL=(); AV_CAR=(); AV_KIND=(); AV_PEER=(); AV_PORT=(); AV_SNI=(); AV_FP=(); AV_ECH=(); AV_FRAG=()
  AV_FS=(); AV_FM=()
  AT_ADDR=$T_PEER
  d=$(plan_part "$T_AUTO" d); r=$(plan_part "$T_AUTO" r)
  av_add icmp icmp d "$AT_ADDR" '' ''
  for c in udp tcp tls wss h2 grpc ws h2c; do
    p=$(plan_port "$d" "$c"); [ -n "$p" ] && av_add "$c" "$c" d "$AT_ADDR:$p" '' ''
  done
  if [ -n "$T_SNI" ]; then
    for c in wss grpc; do # h2 never connects through Cloudflare
      p=$(plan_port "$d" "$c"); [ -n "$p" ] || continue
      if cdn_ok; then # variant (a): chrome+ech on the best Cloudflare edges (CS_EDGES, filled by auto_test); b-d: cdn_auto_extras
        if [ "${#CS_EDGES[@]}" -gt 0 ]; then av_add "$c · chrome+ech · ${#CS_EDGES[@]} edges" "$c" c "$(cdn_peer_list "$p")" '' "$T_SNI" chrome auto
        else av_add "$c · chrome+ech" "$c" c "$T_SNI:$p" '' "$T_SNI" chrome auto; fi
      else av_add "$c via CDN" "$c" c "$T_SNI:$p" '' "$T_SNI"; fi
    done
  fi
  av_add "icmp reverse" icmp r "$AT_ADDR" '' ''
  for c in tcp tls ws wss h2 h2c grpc; do
    p=$(plan_port "$r" "$c"); [ -n "$p" ] && av_add "$c reverse" "$c" r "$AT_ADDR:$p" "$p" ''
  done
  return 0
}
at_free_port() { local p=${1:-20500}; while [ "$p" -lt 20700 ] && port_busy "$p" tcp; do p=$((p+1)); done; echo "$p"; }
at_alive() { [ "$(jget "$(curl -fs --noproxy '*' --max-time 2 "http://127.0.0.1:$1/stats" 2>/dev/null)" alive)" = true ]; }
at_wait() { # metrics-port seconds : wait for the link
  local end=$((SECONDS + $2))
  while :; do
    at_alive "$1" && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    kill -0 "$AT_PID" 2>/dev/null || return 1
    sleep 0.5
  done
}
AT_PIDS=(); AT_MPS=()
at_kill() { # the single probe client and every client of the reverse batch
  local p
  if [ -n "$AT_PID" ]; then kill "$AT_PID" 2>/dev/null; { wait "$AT_PID"; } 2>/dev/null; AT_PID=''; fi
  for p in "${AT_PIDS[@]}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "${AT_PIDS[@]}"; do [ -n "$p" ] && { wait "$p"; } 2>/dev/null; done
  AT_PIDS=(); AT_MPS=()
  return 0
}
at_fw_open() { # port/tcp : temporary rule for a reverse test port (firewalld: runtime only)
  local fw p=$1; fw=$(fw_kind); [ -n "$fw" ] || return 0
  [ "$SANDBOX" = 1 ] && hint "Sandbox: test port $p is opened in $fw if not already allowed, and closed when the test ends."
  if [ "$fw" = ufw ]; then
    ufw status 2>/dev/null | grep -q "^$p[[:space:]]" && return 0
    ufw allow "$p" >/dev/null 2>&1 && AT_FW="$AT_FW $p"
  else
    firewall-cmd -q --query-port="$p" 2>/dev/null && return 0
    firewall-cmd -q --add-port="$p" 2>/dev/null && AT_FW="$AT_FW $p"
  fi
  return 0
}
at_fw_close() {
  local fw p; fw=$(fw_kind); [ -n "$AT_FW" ] && [ -n "$fw" ] || { AT_FW=''; return 0; }
  for p in $AT_FW; do
    if [ "$fw" = ufw ]; then ufw delete allow "$p" >/dev/null 2>&1; else firewall-cmd -q --remove-port="$p" 2>/dev/null; fi
  done
  AT_FW=''; return 0
}
at_cleanup() {
  local p
  at_kill; at_fw_close
  for p in ${CS_PIDS[@]+"${CS_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  CS_PIDS=(); [ -n "${CS_DIR:-}" ] && rm -rf "$CS_DIR"; CS_DIR=''
  [ -n "$AT_DIR" ] && rm -rf "$AT_DIR"
  AT_DIR=''; return 0
}
at_start() { # i metrics-port : start a throw-away client for variant i (no -map: nothing is published)
  local i=$1 mp=$2 car=${AV_CAR[$1]} a
  a=(-mode client -carrier "$car" -key-file "$AT_DIR/key" -peer "${AV_PEER[$i]}" -metrics "127.0.0.1:$mp")
  case "$car" in ws|wss|h2|h2c|grpc) a+=(-path "${T_PATH:-/wat}") ;; esac
  if [ "$car" = icmp ] && [ -n "$T_ICMP" ]; then a+=(-icmp-type "$T_ICMP"); fi
  if [ -n "${AV_SNI[$i]}" ]; then a+=(-sni "${AV_SNI[$i]}" -host "${AV_SNI[$i]}"); fi
  if [ -n "${AV_FP[$i]:-}" ]; then a+=(-fp "${AV_FP[$i]}"); fi
  if [ -n "${AV_ECH[$i]:-}" ]; then a+=(-ech "${AV_ECH[$i]}"); fi
  if [ -n "${AV_FRAG[$i]:-}" ] && [ "${AV_FRAG[$i]}" != 0 ]; then a+=(-tls-frag "${AV_FRAG[$i]}"); fi
  if [ -n "${AV_FS[$i]:-}" ]; then # anti-censor matrix variant (2.10.2): desync on the throwaway client
    a+=(-fake-sni "${AV_FS[$i]}")
    [ -n "${AV_FM[$i]:-}" ] && a+=(-fake-mode "${AV_FM[$i]}")
  fi
  # the engine refuses a client without any -map: a loopback-only dummy mapping publishes nothing
  a+=(-map "$(at_free_port $((mp + 1))):1@127.0.0.1")
  if [ "${AV_KIND[$i]}" = r ]; then
    a+=(-reverse)
    if is_pool "$car"; then a+=(-listen ":${AV_PORT[$i]}"); fi
  fi
  timeout -k 2 "$AT_LIM" "$BIN" "${a[@]}" >"$AT_DIR/client.$i.log" 2>&1 &
  AT_PID=$!
}
at_curl() { curl -fs --noproxy '*' --max-time $((AT_MB * 2 > 20 ? AT_MB * 2 : 20)) "http://127.0.0.1:$1/speedtest?dir=$2&mb=$AT_MB" 2>/dev/null; }
at_probe() { # i wait-seconds : fills AR_*[i]
  local i=$1 w=${2:-8} mp r
  AR_OK[$i]=0; AR_DOWN[$i]=0; AR_UP[$i]=0; AR_RTT[$i]=0; AR_WHY[$i]=''
  case " $AT_SKIP " in *" $(av_key "$i") "*) AR_WHY[$i]='in use by this tunnel'; return 0 ;; esac
  if [ "${AV_KIND[$i]}" = r ] && is_pool "${AV_CAR[$i]}"; then
    if listen_blocked tcp "${AV_PORT[$i]}"; then AR_WHY[$i]="port ${AV_PORT[$i]}/tcp is busy here"; return 0; fi
    at_fw_open "${AV_PORT[$i]}/tcp"
  fi
  mp=$(at_free_port)
  AT_LIM=$((w + 55 + AT_MB * 4))
  at_start "$i" "$mp"
  if ! at_wait "$mp" "$w"; then
    AR_WHY[$i]="no link in $w s"
  else
    [ "${AV_KIND[$i]}" = r ] || AT_DLINK=$((AT_DLINK+1))
    at_measure "$i" "$mp"
  fi
  at_kill; at_fw_close
  return 0
}
at_measure() { # i metrics-port : speed test on a running client, fills AR_*[i]
  local i=$1 mp=$2 r
  r=$(at_curl "$mp" down)
  if [ "$(jget "$r" ok)" = true ]; then
    AR_DOWN[$i]=$(jget "$r" mb_per_s)
    r=$(at_curl "$mp" up)
    if [ "$(jget "$r" ok)" = true ]; then
      AR_UP[$i]=$(jget "$r" mb_per_s)
      AR_RTT[$i]=$(jget "$(curl -fs --noproxy '*' --max-time 2 "http://127.0.0.1:$mp/stats" 2>/dev/null)" srtt_ms)
      : "${AR_DOWN[$i]:=0}" "${AR_UP[$i]:=0}" "${AR_RTT[$i]:=0}"
      AR_OK[$i]=1
    fi
  fi
  [ "${AR_OK[$i]}" = 1 ] || AR_WHY[$i]='speed test failed/stalled'
  return 0
}
# Reverse pool carriers: Kharej's NAME-r companion starts dialing Iran's r-ports as soon as it knows Iran's IP, and its
# redial backoff grows while nothing listens. So all reverse clients (and their temporary firewall rules) are started at
# once, we wait for all of them together, then the speed tests run one at a time on the already-running clients.
at_pool_batch() { # indices... : probe every reverse pool variant given
  local i mp base=20500 end pend started=() up=()
  for i in "$@"; do
    AR_OK[$i]=0; AR_DOWN[$i]=0; AR_UP[$i]=0; AR_RTT[$i]=0; AR_WHY[$i]=''
    case " $AT_SKIP " in *" $(av_key "$i") "*) AR_WHY[$i]='in use by this tunnel'; continue ;; esac
    if listen_blocked tcp "${AV_PORT[$i]}"; then AR_WHY[$i]="port ${AV_PORT[$i]}/tcp is busy here"; continue; fi
    at_fw_open "${AV_PORT[$i]}/tcp"
  done
  AT_LIM=$((45 + $# * (50 + AT_MB * 4) + 30))
  for i in "$@"; do
    [ -z "${AR_WHY[$i]}" ] || continue
    mp=$(at_free_port "$base"); base=$((mp + 3))
    at_start "$i" "$mp"
    AT_PIDS[$i]=$AT_PID; AT_PID=''; AT_MPS[$i]=$mp
    started+=("$i")
  done
  if [ "${#started[@]}" -gt 0 ]; then
    [ "$AT_QUIET" = 1 ] || at_busy "reverse links (all at once, up to 45 s)"
    end=$((SECONDS + 45))
    while :; do
      pend=0
      for i in "${started[@]}"; do
        [ "${up[$i]:-0}" = 1 ] && continue
        if at_alive "${AT_MPS[$i]}"; then up[$i]=1
        elif kill -0 "${AT_PIDS[$i]}" 2>/dev/null; then pend=1; fi
      done
      [ "$pend" = 0 ] && break
      [ "$SECONDS" -ge "$end" ] && break
      sleep 0.5
    done
    [ "$AT_QUIET" = 1 ] || at_idle
  fi
  for i in "$@"; do
    if [ -z "${AR_WHY[$i]}" ]; then
      if [ "${up[$i]:-0}" = 1 ]; then
        [ "$AT_QUIET" = 1 ] || at_busy "${AV_LABEL[$i]}"
        at_measure "$i" "${AT_MPS[$i]}"
        [ "$AT_QUIET" = 1 ] || at_idle
      else AR_WHY[$i]='no link in 45 s'; fi
    fi
    [ "$AT_QUIET" = 1 ] || at_print "$i"
  done
  at_kill; at_fw_close
  return 0
}
at_busy() { if [ "$ANIM" = 1 ]; then spin_start "Testing $1"; elif [ "$NONINTERACTIVE" = 1 ]; then printf '  testing %s ...\n' "$1"; elif [ "$IS_TTY" = 1 ]; then printf '  testing %s ...' "$1"; fi; return 0; }
at_idle() { if [ "$ANIM" = 1 ]; then spin_stop; elif [ "$IS_TTY" = 1 ]; then printf '\r\e[K'; fi; return 0; }
at_print() {
  local i=$1
  if [ "${AR_OK[$i]}" = 1 ]; then
    printf '  %s✔%s %-28s %s%6.1f%s MB/s down  %6.1f MB/s up  %4.0f ms\n' "$GRN" "$RST" "${AV_LABEL[$i]}" "$BOLD" "${AR_DOWN[$i]:-0}" "$RST" "${AR_UP[$i]:-0}" "${AR_RTT[$i]:-0}"
  else
    printf '  %s✘%s %-28s %s%s%s\n' "$RED" "$RST" "${AV_LABEL[$i]}" "$GRY" "${AR_WHY[$i]}" "$RST"
  fi
}
AT_NOTE=''
auto_refine() { # AT_RANK from the 8 MB screening -> re-measure the top 3 at 20 MB (slow start dominates small transfers), re-rank
  local i k=0 top=() pool=() save=$AT_MB w ok d u r t0=$SECONDS; local -A sv=()
  [ "${#AT_RANK[@]}" -gt 0 ] || return 0
  for i in "${AT_RANK[@]}"; do [ "$k" -ge 3 ] && break; top+=("$i"); k=$((k+1)); sv[$i]="${AR_OK[$i]}|${AR_DOWN[$i]}|${AR_UP[$i]}|${AR_RTT[$i]}"; done
  at_prep || return 0
  AT_MB=20
  [ "$AT_QUIET" = 1 ] || { echo; say "  ${BOLD}Confirming the top ${#top[@]} with 20 MB each way${RST}"; }
  for i in "${top[@]}"; do
    if [ "${AV_KIND[$i]}" = r ] && is_pool "${AV_CAR[$i]}"; then pool+=("$i"); continue; fi
    w=8; [ "${AV_KIND[$i]}" = r ] && [ "${AV_CAR[$i]}" = icmp ] && w=30
    [ "$AT_QUIET" = 1 ] || at_busy "${AV_LABEL[$i]}"
    at_probe "$i" "$w"
    [ "$AT_QUIET" = 1 ] || { at_idle; at_print "$i"; }
  done
  [ "${#pool[@]}" -gt 0 ] && at_pool_batch "${pool[@]}"
  at_cleanup
  AT_MB=$save
  for i in "${top[@]}"; do # a variant that fails the longer test keeps its screening numbers
    [ "${AR_OK[$i]}" = 1 ] && continue
    IFS='|' read -r ok d u r <<<"${sv[$i]}"; AR_OK[$i]=$ok; AR_DOWN[$i]=$d; AR_UP[$i]=$u; AR_RTT[$i]=$r
  done
  AT_SECS=$((AT_SECS + SECONDS - t0))
  AT_NOTE="Screened with $AT_MB MB each way; the top ${#top[@]} re-measured with 20 MB."
  at_rank
  return 0
}
auto_test() { # needs read_token of an auto token (T_*), AT_QUIET, AT_MB, AT_SKIP ; fills AR_*, AT_SECS
  local i n t0=$SECONDS kind last='' w pool=() j sc
  at_prep || return 1
  AR_OK=(); AR_DOWN=(); AR_UP=(); AR_RTT=(); AR_WHY=()
  CS_EDGES=(); CS_TOTAL=0; CS_RAN=0
  if [ -n "$T_SNI" ] && cdn_ok; then # one scan for all CDN carriers; its summary line is printed in the CDN section
    j=''; sc=wss; for i in wss grpc; do j=$(plan_port "$(plan_part "$T_AUTO" d)" "$i"); [ -n "$j" ] && { sc=$i; break; }; done
    if [ -n "$j" ]; then
      [ "$AT_QUIET" = 1 ] || at_busy "Cloudflare edges"
      CS_QUIET=1; cdn_scan "$T_SNI" "$j" "${T_PATH:-/wat}" "$sc"
      [ "$AT_QUIET" = 1 ] || at_idle
    fi
  fi
  auto_variants
  n=${#AV_LABEL[@]}; AT_DLINK=0
  for ((i=0; i<n; i++)); do
    kind=${AV_KIND[$i]}
    if [ "$kind" != "$last" ] && [ "$AT_QUIET" != 1 ]; then
      case "$kind" in
        d) say "  ${BOLD}Direct connections${RST}" ;;
        c) echo; say "  ${BOLD}Through the CDN${RST} ($T_SNI)"; [ "$CS_RAN" = 1 ] && cdn_scan_say ;;
        r) echo; say "  ${BOLD}Reverse${RST} (Kharej connects out to this server)" ;;
      esac
    fi
    last=$kind
    if [ "$kind" = r ] && is_pool "${AV_CAR[$i]}"; then
      pool=(); for ((j=i; j<n; j++)); do [ "${AV_KIND[$j]}" = r ] && is_pool "${AV_CAR[$j]}" && pool+=("$j"); done
      at_pool_batch "${pool[@]}"
      break
    fi
    w=8; [ "$kind" = r ] && [ "${AV_CAR[$i]}" = icmp ] && w=30 # Kharej's companion needs a few seconds to start
    [ "$AT_QUIET" = 1 ] || at_busy "${AV_LABEL[$i]}"
    at_probe "$i" "$w"
    [ "$AT_QUIET" = 1 ] || { at_idle; at_print "$i"; }
    if [ "$kind" = c ] && cdn_ok && [ "${AV_KIND[$((i+1))]:-}" != c ]; then cdn_auto_extras; fi
  done
  at_cleanup
  AT_SECS=$((SECONDS-t0))
  return 0
}
at_rank() { # [policy] -> AT_RANK (working variants, best first: policy driven)
  local pol=${1:-${NI_POLICY:-}} i
  if [ -z "$pol" ] && [ -n "${AT_TUNNEL:-}" ] && [ -f "$CONF/$AT_TUNNEL.policy" ]; then
    pol=$(cat "$CONF/$AT_TUNNEL.policy" 2>/dev/null || echo speed)
  fi
  : "${pol:=speed}"
  AT_RANK=()
  case "$pol" in
    latency)
      while read -r _ _ i; do [ -n "$i" ] && AT_RANK+=("$i"); done < <(
        for ((i=0; i<${#AV_LABEL[@]}; i++)); do
          [ "${AR_OK[$i]}" = 1 ] && awk -v d="${AR_DOWN[$i]:-0}" -v u="${AR_UP[$i]:-0}" -v r="${AR_RTT[$i]:-0}" -v i="$i" 'BEGIN{printf "%.3f %.6f %d\n", r, d+u, i}'
        done | sort -k1,1g -k2,2gr)
      ;;
    direct)
      while read -r _ _ _ i; do [ -n "$i" ] && AT_RANK+=("$i"); done < <(
        for ((i=0; i<${#AV_LABEL[@]}; i++)); do
          local dir_p=0
          case "${AV_CAR[$i]}" in tcp|tls|udp|icmp) [ "${AV_KIND[$i]}" = d ] && dir_p=1 ;; esac
          [ "${AR_OK[$i]}" = 1 ] && awk -v dp="$dir_p" -v d="${AR_DOWN[$i]:-0}" -v u="${AR_UP[$i]:-0}" -v r="${AR_RTT[$i]:-0}" -v i="$i" 'BEGIN{printf "%d %.6f %.3f %d\n", dp, d+u, r, i}'
        done | sort -k1,1nr -k2,2gr -k3,3g)
      ;;
    bond|speed|*)
      while read -r _ _ i; do [ -n "$i" ] && AT_RANK+=("$i"); done < <(
        for ((i=0; i<${#AV_LABEL[@]}; i++)); do
          [ "${AR_OK[$i]}" = 1 ] && awk -v d="${AR_DOWN[$i]:-0}" -v u="${AR_UP[$i]:-0}" -v r="${AR_RTT[$i]:-0}" -v i="$i" 'BEGIN{printf "%.6f %.3f %d\n", d+u, r, i}'
        done | sort -k1,1gr -k2,2g)
      ;;
  esac
}
at_table() {
  local i k=0
  echo
  printf '  %s%3s  %-28s %12s %12s %7s%s\n' "$GRY" '#' variant down up rtt "$RST"
  for i in "${AT_RANK[@]}"; do
    k=$((k+1))
    printf '  %s%3s%s  %-28s %7.1f MB/s %7.1f MB/s %4.0f ms\n' "$BOLD$CYN" "$k" "$RST" "${AV_LABEL[$i]}" "${AR_DOWN[$i]:-0}" "${AR_UP[$i]:-0}" "${AR_RTT[$i]:-0}"
  done
  for ((i=0; i<${#AV_LABEL[@]}; i++)); do
    [ "${AR_OK[$i]}" = 1 ] || printf '  %s  ✘  %-28s %s%s%s\n' "$RED" "${AV_LABEL[$i]}" "$GRY" "${AR_WHY[$i]}" "$RST"
  done
  hint "${AT_NOTE:-Tested with ${AT_MB} MB each way.} Finished in ${AT_SECS} s."
}
at_to_t() { # AT_SEL (one index, or several = bond) -> T_CARRIER T_PEER T_PATH T_SNI T_REV AT_EXTRA + labels
  local i c cars='' cdn='' l
  AT_EXTRA=''; T_SNI=''; T_REV=''; T_PATH=''
  if [ "${#AT_SEL[@]}" -gt 1 ]; then
    for i in "${AT_SEL[@]}"; do
      c=${AV_CAR[$i]}; cars="${cars:+$cars+}$c"; AT_EXTRA+="peer-$c: ${AV_PEER[$i]}"$'\n'
      # fp / ech / tls-frag are global flags, not per carrier: a bond uses the settings of its first (best) CDN variant
      if [ "${AV_KIND[$i]}" = c ] && [ -z "$cdn" ]; then cdn=$i; T_SNI=${AV_SNI[$i]}; fi
    done
    AT_EXTRA=${AT_EXTRA%$'\n'}
    if [ -n "$cdn" ]; then while IFS= read -r l; do [ -n "$l" ] && AT_EXTRA+=$'\n'"$l"; done < <(at_cdn_lines "$cdn"); fi
    T_CARRIER=$cars; T_PEER=$AT_ADDR; T_PATH=/wat
    AT_SEL_LABEL="bond $cars"; AT_SEL_KEY=bond
    return 0
  fi
  i=${AT_SEL[0]}; c=${AV_CAR[$i]}
  T_CARRIER=$c; T_PEER=${AV_PEER[$i]}
  case "$c" in ws|wss|h2|h2c|grpc) T_PATH=/wat ;; esac
  if [ "${AV_KIND[$i]}" = c ]; then T_SNI=${AV_SNI[$i]}; AT_EXTRA=$(at_cdn_lines "$i"); fi
  [ "${AV_KIND[$i]}" = r ] && T_REV=1
  AT_SEL_LABEL=${AV_LABEL[$i]}; AT_SEL_KEY=$(av_key "$i")
}
at_choose() { # rc 0 = chosen (T_* ready), 1 = cancelled
  local n=${#AT_RANK[@]} best=${AT_RANK[0]} bond=() i t num rest bd bu
  for i in "${AT_RANK[@]}"; do [ "${AV_KIND[$i]}" = d ] && bond+=("$i"); done
  if [ "$NONINTERACTIVE" = 1 ]; then # --pick best (default) | bond | N (row number of the table)
    local def_pick="best"
    local cur_pol=${NI_POLICY:-}
    [ -z "$cur_pol" ] && [ -n "${AT_TUNNEL:-}" ] && cur_pol=$(cat "$CONF/$AT_TUNNEL.policy" 2>/dev/null || echo speed)
    [ "$cur_pol" = bond ] && def_pick="bond"
    case "${NI_PICK:-$def_pick}" in
      best) AT_SEL=("$best") ;;
      bond) if [ "${#bond[@]}" -ge 2 ]; then AT_SEL=("${bond[@]}"); else AT_SEL=("$best"); fi ;;
      *,*) at_rows "$NI_PICK" || return 1 ;;
      ''|*[!0-9]*) err "--pick must be best, bond, a row number of the table, or several joined with commas (1,3)"; return 1 ;;
      *) if [ "$NI_PICK" -ge 1 ] && [ "$NI_PICK" -le "$n" ]; then AT_SEL=("${AT_RANK[$((NI_PICK-1))]}")
         else err "--pick $NI_PICK: the table has $n working row(s)"; return 1; fi ;;
    esac
    at_to_t; return 0
  fi
  printf -v bd '%.1f' "${AR_DOWN[$best]:-0}"
  printf -v bu '%.1f' "${AR_UP[$best]:-0}"
  echo
  printf '  %s use the best (%s%s%s, %s/%s MB/s)\n' "$(key_label Enter)" "$BOLD" "${AV_LABEL[$best]}" "$RST" "$bd" "$bu"
  [ "${#bond[@]}" -ge 2 ] && printf '  %s bond all working direct carriers (%d: survives any one being blocked)\n' "$(key_label b)" "${#bond[@]}"
  [ "$n" -gt 1 ] && printf '  %s pick another from the table\n' "$(key_label "1-$n")"
  [ "$n" -gt 1 ] && printf '  %s custom: join the rows you choose into one tunnel (it keeps working while any of them passes)\n' "$(key_label c)"
  at_failed >/dev/null && printf '  %s use a type that failed the test anyway\n' "$(key_label f)"
  printf '  %s cancel\n' "$(key_label q)"
  for t in 1 2 3 4 5; do
    printf '  %s?%s Choice %s[Enter]%s ' "$CYN" "$RST" "$GRY" "$RST"
    key_read
    case "$KEY" in
      enter) AT_SEL=("$best") ;;
      b|B) if [ "${#bond[@]}" -ge 2 ]; then AT_SEL=("${bond[@]}"); else echo; warn "Bonding needs two or more working direct carriers."; continue; fi ;;
      c|C) [ "$n" -gt 1 ] || { echo; warn "Only one type works, so there is nothing to join."; continue; }
         echo; at_custom || continue ;;
      f|F) echo; at_force || continue ;;
      [1-9]) num=$KEY
         if [ "$n" -gt 9 ]; then printf '%s' "$KEY"; IFS= read -r -t 5 rest || true; num="$KEY$rest"; fi
         if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$n" ]; then AT_SEL=("${AT_RANK[$((num-1))]}")
         else echo; warn "No row $num."; continue; fi ;;
      q|Q|esc) echo; return 1 ;;
      *) echo; warn "Press Enter, b, c, f, a row number or q."; continue ;;
    esac
    case "$KEY" in c|C|f|F) ;; *) echo ;; esac
    at_to_t; return 0
  done
  return 1
}
at_rows() { # "1 3 4" or "1,3,4" (rows of the table) -> AT_SEL ; rc 1 with a message when a row is unusable
  local r i c seen=' ' cars=' '
  AT_SEL=()
  for r in ${1//,/ }; do
    if ! [[ "$r" =~ ^[0-9]+$ ]] || [ "$r" -lt 1 ] || [ "$r" -gt "${#AT_RANK[@]}" ]; then err "No row $r in the table."; return 1; fi
    i=${AT_RANK[$((r-1))]}
    case "$seen" in *" $i "*) continue ;; esac
    seen+="$i "
    AT_SEL+=("$i")
  done
  [ "${#AT_SEL[@]}" -ge 1 ] || { err "Enter at least one row number."; return 1; }
  [ "${#AT_SEL[@]}" -eq 1 ] && return 0
  for i in "${AT_SEL[@]}"; do
    if [ "${AV_KIND[$i]}" = r ]; then err "${AV_LABEL[$i]} is a reverse connection; it cannot be joined with others. Pick it alone."; return 1; fi
    c=${AV_CAR[$i]}
    case "$cars" in *" $c "*) err "Two rows use $c; a joined tunnel can use each type once."; return 1 ;; esac
    cars+="$c "
  done
}
at_custom() { # interactive: choose rows to join -> AT_SEL
  ask "Rows to join, e.g. 1 3 4 (Enter = cancel)" ""
  [ -n "$REPLY_V" ] || return 1
  at_rows "$REPLY_V"
}
at_failed() { # prints the indices of variants that failed the test ; rc 1 when none did
  local i any=1
  for ((i=0; i<${#AV_LABEL[@]}; i++)); do [ "${AR_OK[$i]}" = 1 ] || { echo "$i"; any=0; }; done
  return $any
}
at_force() { # interactive: pick a variant that failed the test -> AT_SEL
  local f=() i k=0
  mapfile -t f < <(at_failed)
  [ "${#f[@]}" -gt 0 ] || { warn "Every type passed the test."; return 1; }
  warn "These failed the test. The tunnel will likely not connect until the route lets them through."
  for i in "${f[@]}"; do k=$((k+1)); printf '    %s%d%s %-28s %s%s%s\n' "$CYN" "$k" "$RST" "${AV_LABEL[$i]}" "$GRY" "${AR_WHY[$i]}" "$RST"; done
  ask "Number (Enter = cancel)" ""
  [ -n "$REPLY_V" ] || return 1
  if ! [[ "$REPLY_V" =~ ^[0-9]+$ ]] || [ "$REPLY_V" -lt 1 ] || [ "$REPLY_V" -gt "$k" ]; then warn "No number $REPLY_V."; return 1; fi
  AT_SEL=("${f[$((REPLY_V-1))]}")
}
at_none() { # nothing worked
  local i tried=''
  err "Nothing worked: none of the connection types got a working link from this server to Kharej."
  for ((i=0; i<${#AV_LABEL[@]}; i++)); do tried="$tried ${AV_LABEL[$i]},"; done
  say "  Tried:${tried%,}"
  [ "$AT_QUIET" = 1 ] && return 0
  at_table
  if [ "$AT_DLINK" = 0 ]; then
    echo
    warn "Kharej may not know this server's IP yet, so the reverse side may never have started."
    hint "On Kharej run:  $SELF auto-ip <kharej tunnel name> $(public_ip)"
    hint "then run the test again: ${AT_AGAIN:-paste the token again on this server}"
  fi
  hint "Also check: the Kharej tunnel is running, the key is current (paste the token again), and Kharej's cloud firewall."
}
auto_iran_front() { # token : test everything, ranked table, choose. Leaves T_* ready for the normal flow
  AUTO_TOKEN=$1
  [ -n "$T_AUTO" ] || { err "This auto token has no test plan. Make a new token on Kharej (wattun 2.1.0 or newer)."; return 1; }
  summary_line "Mode" "auto: tests every connection type"
  summary_line "Kharej" "$T_PEER"
  summary_line "CDN domain" "${T_SNI:-none (CDN tests skipped)}"
  summary_line "Kharej allows" "${T_PORTS:-any port}"
  echo
  hint "Testing from this server, about 2-3 minutes. Nothing is published and no tunnel is touched."
  echo
  AT_QUIET=0; AT_MB=8; AT_NOTE=""; AT_SKIP=''; AT_AGAIN=''
  auto_test || { err "Could not prepare the test (is $AUTO_RUN writable?)."; return 1; }
  at_rank; auto_refine
  if [ "${#AT_RANK[@]}" -eq 0 ]; then echo; at_none; return 1; fi
  at_table
  at_choose || { warn "Cancelled."; return 1; }
  ok "Using $AT_SEL_LABEL"
  sleep 0.4
  return 0
}
auto_current_key() { # name -> carrier/kind of the running config (d direct, c CDN, r reverse) or bond
  local c; c=$(cfg "$1" carrier)
  case "$c" in *+*) echo bond; return ;; esac
  if is_reverse "$1"; then echo "$c/r"; elif [ -n "$(cfg "$1" sni)" ]; then echo "$c/c"; else echo "$c/d"; fi
}
auto_apply() { # name : write the chosen variant (T_*, AT_EXTRA) into NAME.yml, restart, wait for the link
  local n=$1 f="$CONF/$1.yml" ol oldrev=0 oldpool=0 l k v rport=''
  ol=$(cfg "$n" listen); ol=${ol##*:}
  is_reverse "$n" && oldrev=1
  [ "$oldrev" = 1 ] && is_pool "$(cfg "$n" carrier)" && oldpool=1
  sed -i -E '/^(carrier|peer|path|sni|host|reverse|listen|fp|ech|ech-cache|tls-frag|peer-[a-z0-9]+|listen-[a-z0-9]+):/d' "$f"
  set_value "$n" carrier "$T_CARRIER"
  # a working fake-SNI/pool-rotate combination survives a type switch only when the new type can still
  # carry it (single pool carrier, normal direction — the desync layer attaches nowhere else); strip it
  # otherwise, so switching to icmp/udp/bond/reverse never leaves dead keys (or silently re-arms them
  # when the type is switched back later)
  local keepres=''
  case "$T_CARRIER" in tcp|tls|ws|wss|h2|h2c|grpc) [ "$T_REV" != 1 ] && keepres=1 ;; esac
  [ "$keepres" = 1 ] || sed -i -E '/^(fake-(sni|mode|ttl)|pool-rotate(-bytes)?):/d' "$f"
  set_value "$n" peer "$T_PEER"
  [ -n "$T_PATH" ] && set_value "$n" path "$T_PATH"
  if [ -n "$T_SNI" ]; then set_value "$n" sni "$T_SNI"; set_value "$n" host "$T_SNI"; fi
  [ "$T_REV" = 1 ] && set_value "$n" reverse true
  if [ "$T_REV" = 1 ] && is_pool "$T_CARRIER"; then rport=${T_PEER##*:}; set_value "$n" listen "\":$rport\""; fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    k=${l%%: *}; v=${l#*: }; set_value "$n" "$k" "$v"
  done <<<"$AT_EXTRA"
  l=$(ech_cache_line "$n"); if [ -n "$l" ]; then set_value "$n" ech-cache "${l#*: }"; fi
  step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
  [ -n "$rport" ] && fw_open "$rport/tcp"
  [ "$oldpool" = 1 ] && [ -n "$ol" ] && [ "$ol" != "$rport" ] && fw_close "$ol/tcp"
  if [ "$T_CARRIER" = icmp ] && [ "$T_REV" = 1 ]; then
    [ "$AT_QUIET" = 1 ] || kreply_offer
  else reverse_iran_left || kreply_restore; fi
  [ "$AT_QUIET" = 1 ] && return 0
  if wait_link "$n" 25; then ok "CONNECTED (RTT ${LINK_RTT} ms)"; else warn "Not connected yet."; [ "$NONINTERACTIVE" = 1 ] && return 1; fi
  return 0
}
auto_test_cmd() { # name : re-run the test for an existing auto Iran tunnel and offer to switch
  local n=$1 cur
  if [ "$(role "$n")" != Iran ] || [ ! -f "$CONF/$n.auto" ]; then
    err "'$n' is not an auto Iran tunnel (it has no $n.auto). Create it with the token from an auto Kharej tunnel."; return 1
  fi
  if ! { read_token "$(cat "$CONF/$n.auto")" && [ -n "$T_AUTO" ]; }; then err "$CONF/$n.auto is not a valid auto token."; return 1; fi
  AT_TUNNEL=$n
  cur=$(auto_current_key "$n")
  AT_QUIET=0; AT_MB=8; AT_NOTE=""; AT_SKIP=''; AT_AGAIN="$SELF auto-test $n"
  case "$cur" in */r) AT_SKIP=" $cur " ;; esac # its own port / ICMP are in use by the running tunnel
  page "Auto test" "$n"
  hint "Current: $cur. The running tunnel is not touched until you choose."
  echo
  auto_test || { err "Could not prepare the test (is $AUTO_RUN writable?)."; return 1; }
  at_rank; auto_refine
  if [ "${#AT_RANK[@]}" -eq 0 ]; then
    echo; at_none
    { [ "$NONINTERACTIVE" != 1 ] && echo && confirm "Use one of the types that failed anyway?" n && at_force; } || return 1
    at_to_t
  else
    at_table
    at_choose || { warn "No change."; [ "$NONINTERACTIVE" = 1 ] && return 1; return 0; }
  fi
  if [ "$AT_SEL_KEY" = "$cur" ]; then ok "'$n' already uses $AT_SEL_LABEL."; return 0; fi
  confirm "Switch '$n' to $AT_SEL_LABEL? (open connections drop)" y || { warn "No change."; return 0; }
  auto_apply "$n"
}
auto_retest() { # name : unattended (auto-heal or auto-optimize): 1 MB tests
  local n=$1 cur best winner winner_key pol
  if ! { [ -f "$CONF/$n.auto" ] && read_token "$(cat "$CONF/$n.auto")" && [ -n "$T_AUTO" ]; }; then
    # not an auto tunnel: a plain CDN tunnel only gets a fresh edge scan (dead edge IPs replaced)
    cdn_tunnel_p "$n" && { cdn_refresh_edges "$n"; return 0; }
    return 1
  fi
  AT_TUNNEL=$n
  AT_QUIET=1; AT_MB=1; AT_NOTE=''; AT_SKIP=''; AT_AGAIN=''
  cur=$(auto_current_key "$n")
  case "$cur" in */r) AT_SKIP=" $cur " ;; esac
  auto_test || return 1
  at_rank
  if [ "${#AT_RANK[@]}" -eq 0 ]; then logger -t wattun-heal "retest of $n: no connection type works right now"; return 0; fi
  winner=${AT_RANK[0]}
  winner_key=$(av_key "$winner")
  if [ "$winner_key" = "$cur" ]; then
    logger -t wattun-heal "retest of $n: current variant $cur is already the top-ranked carrier, no switch"
    [ "$cur" = "$(cfg "$n" carrier)/c" ] && cdn_refresh_edges "$n" # same carrier through the CDN: replace dead edge IPs
    return 0
  fi
  # If off-peak optimization or SLA breach triggered this, always upgrade to the winner!
  # Otherwise (connection recovery), if current variant is still working, avoid flapping.
  if [ "${AUTO_OPTIMIZE:-0}" != 1 ] && [ ! -f "$RUN/$n.sla_triggered" ]; then
    for best in "${AT_RANK[@]}"; do
      if [ "$(av_key "$best")" = "$cur" ]; then
        logger -t wattun-heal "retest of $n: current variant $cur still works, no switch"
        [ "$cur" = "$(cfg "$n" carrier)/c" ] && cdn_refresh_edges "$n"
        return 0
      fi
    done
  fi
  pol=$(cat "$CONF/$n.policy" 2>/dev/null || echo speed)
  if [ "$pol" = bond ]; then
    local -a bond_cars=()
    for i in "${AT_RANK[@]}"; do [ "${AV_KIND[$i]}" = d ] && bond_cars+=("$i"); done
    if [ "${#bond_cars[@]}" -ge 2 ]; then
      AT_SEL=("${bond_cars[@]}")
    else
      AT_SEL=("$winner")
    fi
  else
    AT_SEL=("$winner")
  fi
  at_to_t
  auto_apply "$n" >/dev/null 2>&1
  logger -t wattun-heal "switched $n from $cur to $AT_SEL_KEY"
  rm -f "$RUN/$n.sla_triggered"
  return 0
}
heal_matrix() { # name : unattended matrix, apply the best only when the current config has no working link (called by heal)
  local n=$1 stamp="$RUN/$1.matrix" m=$MGR renv best
  [ "$(find "$stamp" -mmin -60 2>/dev/null)" ] && return 0 # at most once per hour
  command -v systemd-run >/dev/null 2>&1 || return 0
  touch "$stamp"
  logger -t wattun-heal "tunnel $n still down after 3 restart cycles, running the anti-censor matrix"
  mapfile -t renv < <(run_env_args)
  [ -x "$m" ] || m=$(readlink -f "$0")
  systemd-run --quiet --collect --unit "${WAT_PREFIX}-matrix-$n" "${renv[@]}" \
    --setenv=AC_FALLBACK=1 "$m" matrix "$n" --yes >/dev/null 2>&1
  return 0
}
heal_retest() { # name : at most once per 30 min, in a transient unit so it outlives the heal run
  local n=$1 stamp="$RUN/$1.retest" m=$MGR renv
  mapfile -t renv < <(run_env_args)
  [ -n "$(find "$stamp" -mmin -30 2>/dev/null)" ] && return 0
  command -v systemd-run >/dev/null 2>&1 || return 0
  [ -x "$m" ] || m=$(readlink -f "$0")
  touch "$stamp"
  logger -t wattun-heal "tunnel $n still down after restarts, testing the other connection types"
  systemd-run --quiet --collect --unit "${WAT_PREFIX}-autoretest-$n" "${renv[@]}" \
    "$m" auto-retest "$n" --yes >/dev/null 2>&1
  return 0
}

# ======================================================================================
#  Anti-censor matrix (2.10.2): test EVERY resilience combination from the Iran side,
#  apply the best that connects. All probes are throw-away clients on this server -
#  Kharej is never touched (under a blackout there is no SSH to it anyway).
#  Matrix on the tunnel's pool carrier (tcp/tls/ws/wss/h2/h2c/grpc):
#    base (current config, no desync) + desync seq/seqsum/sum/ttl/rst per allowlisted SNI
#    + ECH for TLS carriers + auto-mode (the binary's own startup probe).
#  Fills AV_*/AR_*/AT_RANK like auto_test; the winner is written with ac_matrix_apply.
# ======================================================================================
AC_SNIS='mci.ir,irancell.ir,tci.ir,divar.ir' # curated allowlisted SNIs, comma separated
AC_MODES='seq seqsum sum ttl rst'
ac_matrix() { # name : needs T_* loaded from the tunnel (ac_load); fills AV_*, AR_*, AT_RANK, AT_SECS
  local n=$1 i fs fm car=$T_CARRIER t0=$SECONDS w
  AV_LABEL=(); AV_CAR=(); AV_KIND=(); AV_PEER=(); AV_PORT=(); AV_SNI=(); AV_FP=(); AV_ECH=(); AV_FRAG=()
  AV_FS=(); AV_FM=()
  AR_OK=(); AR_DOWN=(); AR_UP=(); AR_RTT=(); AR_WHY=()
  at_prep || return 1
  # 0. baseline: the tunnel as it runs now (no desync) → tells whether the censor even needs the kit
  av_add "base (no desync)" "$car" d "$T_PEER" '' "$T_SNI"
  # 1. every fake-mode for the first curated SNI
  for fm in $AC_MODES; do
    av_add "desync ${AC_SNIS%%,*} → $fm" "$car" d "$T_PEER" '' "$T_SNI" '' '' '' "${AC_SNIS%%,*}" "$fm"
  done
  # 2. the strongest mode (seqsum) against every other curated SNI
  local fs rest=${AC_SNIS#*,}
  for fs in ${rest//,/ }; do
    [ -n "$fs" ] || continue
    av_add "desync $fs → seqsum" "$car" d "$T_PEER" '' "$T_SNI" '' '' '' "$fs" seqsum
  done
  # 3. ECH ladder (TLS carriers only): hides the real SNI from the DPI, works when SNIs are filtered
  case "$car" in tls|wss|h2|grpc)
    [ -n "$(cfg "$n" ech)" ] || av_add "ech ladder (no desync)" "$car" d "$T_PEER" '' "$T_SNI" chrome auto ;;
  esac
  # 4. auto mode: the binary's own startup probe picks seq/sum/seqsum/rst by itself
  if [ "$(bin_ver_ok 2.9.0)" = 1 ]; then
    av_add "desync auto-probe" "$car" d "$T_PEER" '' "$T_SNI" '' '' '' "${AC_SNIS%%,*}" auto
  fi
  # 5. Native ICMP echo fallback (activated when emergency ladder AC_FALLBACK=1 is set)
  if [ "${AC_FALLBACK:-0}" = 1 ] && [ "$car" != icmp ] && [ -n "$T_PEER" ]; then
    local icmp_peer="${T_PEER%:*}"
    av_add "fallback ICMP echo" icmp d "$icmp_peer" '' '' '' '' '' '' ''
  fi
  AT_SKIP=''; AT_NOTE=''
  for ((i=0; i<${#AV_LABEL[@]}; i++)); do
    w=8
    [ "$AT_QUIET" = 1 ] || at_busy "${AV_LABEL[$i]}"
    at_probe "$i" "$w"
    [ "$AT_QUIET" = 1 ] || { at_idle; at_print "$i"; }
  done
  at_cleanup
  at_rank; AT_SECS=$((SECONDS-t0))
  return 0
}
ac_matrix_apply() { # name : write the chosen variant (AT_SEL[0]) into NAME.yml and restart
  local n=$1 i=${AT_SEL[0]}
  T_PEER=${AV_PEER[$i]}; T_SNI=${AV_SNI[$i]}
  T_CARRIER=${AV_CAR[$i]}
  AT_EXTRA=''
  [ -n "${AV_FP[$i]:-}" ] && AT_EXTRA+="fp: ${AV_FP[$i]}"$'\n'
  [ -n "${AV_ECH[$i]:-}" ] && AT_EXTRA+="ech: ${AV_ECH[$i]}"$'\n'
  if [ -n "${AV_FS[$i]:-}" ]; then
    set_value "$n" fake-sni "${AV_FS[$i]}"
    set_value "$n" fake-mode "${AV_FM[$i]:-seq}"
    unset_value "$n" fake-ttl # matrix probes always run ttl auto-calibration
  else
    sed -i -E '/^(fake-(sni|mode|ttl)):/d' "$CONF/$n.yml"
  fi
  auto_apply "$n"
}
ac_load() { # name -> T_* from the running tunnel's config (matrix runs on the same carrier+peer)
  local n=$1 kf
  kf=$(cfg "$n" key-file); [ -r "$kf" ] || kf="$CONF/$n.key"
  T_CARRIER=$(cfg "$n" carrier); T_PEER=$(cfg "$n" peer); T_PATH=$(cfg "$n" path)
  T_SNI=$(cfg "$n" sni); [ -n "$T_SNI" ] || T_SNI=$(cfg "$n" host)
  T_KEY=''; { IFS= read -r T_KEY <"$kf"; } 2>/dev/null
  [ -n "$T_KEY" ] && [ -n "$T_PEER" ]
}
ac_matrix_cmd() { # name : test every anti-censor combination, apply the best that connects
  local n=$1
  [ "$(role "$n")" = Iran ] || { err "'$n' is not an Iran tunnel (the matrix runs client-side)."; return 1; }
  is_reverse "$n" && { err "'$n' is a reverse tunnel; the desync matrix needs a normal Iran tunnel."; return 1; }
  local cr; cr=$(cfg "$n" carrier)
  if [[ "$cr" == *+* ]]; then
    err "'$n' is a bond ($cr); the desync matrix tunes one carrier. Use auto-test for bonds."
    return 1
  fi
  if ! is_pool "$cr"; then
    if [ "$cr" = icmp ]; then
      err "The desync kit does not attach to the icmp carrier (its camouflage is the ICMP shape itself)."
      hint "For icmp the resilience knob is the volume governor: $SELF blackout $n  # or tunnel page -> o -> k"
      [ "$(cfg "$n" governor)" = true ] && hint "The governor is already ON for '$n'."
    else
      err "Carrier '$cr' has no anti-censorship layer (only tcp, tls, ws, wss, h2, h2c, grpc)."
    fi
    return 1
  fi
  [ "$(uname -s)" = Linux ] || { err "The desync kit is a Linux feature (fake-sni needs CAP_NET_RAW)."; return 1; }
  ac_load "$n" || { err "Cannot read the key/peer of '$n'."; return 1; }
  [ "$(bin_ver_ok 2.7.0)" = 1 ] || { err "The desync matrix needs wattun 2.7.0 or newer (run: $SELF update)."; return 1; }
  page "Anti-censor matrix" "$n ($cr)"
  hint "Testing every resilience combination from THIS server with throw-away clients."
  hint "Kharej is never touched. About 2-3 minutes; the running tunnel is untouched until the end."
  echo
  AT_QUIET=0; AT_MB=2
  ac_matrix "$n" || { err "Could not prepare the test."; return 1; }
  at_table
  if [ "${#AT_RANK[@]}" -eq 0 ]; then
    echo
    err "Nothing connects right now → not even the baseline. The censor is dropping the carrier itself (L3/IP block)."
    hint "The desync kit cannot fix a blocked IP: switch carrier (m), use the CDN (cdn-tune), or wait out the blackout."
    return 1
  fi
  local best=${AT_RANK[0]} cur
  echo
  ok "Best: ${AV_LABEL[$best]} ($(printf '%.1f/%.1f MB/s' "${AR_DOWN[$best]:-0}" "${AR_UP[$best]:-0}"))"
  cur="fs=$(cfg "$n" fake-sni) fm=$(cfg "$n" fake-mode)"
  local want="fs=${AV_FS[$best]:-} fm=${AV_FM[$best]:-}"
  [ -n "$(cfg "$n" fake-ttl)" ] && cur+=" ttl=$(cfg "$n" fake-ttl)" # a manual fake-ttl differs from the matrix's auto
  if [ "$cur" = "$want" ]; then
    ok "The running tunnel already uses this combination; nothing to change."
    return 0
  fi
  if confirm "Apply '${AV_LABEL[$best]}' to '$n'? (restarts the tunnel, open connections drop)" y; then
    AT_SEL=("$best")
    ac_matrix_apply "$n"
  else
    warn "No change."
  fi
  return 0
}

# ======================================================================================
#  CDN tuning (wattun >= 2.2.0 on Iran): find the fastest Cloudflare edges and TLS settings, no questions
#    cdn_scan   finds the edges that serve the domain over ECH: TCP pre-filter, then one throw-away client over all candidates, /stats edges (CS_*)
#    cdn_tune   tests chrome+ech, chrome, go (frag last resort) variants with the same throw-away clients as Auto (AV_*, AR_*) -> CT_IDX
#    Config keys written: peer (several edges, comma separated), fp, ech, tls-frag. sni/host stay the domain.
# ======================================================================================
CDN_MINVER=2.2.0
CDN_OK=''
CS_DIR=''; CS_PIDS=(); CS_EDGES=(); CS_REACH_IPS=(); CS_REACH=0; CS_TOTAL=0; CS_BEST_IP=''; CS_BEST_MS=0; CS_QUIET=0
CS_VERBOSE=${WAT_VERBOSE:-0}
CS_FALLBACK=0; CS_RAN=0
CS_V4='162.159.140.220 162.159.141.1 162.159.141.100 162.159.135.1 162.159.135.100 162.159.136.1 162.159.136.100 162.159.128.1 162.159.128.100 104.16.0.1 104.17.0.1 104.18.0.1 104.19.0.1 104.21.0.1 104.24.0.1 172.64.0.1 172.64.80.1 172.65.0.1 172.66.0.1 172.67.0.1 172.67.74.1 188.114.96.1 188.114.97.6'
CS_V6='2a06:98c1:3121::7 2a06:98c1:3120::7 2606:4700:3030::1 2606:4700:3033::1 2606:4700::6810:1 2606:4700:20::1'
CT_IDX=''; CT_I=''; CT_DESC=''; CT_W=8; AT_FULL=0
is_cdn_carrier() { case "$1" in ws|wss|h2|h2c|grpc) return 0 ;; esac; return 1; }
cdn_ok() { # is the installed binary new enough for fp / ech / tls-frag / several peers ?
  [ -n "$CDN_OK" ] || { ver_ge "$(bin_ver || true)" "$CDN_MINVER" 2>/dev/null && CDN_OK=1 || CDN_OK=0; }
  [ "$CDN_OK" = 1 ]
}
ech_cache_line() { # name : the "ech-cache:" config line for a tunnel that uses ech: auto (wattun >= 2.2.3 only; older engines reject unknown keys)
  grep -qx 'ech: auto' <<<"$AT_EXTRA" || return 0
  ver_ge "$(bin_ver || true)" 2.2.3 2>/dev/null && echo "ech-cache: $CONF/$1.ech"
  return 0
}
cdn_tunnel_p() { # name : an Iran client on a CDN carrier with a domain (not reverse, not an auto companion)
  [ "$(role "$1")" = Iran ] && ! is_reverse "$1" && is_cdn_carrier "$(cfg "$1" carrier)" || return 1
  [ -n "$(cfg "$1" sni)$(cfg "$1" host)" ]
}
cdn_domain() { # T_SNI, else the host of T_PEER when that is a domain -> prints it (nothing when the peer is an IP)
  local h
  if [ -n "$T_SNI" ]; then echo "$T_SNI"; return 0; fi
  h=${T_PEER%%,*}; h=${h%:*}
  [[ "$h" == *[A-Za-z]* ]] && [[ "$h" != *:* ]] && echo "$h"
  return 0
}
cdn_peer_list() { # port -> "ip:port,[v6]:port" from CS_EDGES
  local ip out=''
  for ip in ${CS_EDGES[@]+"${CS_EDGES[@]}"}; do
    [[ "$ip" == *:* ]] && ip="[$ip]"
    out="${out:+$out,}$ip:$1"
  done
  echo "$out"
}
cdn_scan_say() { # one summary line for the last cdn_scan
  if [ "$CS_REACH" -gt 0 ]; then ok "Cloudflare edges: $CS_REACH serve this domain over ECH (of $CS_TOTAL reachable)"
  elif [ "$CS_TOTAL" -gt 0 ]; then warn "Cloudflare edges: none of the $CS_TOTAL reachable ones served this domain over ECH; using the domain's own addresses"
  else warn "Cloudflare edges: none of the tested addresses accepts a TCP connection from this server"; fi
}
cdn_up_edges() { # metrics-port : the edge addresses the engine reports as up (/stats "edges": [{"addr":"ip:port","up":true}]), one per line
  curl -fs --noproxy '*' --max-time 3 "http://127.0.0.1:$1/stats" 2>/dev/null | grep -oE '"addr":"[^"]+","up":true' \
    | sed -E 's/^"addr":"//; s/","up":true$//; s/:[0-9]+$//; s/^\[//; s/\]$//'
}
cdn_ipv4hints() { # domain : the IPv4 addresses of its HTTPS record's ipv4hint, one per line (dig, else DoH JSON); silent on any failure
  local d=$1 s=''
  if command -v dig >/dev/null 2>&1; then
    s=$(timeout 4 dig +short +time=2 +tries=1 HTTPS "$d" 2>/dev/null | grep -io 'ipv4hint=[0-9.,]*')
  fi
  if [ -z "$s" ] && command -v curl >/dev/null 2>&1; then
    s=$(curl -fs --noproxy '*' --connect-timeout 2 --max-time 4 -k -H 'accept: application/dns-json' \
      "https://8.8.8.8/resolve?name=$d&type=HTTPS" 2>/dev/null | grep -io 'ipv4hint=[0-9.,]*')
  fi
  [ -n "$s" ] || return 0
  sed -E 's/^[^=]*=//' <<<"$s" | tr ',' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true
  return 0
}
now_us() { if [ -n "${EPOCHREALTIME:-}" ]; then local t=${EPOCHREALTIME/[.,]/}; echo "$t"; else echo $(( $(date +%s%N) / 1000 )); fi; }
cdn_pick_edges() { # up to 3 of the ips given (already fastest first): one per /24 (v6: /48) when there are alternatives, then fill up
  local ip k out=() rest=(); local -A pf=()
  for ip in "$@"; do
    if [[ "$ip" == *:* ]]; then k=$(cut -d: -f1-3 <<<"$ip"); else k=${ip%.*}; fi
    if [ -z "${pf[$k]:-}" ] && [ "${#out[@]}" -lt 3 ]; then pf[$k]=1; out+=("$ip"); else rest+=("$ip"); fi
  done
  for ip in ${rest[@]+"${rest[@]}"}; do [ "${#out[@]}" -ge 3 ] && break; out+=("$ip"); done
  CS_EDGES=("${out[@]}")
}
cdn_scan() { # domain port path carrier : pick the Cloudflare edges that serve this domain, judged by the tunnel engine itself
  # -> CS_EDGES (best 3), CS_REACH_IPS (every edge that is up), CS_REACH (up) / CS_TOTAL (TCP-reachable) ; CS_FALLBACK=1 when none was
  # verified (CS_EDGES is then the domain's own addresses) ; rc 1 when there is nothing to choose from at all.
  # curl cannot do ECH, so it only pre-filters plain TCP reachability. A throw-away client with -fp chrome -ech auto and one pool
  # connection per candidate spreads over all of them; /stats then says which candidates really carried a connection.
  local dom=$1 port=$2 path=${3:-/} car=${4:-wss} ip n=0 v6=0 i own=() cand=() reach=() peers='' up='' mp pid t end a N
  local -A seen=() isup=() tcpms=()
  CS_EDGES=(); CS_REACH_IPS=(); CS_REACH=0; CS_TOTAL=0; CS_BEST_IP=''; CS_BEST_MS=0; CS_FALLBACK=0; CS_RAN=0
  [[ "$path" == /* ]] || path=/$path
  ipv4_ok "$dom" && return 1 # an IP address has no Cloudflare edges to choose from
  ip -6 route get 2606:4700::1 >/dev/null 2>&1 && v6=1 # DNS may return AAAA on a server without any v6 route
  # the HTTPS record's ipv4hint addresses come first: they are the edges the zone itself advertises to browsers
  for ip in $(cdn_ipv4hints "$dom"); do
    [ -n "${seen[$ip]:-}" ] || { seen[$ip]=1; own+=("$ip"); cand+=("$ip"); }
  done
  # then the domain's own A records: they are what Cloudflare hands out for this very zone
  for ip in $(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1}' | sort -u); do
    [ -n "${seen[$ip]:-}" ] || { seen[$ip]=1; own+=("$ip"); cand+=("$ip"); }
  done
  if [ "$v6" = 1 ]; then
    for ip in $(getent ahostsv6 "$dom" 2>/dev/null | awk '{print $1}' | grep -v -i '^::ffff:' | sort -u); do
      [ -n "${seen[$ip]:-}" ] || { seen[$ip]=1; own+=("$ip"); cand+=("$ip"); }
    done
  fi
  for ip in $CS_V4 $( [ "$v6" = 1 ] && echo "$CS_V6" ); do
    [ -n "${seen[$ip]:-}" ] || { seen[$ip]=1; cand+=("$ip"); }
  done
  CS_RAN=1
  CS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wattun-cdn.XXXXXX") || { CS_DIR=''; return 1; }
  # fast pre-filter: drop what cannot even open a TCP connection (any TLS / HTTP outcome is fine here)
  CS_PIDS=()
  for ip in "${cand[@]}"; do
    n=$((n+1))
    local hip=$ip
    [[ "$hip" == *:* ]] && hip="[$hip]" # bash /dev/tcp needs brackets for v6, else every AAAA fails the filter
    ( t0=$(now_us); timeout 2 bash -c "exec 3<>/dev/tcp/$hip/$port" 2>/dev/null && echo $(( $(now_us) - t0 )) >"$CS_DIR/$n" ) &
    CS_PIDS+=($!)
  done
  wait "${CS_PIDS[@]}" 2>/dev/null
  CS_PIDS=()
  n=0
  # fastest TCP connect first: that order decides which edges are kept
  for ip in "${cand[@]}"; do n=$((n+1)); [ -s "$CS_DIR/$n" ] && tcpms[$ip]=$(< "$CS_DIR/$n"); done
  while read -r _ ip; do [ -n "$ip" ] && reach+=("$ip"); done < <(for ip in "${!tcpms[@]}"; do echo "${tcpms[$ip]} $ip"; done | sort -n)
  rm -rf "$CS_DIR"; CS_DIR=''
  CS_TOTAL=${#reach[@]}
  if [ "$CS_TOTAL" -eq 0 ]; then # nothing answers on TCP (or the check itself is unreliable here): the domain's own addresses are the only guess
    [ "${#own[@]}" -gt 0 ] || return 1
    CS_FALLBACK=1; CS_EDGES=("${own[@]:0:3}"); [ "$CS_QUIET" = 1 ] || cdn_scan_say
    return 0
  fi
  [ "${#reach[@]}" -gt 24 ] && reach=("${reach[@]:0:24}")
  N=${#reach[@]}
  for ip in "${reach[@]}"; do
    [[ "$ip" == *:* ]] && ip="[$ip]"
    peers="${peers:+$peers,}$ip:$port"
  done
  if [ -n "${AT_DIR:-}" ] && [ -r "$AT_DIR/key" ] || { [ -n "${T_KEY:-}" ] && at_prep; }; then
    mp=$(at_free_port)
    a=(-mode client -carrier "$car" -key-file "$AT_DIR/key" -peer "$peers" -metrics "127.0.0.1:$mp" -conns "$N"
       -path "$path" -sni "$dom" -host "$dom" -map "$(at_free_port $((mp + 1))):1@127.0.0.1")
    case "$car" in wss|grpc|h2) a+=(-fp chrome -ech auto) ;; esac
    timeout -k 2 40 "$BIN" "${a[@]}" >"$AT_DIR/scan.log" 2>&1 &
    AT_PID=$!
    end=$((SECONDS + 12))
    while [ "$SECONDS" -lt "$end" ]; do
      sleep 1
      up=$(cdn_up_edges "$mp"); [ -n "$up" ] && [ "$(wc -l <<<"$up")" -ge "$N" ] && break
    done
    up=$(cdn_up_edges "$mp")
    at_kill
    for ip in $up; do isup[$ip]=1; done
    for ip in "${reach[@]}"; do [ -n "${isup[$ip]:-}" ] && CS_REACH_IPS+=("$ip"); done
  fi
  CS_REACH=${#CS_REACH_IPS[@]}
  if [ "$CS_REACH" -gt 0 ]; then
    cdn_pick_edges "${CS_REACH_IPS[@]}"; CS_BEST_IP=${CS_EDGES[0]}; CS_BEST_MS=$(( ${tcpms[$CS_BEST_IP]:-0} / 1000 ))
  else
    CS_FALLBACK=1
    if [ "${#own[@]}" -gt 0 ]; then CS_EDGES=("${own[@]:0:3}"); else CS_EDGES=("${reach[@]:0:3}"); fi
  fi
  [ "$CS_QUIET" = 1 ] || cdn_scan_say
  return 0
}

at_prep() { # temp dir and key file for the throw-away clients (needs T_KEY)
  AT_DIR=$AUTO_RUN/t.$$
  mkdir -p "$AUTO_RUN" && chmod 700 "$AUTO_RUN" && rm -rf "$AT_DIR" && mkdir -p "$AT_DIR" || return 1
  ( umask 077; printf '%s\n' "$T_KEY" >"$AT_DIR/key" )
}
at_score() { awk -v d="${AR_DOWN[$1]:-0}" -v u="${AR_UP[$1]:-0}" 'BEGIN{printf "%.6f", d+u}'; } # i -> down+up
at_best_score() { # best down+up of everything tested so far
  local i b=0
  for ((i=0; i<${#AV_LABEL[@]}; i++)); do
    [ "${AR_OK[$i]:-0}" = 1 ] || continue
    b=$(awk -v a="$b" -v c="$(at_score "$i")" 'BEGIN{print (c>a)?c:a}')
  done
  echo "$b"
}
at_near_best() { awk -v s="$(at_score "$1")" -v b="$(at_best_score)" 'BEGIN{exit !(s>=b*0.9)}'; } # i within 10% of the best seen
at_cdn_lines() { # i -> the fp / ech / tls-frag config lines of variant i
  local i=$1
  [ -n "${AV_FP[$i]:-}" ] && [ "${AV_FP[$i]}" != go ] && echo "fp: ${AV_FP[$i]}"
  [ -n "${AV_ECH[$i]:-}" ] && [ "${AV_ECH[$i]}" != off ] && echo "ech: ${AV_ECH[$i]}"
  [ -n "${AV_FRAG[$i]:-}" ] && [ "${AV_FRAG[$i]}" != 0 ] && echo "tls-frag: ${AV_FRAG[$i]}"
  return 0
}
cdn_desc() { # i -> "chrome fingerprint, 3 Cloudflare edges"
  local i=$1 out='' n h=${AV_PEER[$1]%%,*}
  add() { out="${out:+$out, }$1"; }
  [ -n "${AV_FP[$i]:-}" ] && [ "${AV_FP[$i]}" != go ] && add "${AV_FP[$i]} fingerprint"
  [ -n "${AV_ECH[$i]:-}" ] && [ "${AV_ECH[$i]}" != off ] && add "ECH (hidden domain)"
  [ -n "${AV_FRAG[$i]:-}" ] && [ "${AV_FRAG[$i]}" != 0 ] && add "${AV_FRAG[$i]}-byte TLS fragments"
  if [[ "$h" == \[* ]] || [[ "${h%%:*}" =~ ^[0-9.]+$ ]]; then
    n=$(awk -F, '{print NF}' <<<"${AV_PEER[$i]}"); add "$n Cloudflare edge$([ "$n" -gt 1 ] && echo s)"
  fi
  echo "${out:-default settings}"
}
cdn_try() { # carrier label peer fp ech tls-frag : add a CDN variant, test it, print the result ; its index -> CT_I
  local i
  av_add "$2" "$1" c "$3" '' "$T_SNI" "$4" "$5" "$6"
  i=$((${#AV_LABEL[@]}-1)); CT_I=$i
  [ "$AT_QUIET" = 1 ] || at_busy "$2"
  at_probe "$i" "$CT_W"
  [ "$AT_QUIET" = 1 ] || { at_idle; at_print "$i"; }
  return 0
}
cdn_variants() { # carrier edge-peer default-peer [skip-ech] : TLS variants in preference order: chrome+ech, chrome, go; frag only when all failed
  local car=$1 pa=$2 pd=$3 skip=${4:-0} any=0 eok=0 i
  if [ "$skip" = 1 ]; then eok=${AR_OK[$CT_I]:-0}
  else
    # ECH is the variant that works against an SNI filter (field result: every non-ECH variant failed through Cloudflare from Iran)
    CT_W=12; cdn_try "$car" "$car · chrome+ech" "$pa" chrome auto ''; CT_W=8
    eok=${AR_OK[$CT_I]}
  fi
  [ "$eok" = 1 ] && any=1
  # chrome+ech works: nothing further to test, unless "full"
  [ "$eok" = 1 ] && [ "$AT_FULL" != 1 ] && return 0
  cdn_try "$car" "$car · chrome" "$pa" chrome '' ''; [ "${AR_OK[$CT_I]}" = 1 ] && any=1
  cdn_try "$car" "$car · go" "$pd" '' '' '';          [ "${AR_OK[$CT_I]}" = 1 ] && any=1
  # the ClientHello cut comes after the handshake, so it rarely helps against an SNI filter: last resort only
  if [ "$any" != 1 ]; then cdn_try "$car" "$car · frag" "$pa" chrome '' 100
  elif [ "$AT_FULL" = 1 ]; then cdn_try "$car" "$car · frag (diagnostic)" "$pa" chrome '' 100; fi
  return 0
}
cdn_auto_extras() { # Auto: after (a) chrome+ech of each CDN carrier: the remaining variants only when (a) failed (or full)
  local i car port list=()
  for ((i=0; i<${#AV_LABEL[@]}; i++)); do [ "${AV_KIND[$i]}" = c ] && list+=("$i"); done
  for i in "${list[@]}"; do
    [ "$AT_FULL" = 1 ] || [ "${AR_OK[$i]}" != 1 ] || continue
    car=${AV_CAR[$i]}; port=${AV_PEER[$i]%%,*}; port=${port##*:}
    CT_I=$i
    cdn_variants "$car" "${AV_PEER[$i]}" "$T_SNI:$port" 1
  done
  return 0
}
cdn_tune() { # [full] : needs T_CARRIER T_PEER T_KEY T_PATH T_SNI (the domain), AT_QUIET, AT_MB ; fills AV_*, AR_*, CT_IDX ; rc 1 = could not start
  local car=$T_CARRIER port pa pd label a t0=$SECONDS i
  AT_FULL=${1:-0}
  AV_LABEL=(); AV_CAR=(); AV_KIND=(); AV_PEER=(); AV_PORT=(); AV_SNI=(); AV_FP=(); AV_ECH=(); AV_FRAG=()
  AV_FS=(); AV_FM=()
  AR_OK=(); AR_DOWN=(); AR_UP=(); AR_RTT=(); AR_WHY=(); CT_IDX=''
  port=${T_PEER%%,*}; port=${port##*:}
  pd=$T_PEER; case "$pd" in *,*) pd="$T_SNI:$port" ;; esac
  [ "$car" = h2 ] && [ "$AT_QUIET" != 1 ] && hint "h2 does not work through Cloudflare; use grpc or wss"
  if [ "$AT_FULL" = 1 ] && [ "$AT_QUIET" != 1 ]; then # the Kharej tunnel runs one carrier; say what the other CDN carrier would have been
    case "$car" in wss) hint "grpc: not offered by this Kharej tunnel" ;; grpc) hint "wss: not offered by this Kharej tunnel" ;; esac
  fi
  at_prep || return 1
  [ "$AT_QUIET" = 1 ] || at_busy "Cloudflare edges"
  CS_QUIET=1; cdn_scan "$T_SNI" "$port" "${T_PATH:-/wat}" "$car"
  [ "$AT_QUIET" = 1 ] || { at_idle; [ "$CS_RAN" = 1 ] && cdn_scan_say; echo; }
  pa=$pd; label=$car
  if [ "${#CS_EDGES[@]}" -gt 0 ]; then pa=$(cdn_peer_list "$port"); label="$car · ${#CS_EDGES[@]} edges"; fi
  case "$car" in
    wss|grpc|h2) cdn_variants "$car" "$pa" "$pd" 0 ;;
    *) # plain ws / h2c only get the edge choice; the default is tried only when that failed
      cdn_try "$car" "$label" "$pa" '' '' ''
      [ "${AR_OK[$CT_I]}" = 1 ] || cdn_try "$car" "$car · default" "$pd" '' '' '' ;;
  esac
  at_cleanup
  at_rank; AT_SECS=$((SECONDS-t0))
  for i in ${AT_RANK[@]+"${AT_RANK[@]}"}; do [[ "${AV_LABEL[$i]}" == *"(diagnostic)" ]] && continue; CT_IDX=$i; break; done # the diagnostic row is never chosen
  return 0
}
cdn_take() { # the best variant (CT_IDX) -> T_PEER, T_SNI, AT_EXTRA, CT_DESC
  T_PEER=${AV_PEER[$CT_IDX]}; T_SNI=${AV_SNI[$CT_IDX]}
  AT_EXTRA=$(at_cdn_lines "$CT_IDX"); CT_DESC=$(cdn_desc "$CT_IDX")
}
cdn_result_line() { printf 'Best: %s, %.1f/%.1f MB/s' "$(cdn_desc "$CT_IDX")" "${AR_DOWN[$CT_IDX]:-0}" "${AR_UP[$CT_IDX]:-0}"; }
cdn_wizard_tune() { # Iran wizard, token accepted: CDN carrier + domain + wattun >= 2.2.0 -> best edges and TLS settings, no questions
  local dom sni0=$T_SNI
  [ "$T_REV" = 1 ] && return 0
  is_cdn_carrier "$T_CARRIER" && cdn_ok || return 0
  dom=$(cdn_domain); [ -n "$dom" ] || return 0
  T_SNI=$dom
  echo
  [ "$T_CARRIER" = h2 ] && hint "h2 does not work through Cloudflare; use grpc or wss"
  AT_QUIET=1; AT_MB=20; AT_NOTE=''; AT_SKIP=''
  at_busy "the Cloudflare edges and TLS settings (ECH first) for $dom"
  cdn_tune 0
  at_idle
  if [ -n "$CT_IDX" ]; then
    [ "$CS_RAN" = 1 ] && cdn_scan_say
    [ "$NONINTERACTIVE" = 1 ] && at_table
    cdn_take; ok "$(cdn_result_line)"
  else
    T_SNI=$sni0
    warn "CDN tuning found nothing that works from here; keeping the token's settings."
  fi
  return 0
}
cdn_apply() { # name : write T_PEER, T_SNI and AT_EXTRA (fp / ech / tls-frag) into NAME.yml and restart
  local n=$1 l k v
  sed -i -E '/^(peer|fp|ech|ech-cache|tls-frag):/d' "$CONF/$n.yml"
  set_value "$n" peer "$T_PEER"
  [ -n "$(cfg "$n" sni)" ] || set_value "$n" sni "$T_SNI"
  [ -n "$(cfg "$n" host)" ] || set_value "$n" host "$T_SNI"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    k=${l%%: *}; v=${l#*: }; set_value "$n" "$k" "$v"
  done <<<"$AT_EXTRA"
  l=$(ech_cache_line "$n"); if [ -n "$l" ]; then set_value "$n" ech-cache "${l#*: }"; fi
  if [ "$AT_QUIET" = 1 ]; then systemctl restart "${WAT_PREFIX}@$n" >/dev/null 2>&1; return 0; fi
  step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
  if wait_link "$n" 25; then ok "CONNECTED (RTT ${LINK_RTT} ms)"; else warn "Not connected yet."; [ "$NONINTERACTIVE" = 1 ] && return 1; fi
  return 0
}
cdn_load_t() { # name -> T_CARRIER T_PEER T_KEY T_PATH T_SNI from NAME.yml ; rc 1 when it is not a CDN tunnel
  local n=$1 kf
  cdn_tunnel_p "$n" || return 1
  kf=$(cfg "$n" key-file); [ -r "$kf" ] || kf="$CONF/$n.key"
  T_CARRIER=$(cfg "$n" carrier); T_PEER=$(cfg "$n" peer); T_PATH=$(cfg "$n" path); T_REV=''; T_ICMP=''
  T_SNI=$(cfg "$n" sni); [ -n "$T_SNI" ] || T_SNI=$(cfg "$n" host)
  T_KEY=''; { IFS= read -r T_KEY <"$kf"; } 2>/dev/null
  [ -n "$T_KEY" ]
}
cdn_tune_cmd() { # name [full] : re-run the CDN tuning for an Iran CDN tunnel, show the table, apply the best
  local n=$1 full=0 cur new
  [ "${2:-}" = full ] && full=1
  cdn_ok || { err "CDN tuning needs wattun $CDN_MINVER or newer (this is $(bin_ver)). Run: $SELF update"; return 1; }
  cdn_load_t "$n" || { err "'$n' is not an Iran tunnel on a CDN carrier (ws, wss, h2, h2c, grpc) with a domain."; return 1; }
  cur=$(cfg "$n" peer)/$(cfg "$n" fp)/$(cfg "$n" ech)/$(cfg "$n" tls-frag)
  page "CDN tune" "$n"
  hint "Testing from this server. The running tunnel is not touched until you confirm."
  echo
  AT_QUIET=0; AT_MB=20; AT_NOTE=''; AT_SKIP=''; AT_AGAIN=''
  cdn_tune "$full" || { err "Could not prepare the test (is $AUTO_RUN writable?)."; return 1; }
  if [ -z "$CT_IDX" ]; then
    echo; err "No CDN variant got a working link from this server. Nothing was changed."
    hint "Check that the Kharej tunnel is running and the domain is proxied by Cloudflare."
    return 1
  fi
  at_table
  echo
  ok "$(cdn_result_line)"
  cdn_take
  new=$T_PEER/$(sed -n 's/^fp: //p' <<<"$AT_EXTRA")/$(sed -n 's/^ech: //p' <<<"$AT_EXTRA")/$(sed -n 's/^tls-frag: //p' <<<"$AT_EXTRA")
  if [ "$new" = "$cur" ]; then ok "'$n' already uses these settings."; return 0; fi
  # same TLS settings and only the edge list differs: keep the running tunnel if every edge it uses is still up
  # (a restart drops every open connection; edge order varies between scans)
  if [ "${new#*/}" = "${cur#*/}" ]; then
    local st; st=$(stats "$n" 2>/dev/null)
    if grep -q '"edges"' <<<"$st" && ! grep -q '"up": *false' <<<"$st"; then
      ok "'$n' already uses these settings and all its Cloudflare edges are up; not restarting."; return 0
    fi
  fi
  confirm "Apply to '$n'? (restarts the tunnel, open connections drop)" y || { warn "No change."; return 0; }
  cdn_apply "$n"
}
cdn_refresh_edges() { # name : unattended (auto-heal): same scan as cdn-tune (the engine tells which edges serve the domain over ECH), replace dead edge IPs, restart
  local n=$1 peer port dom c cur h bad=0 new
  cdn_ok && cdn_tunnel_p "$n" || return 0
  peer=$(cfg "$n" peer); c=$(cfg "$n" carrier)
  h=${peer%%,*}; h=${h%:*}; h=${h#[}; h=${h%]}
  [[ "$h" == *[A-Za-z]* ]] && [[ "$h" != *:* ]] && return 0 # plain domain: Cloudflare DNS already hands out live edges
  cdn_load_t "$n" || return 0
  dom=$T_SNI
  port=${peer%%,*}; port=${port##*:}
  AT_QUIET=1; CS_QUIET=1
  at_prep || return 0
  if ! cdn_scan "$dom" "$port" "$(cfg "$n" path)" "$c"; then
    at_cleanup; logger -t wattun-heal "cdn scan for $n: no Cloudflare edge to choose from"; return 0
  fi
  at_cleanup
  if [ "$CS_FALLBACK" = 1 ]; then logger -t wattun-heal "cdn scan for $n: no edge served the domain over ECH right now, peer left as is"; return 0; fi
  for cur in ${peer//,/ }; do
    h=${cur%:*}; h=${h#[}; h=${h%]}
    [[ " ${CS_REACH_IPS[*]} " == *" $h "* ]] || bad=1
  done
  [ "$bad" = 1 ] || { logger -t wattun-heal "cdn scan for $n: all edges still serve the domain"; return 0; }
  new=$(cdn_peer_list "$port")
  logger -t wattun-heal "cdn scan for $n: replacing dead edges, peer is now $new"
  set_value "$n" peer "$new" 2>/dev/null
  systemctl restart "${WAT_PREFIX}@$n" >/dev/null 2>&1
  return 0
}
# short CDN settings of an Iran tunnel: "wss · chrome · 3 edges" (second argument "short": "chrome · 3 edges"); nothing when default
cdn_summary() { # name [short]
  local n=$1 c fp ech fr peer cnt out=''
  cdn_tunnel_p "$n" || return 0
  c=$(cfg "$n" carrier); fp=$(cfg "$n" fp); ech=$(cfg "$n" ech); fr=$(cfg "$n" tls-frag); peer=$(cfg "$n" peer)
  cnt=$(awk -F, '{print NF}' <<<"$peer")
  [ -n "$fp" ] && [ "$fp" != go ] && out="$fp"
  [ -n "$ech" ] && [ "$ech" != off ] && out="${out:+$out · }ech"
  [ -n "$fr" ] && [ "$fr" != 0 ] && out="${out:+$out · }frag $fr"
  [ "$cnt" -gt 1 ] && out="${out:+$out · }$cnt edges"
  [ -n "$out" ] || return 0
  if [ "${2:-}" = short ]; then echo "$out"; else echo "$c · $out"; fi
}

new_tunnel() { # [kharej|iran]
  local pick=${1:-}
  if [ -z "$pick" ]; then
    page "New tunnel" "which server is this?"
    step_diagram
    echo
    say "  A tunnel connects two nodes across international network boundaries:"
    printf '    %s  %sKharej (Foreign VPS)%s   Where real service lives (Xray/panel)  %s[STEP 1 - DO FIRST]%s\n' "$(key_label 1)" "$BOLD" "$RST" "$YEL$BOLD" "$RST"
    printf '    %s  %sIran (Domestic VPS)%s    Where users/clients connect            %s(Needs token from step 1)%s\n' "$(key_label 2)" "$BOLD" "$RST" "$GRY" "$RST"
    echo
    printf '  %s?%s Which role does THIS server perform? %s[1=Kharej, 2=Iran, b=back]%s ' "$CYN" "$RST" "$GRY" "$RST"
    key_read; echo
    case "$KEY" in 1|k|K) pick=kharej ;; 2|i|I) pick=iran ;; *) return 0 ;; esac
  fi
  local rc=0
  case "$pick" in
    kharej) run_flow wizard_kharej; rc=$? ;;
    iran) run_flow wizard_iran; rc=$? ;;
    *) err "Unknown role '$pick' (use kharej or iran)."; return 1 ;;
  esac
  [ "$rc" -eq 130 ] || pause
  return 0
}

# ======================================================================================
#  Diagnosis, speed test, logs
# ======================================================================================
# ICMP path check (Iran side, icmp carrier): ping the Kharej at four packet sizes and read the tunnel's own packet
# counters, then say which cause fits. Uses plain ping, so it needs nothing installed on Kharej.
# Does this server itself block ICMP? Looks at the kernel switch and the local firewall rules (iptables, nftables).
# It cannot see a firewall in the provider's cloud panel. Prints one warning per finding; returns 0 when it found one.
# Does this iptables/nft rule line touch ICMP the tunnel uses? $1 = rule, $2 = space-padded list of type numbers in use.
# True when the rule has no type restriction or names a type in use; false for icmpv6 and unrelated types (time-exceeded...).
icmp_rule_hits() {
  local l=$1 used=$2 toks tok n
  case "$l" in *icmpv6*|*ipv6-icmp*) return 1 ;; esac
  case "$l" in *'! --icmp-type'*|*'icmp type !='*) return 0 ;; esac
  if [[ "$l" =~ --icmp-type[[:space:]]+([^[:space:]]+) ]]; then toks=${BASH_REMATCH[1]}
  elif [[ "$l" =~ icmp[[:space:]]+type[[:space:]]+(\{[^}]*\}|[^[:space:]]+) ]]; then toks=${BASH_REMATCH[1]}
  else return 0; fi
  toks=${toks//[\{\},]/ }
  for tok in $toks; do
    tok=${tok%%/*}
    case "$tok" in
      echo-reply|pong) n=0 ;; echo-request|ping) n=8 ;;
      timestamp-request) n=13 ;; timestamp-reply) n=14 ;;
      info-request) n=15 ;; info-reply) n=16 ;;
      address-mask-request) n=17 ;; address-mask-reply) n=18 ;;
      any) return 0 ;;
      *[!0-9]*) n=x ;; *) n=$tok ;;
    esac
    case "$used" in *" $n "*) return 0 ;; esac
  done
  return 1
}
local_icmp_check() { # [reverse-iran|-] [icmp-type] : icmp_echo_ignore_all does not stop the tunnel itself, only ping checks
  local found=1 rules hits l used=' 0 8 '
  case "${2:-echo}" in timestamp) used=' 0 8 13 14 ' ;; info) used=' 0 8 15 16 ' ;; mask) used=' 0 8 17 18 ' ;; esac
  if [ "${1:-}" != reverse-iran ] && [ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" = 1 ]; then
    hint "This server ignores plain ping (icmp_echo_ignore_all=1). The tunnel still works; only ping-based checks go unanswered."
  fi
  if command -v iptables >/dev/null 2>&1; then
    rules=$(iptables -S 2>/dev/null | grep -i icmp | grep -E -- '-j (DROP|REJECT)'); hits=''
    while IFS= read -r l; do [ -n "$l" ] && icmp_rule_hits "$l" "$used" && hits+="$l"$'\n'; done <<<"$rules"
    if [ -n "$hits" ]; then warn "iptables has ICMP rules that drop or reject:"; printf '%s' "$hits" | sed "s/^/        $GRY/; s/\$/$RST/"; found=0; fi
    if iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP' && ! iptables -S INPUT 2>/dev/null | grep -qi icmp; then
      warn "iptables INPUT drops everything not allowed, and no ICMP rule exists."; found=0
    fi
  fi
  if command -v nft >/dev/null 2>&1; then
    rules=$(nft list ruleset 2>/dev/null | grep -i icmp | grep -Ei 'drop|reject'); hits=''
    while IFS= read -r l; do [ -n "$l" ] && icmp_rule_hits "$l" "$used" && hits+="$l"$'\n'; done <<<"$rules"
    if [ -n "$hits" ]; then warn "nftables has ICMP rules that drop or reject:"; printf '%s' "$hits" | sed "s/^/        $GRY/; s/\$/$RST/"; found=0; fi
  fi
  return $found
}

icmp_path_report() { # name host
  local n=$1 host=$2 s sz loss ok_sizes='' bad_sizes='' maxok=0 pin pout ign fw
  echo
  say "  ${BOLD}ICMP path to $host${RST}"
  for sz in 56 200 400 640; do
    spin_start "ping with $sz bytes"
    loss=$(ping -c 4 -i 0.3 -W 2 -q -M do -s "$sz" "$host" 2>/dev/null | grep -o '[0-9]*% packet loss' | grep -o '^[0-9]*')
    spin_stop
    [ -n "$loss" ] || loss=100
    if [ "$loss" -le 25 ]; then ok_sizes="$ok_sizes $sz"; maxok=$sz; ok "$sz bytes: answered (loss ${loss}%)"
    else bad_sizes="$bad_sizes $sz"; err "$sz bytes: no answer (loss ${loss}%)"; fi
  done
  s=$(stats "$n"); pin=$(jget "$s" pkts_in); pout=$(jget "$s" pkts_out); pin=${pin:-0}; pout=${pout:-0}
  local_icmp_check - "$(cfg "$n" icmp-type)"
  echo
  say "  ${BOLD}What this means${RST}"
  if [ -z "$ok_sizes" ]; then
    err "Kharej does not answer ping at any size."
    hint "Either ICMP is blocked on the route, or Kharej drops it (cloud firewall, or net.ipv4.icmp_echo_ignore_all=1 there)."
    hint "Allow ICMP on Kharej's cloud firewall. If the route itself blocks ICMP right now, no ICMP tunnel can work until it opens;"
    hint "the tunnel reconnects by itself when it does (keep auto-heal on). Meanwhile, switch both sides to another carrier:"
    hint "$SELF → Kharej setup / Iran setup with udp, tcp or wss."
    hint "${BOLD}One-way block?${RST}${GRY} If Kharej CAN ping this server (run Diagnose on Kharej to check), the block is only on"
    hint "Iran's own pings. Switch BOTH sides to reverse ICMP: tunnel → Advanced settings → d (direction)."
  elif [ -n "$bad_sizes" ] && [ "$maxok" -lt 256 ]; then
    err "Only tiny packets pass: the route drops ICMP packets larger than about $maxok bytes, below the tunnel's 256-byte minimum."
    hint "An ICMP tunnel cannot work on this route. Use another carrier (udp, tcp, wss) on both sides."
  elif [ -n "$bad_sizes" ] && [ "$maxok" -lt 640 ]; then
    err "Small packets pass, big ones do not: the route drops packets larger than about $maxok bytes."
    hint "Set the same smaller size on BOTH sides: add  mtu: $maxok  to $CONF/NAME.yml on Kharej and Iran, then restart both."
  elif [ "$pout" -gt 0 ] && [ "$pin" -eq 0 ]; then
    err "Ping works at every size, but the tunnel's own packets get no answer."
    hint "Check, in this order: 1) both sides have the SAME key (paste the Kharej token on Iran again), 2) the same carrier and icmp-type,"
    hint "3) the Kharej tunnel is running ('$SELF status' there), 4) try icmp-type: timestamp on BOTH sides (some filters only"
    hint "pass plain echo, others only pass other ICMP types), 5) otherwise use another carrier (udp, tcp, wss)."
  elif [ "$pin" -gt 0 ]; then
    warn "Ping works and the tunnel did receive packets earlier, but it is silent now."
    hint "The route is probably blocking the answers right now. The tunnel reconnects by itself when they return (auto-heal helps)."
  else
    ok "The ICMP path looks fine. If the tunnel is still down, check the key and carrier on both sides."
  fi
}

test_tunnel() {
  local n=$1 cr peer host port s p r it e
  cr=$(cfg "$n" carrier); peer=$(cfg "$n" peer); r=$(role "$n")
  echo
  say "  ${BOLD}Diagnosing '$n'${RST} ($r · $cr)"
  echo
  if systemctl is-active -q "${WAT_PREFIX}@$n"; then ok "Service is running"
  else err "Service is not running"; journalctl -u "${WAT_PREFIX}@$n" -n 10 --no-pager -o cat 2>/dev/null; return; fi
  if [ "$r" = Iran ]; then
    host=${peer%:*}; port=${peer##*:}; [ "$host" = "$peer" ] && port=''
    if [ "$cr" = icmp ] && is_reverse "$n"; then
      hint "Reverse ICMP: Kharej sends the pings and this server answers, so Iran → Kharej ping does not matter."
      hint "Run Diagnose on Kharej: it pings this server, which is the direction this tunnel uses."
    elif [ "$cr" = icmp ]; then
      spin_start "Pinging $host"
      ping -c 3 -W 2 -q "$host" >/dev/null 2>&1; e=$?
      spin_stop
      if [ "$e" -eq 0 ]; then ok "Ping to $host works"
      else err "Ping to $host fails: ICMP is blocked or Kharej drops ping (check its firewall / cloud panel)."; fi
    elif is_pool "$cr" && is_reverse "$n"; then
      port=$(cfg "$n" listen); port=${port##*:}
      if [ -n "$port" ] && port_busy "$port" tcp; then ok "Port $port/tcp is listening here (Kharej connects to it)"
      else err "Nothing listens on ${port:-the carrier port}/tcp here, so Kharej cannot connect."; fi
      hint "Reverse: Kharej connects to this server. Run Diagnose on Kharej to test Kharej → Iran on port ${port:--}."
    elif [ "$cr" != udp ] && [ -n "$port" ]; then
      spin_start "Connecting to $host:$port"
      timeout 4 bash -c "</dev/tcp/$host/$port" 2>/dev/null; e=$?
      spin_stop
      if [ "$e" -eq 0 ]; then ok "TCP $host:$port is reachable"
      else err "Cannot open TCP $host:$port: port closed, firewall, or this carrier is filtered. Try another carrier."; fi
    fi
  fi
  if [[ "$cr" == *"+"* ]]; then
    local -a car_list
    IFS='+' read -ra car_list <<<"$cr"
    say "  ${BOLD}Multi-Carrier Bond Diagnostics (${#car_list[@]} paths):${RST}"
    local c_idx=0 cp cpeer chost cport
    for cp in "${car_list[@]}"; do
      c_idx=$((c_idx+1))
      cpeer=$(cfg "$n" "peer-$cp")
      [ -z "$cpeer" ] && cpeer=$peer
      chost=${cpeer%:*}; cport=${cpeer##*:}
      printf '    • Path #%d [%s]: ' "$c_idx" "$cp"
      if [ "$r" = Iran ]; then
        if [ "$cp" = icmp ]; then
          if ping -c 1 -W 2 -q "$chost" >/dev/null 2>&1; then
            printf '%sICMP ping OK%s\n' "$GRN" "$RST"
          else
            printf '%sICMP ping failed%s\n' "$RED" "$RST"
          fi
        elif [ "$cp" != udp ] && [ -n "$cport" ]; then
          if timeout 3 bash -c "</dev/tcp/$chost/$cport" 2>/dev/null; then
            printf '%sTCP %s:%s reachable%s\n' "$GRN" "$chost" "$cport" "$RST"
          else
            printf '%sTCP %s:%s blocked / unreachable%s\n' "$RED" "$chost" "$cport" "$RST"
          fi
        else
          printf '%sconfigured%s\n' "$CYN" "$RST"
        fi
      else
        printf '%sactive on server%s\n' "$CYN" "$RST"
      fi
    done
    echo
  fi
  s=$(stats "$n")
  if [ "$(jget "$s" alive)" = true ]; then
    ok "Tunnel link is CONNECTED (RTT $(ms "$(jget "$s" srtt_ms)") ms)"
    parse_carriers "$s"
    if [ "$CAR_COUNT" -gt 0 ]; then
      say "  ${BOLD}Live Path Telemetry:${RST}"
      local ci ccol cdot ctxt c_pct
      for ((ci=0; ci<CAR_COUNT; ci++)); do
        [ "${CAR_ALIVE[$ci]}" = true ] && { ccol=$GRN; cdot='●'; ctxt="UP"; } || { ccol=$RED; cdot='○'; ctxt="DOWN"; }
        [ "${CAR_MUTED[$ci]}" = true ] && { ccol=$GRY; cdot='○'; ctxt="MUTED"; }
        c_pct=$(awk -v sh="${CAR_SHARE[$ci]:-0}" 'BEGIN{printf "%.0f", sh*100}')
        printf '    %s%s %-6s%s %-10s  rtt: %4.0f ms  loss: %4.1f%%  share: %3s%%\n' \
          "$ccol" "$cdot" "$ctxt" "$RST" "${CAR_NAME[$ci]}" "${CAR_RTT[$ci]}" "$(awk -v l="${CAR_LOSS[$ci]:-0}" 'BEGIN{printf "%.1f", l*100}')" "$c_pct"
      done
      echo
    fi
  else
    if [ "$r" = Kharej ]; then err "No Iran server is connected yet"; else err "Tunnel link is DISCONNECTED"; fi
    say "  ${GRY}Common causes: different key on the two sides, different carrier/icmp-type, the other side not running,${RST}"
    say "  ${GRY}or the carrier is filtered on this route. Paste the Kharej token on Iran again to be sure.${RST}"
    # the whitelist tell: TCP to the peer still connects but the tunnel stays dead — a filtering hop above
    # TCP. Point at the one-command fix (no echo for reverse: Kharej dials in there, Iran can't fix it alone).
    if [ "$r" = Iran ] && is_pool "$cr" && ! is_reverse "$n" && [ -n "$host" ] && [ -n "$port" ] \
       && timeout 4 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
      echo
      warn "The carrier's TCP port is reachable, but the tunnel still cannot connect: this looks like filtering ABOVE TCP (an SNI allowlist)."
      hint "Turn on the resilience kit with one command:  $SELF blackout $n mci.ir   (replace mci.ir with an allowlisted name; fine-tuning: tunnel page -> o -> k)"
    fi
  fi
  if [ "$r" = Iran ] && [ "$cr" = icmp ] && [ "$(jget "$s" alive)" != true ]; then
    if is_reverse "$n"; then
      echo; say "  ${BOLD}Is this server blocking ICMP itself?${RST}"
      if local_icmp_check reverse-iran "$(cfg "$n" icmp-type)"; then hint "Fix the finding above: in reverse mode this server must receive Kharej's pings."
      else ok "No rule on this server blocks ICMP."; fi
    else icmp_path_report "$n" "${peer%:*}"; fi
  fi
  if [ "$r" = Kharej ] && [ "$(jget "$s" alive)" != true ]; then
    local seen idle
    seen=$(journalctl -u "${WAT_PREFIX}@$n" --since "-6 hours" --no-pager -o cat 2>/dev/null | grep -c 'new client session')
    idle=$(journalctl -u "${WAT_PREFIX}@$n" --since "-6 hours" --no-pager -o cat 2>/dev/null | grep -c 'idle, closing')
    echo
    if [ "$seen" -gt 0 ]; then
      warn "Iran reached this server $seen time(s) in the last 6 hours and went silent $idle time(s)."
      hint "Iran's packets arrive here, but this server's answers may not be reaching Iran. Run Diagnose on the Iran side for the path check."
    else
      warn "Iran never reached this server in the last 6 hours."
      if is_pool "$cr" && is_reverse "$n"; then
        hint "Check on Iran: the same key and carrier, that Iran listens on ${peer##*:}/tcp and that its firewall allows it."
      else
        hint "Check on Iran: the same key and carrier, and for icmp that ping to this server works. For other carriers the listen port must be open here."
      fi
    fi
    if is_pool "$cr" && is_reverse "$n" && [ "$peer" != "${peer%:*}" ]; then
      host=${peer%:*}; port=${peer##*:}
      echo
      spin_start "Connecting to $host:$port"
      timeout 4 bash -c "</dev/tcp/$host/$port" 2>/dev/null; e=$?
      spin_stop
      if [ "$e" -eq 0 ]; then ok "Kharej → Iran TCP $host:$port is reachable"
      else err "Cannot open TCP $host:$port from Kharej: Iran's firewall, the tunnel not running there, or this carrier is filtered Kharej → Iran."; fi
      hint "Some routes cut TCP in both directions (connects, then stalls after a few KB). Then reverse does not help: use icmp."
    fi
    if [ "$cr" = icmp ]; then
      echo
      say "  ${BOLD}Is this server blocking ICMP itself?${RST}"
      if local_icmp_check - "$(cfg "$n" icmp-type)"; then
        hint "Fix the finding above and test again."
      else
        ok "No rule on this server blocks ICMP (kernel switch and local firewall are fine)."
        hint "A firewall in your provider's cloud panel is outside what this check can see: make sure ICMP is allowed there."
      fi
      REPLY_V=''
      if is_reverse "$n"; then REPLY_V=$peer
      elif [ -t 0 ]; then echo; ask "Iran server IP, to test the direction Kharej → Iran (Enter to skip)" ""; fi
      if [ -n "$REPLY_V" ]; then
        echo
        spin_start "Pinging $REPLY_V"
        ping -c 3 -W 2 -q "$REPLY_V" >/dev/null 2>&1; e=$?
        spin_stop
        if [ "$e" -eq 0 ]; then ok "Kharej → Iran ping works ($REPLY_V answers)."
        else err "Kharej → Iran ping fails ($REPLY_V does not answer)."; fi
        if is_reverse "$n"; then
          [ "$e" -eq 0 ] && hint "Ping works, so check that Iran has reverse: true as well, and the same key and icmp-type."
          [ "$e" -ne 0 ] && hint "Reverse mode needs this ping to work. Check Iran's firewall, or switch both sides back to normal."
        else
          hint "Compare with Diagnose on Iran: it tests Iran → Kharej. If one direction works and the other does not, the block is one-way."
          [ "$e" -eq 0 ] && hint "If Iran → Kharej fails while this works, switch BOTH sides to reverse ICMP: Advanced settings → d."
        fi
      fi
    fi
  fi
  if [ "$r" = Iran ] && [ "$cr" = icmp ] && is_reverse "$n" && kreply_needed; then
    echo; warn "The kernel here answers every tunnel packet with a copy (wasted upload)."
    if [ -t 0 ]; then kreply_offer; else hint "Fix: $SELF → this tunnel → o → d (or see docs: Reverse ICMP)."; fi
  fi
  while IFS= read -r it; do
    [ -n "$it" ] || continue
    if [ "$r" = Iran ]; then
      p=$(spec_L "$it")
      if port_busy "$p" "$(spec_P "$it")"; then ok "Iran port $p/$(spec_P "$it") is listening"; else warn "Nothing listens on Iran port $p/$(spec_P "$it")"; fi
    else
      p=$(spec_T "$it"); [ "$(spec_P "$it")" = udp ] && continue
      if timeout 2 bash -c "</dev/tcp/127.0.0.1/$p" 2>/dev/null; then ok "Target 127.0.0.1:$p answers"; else warn "No service on 127.0.0.1:$p (start your panel/service)"; fi
    fi
  done < <(yml_maps "$n")
  if [ "$r" = Iran ] && [ "$(jget "$s" alive)" = true ]; then speed_test "$n"
  elif [ "$r" = Kharej ]; then echo; hint "Speed test: run Diagnose on the Iran side (it tests both directions)."; fi
  e=$(journalctl -u "${WAT_PREFIX}@$n" -n 200 --no-pager -o cat 2>/dev/null | grep -iE "error|fail|denied|refused|restart needed" | tail -5)
  [ -n "$e" ] && { echo; warn "Recent problems in the log:"; printf '%s\n' "$e" | sed "s/^/      $GRY/; s/\$/$RST/"; }
  return 0
}

# 10 MB each way through the live tunnel (wattun >= 1.8.1 on both sides; uses /speedtest on the local metrics address).
speed_test() { # name [mb]
  local n=$1 mb=${2:-10} m d r label secs mbs mbit er
  m=$(cfg "$n" metrics); [ -n "$m" ] || { warn "Speed test needs a metrics address in $n.yml."; return; }
  echo
  say "  ${BOLD}Speed test${RST}: ${mb} MB each way through the tunnel"
  for d in down up; do
    [ "$d" = down ] && label="Download (Kharej → Iran)" || label="Upload   (Iran → Kharej)"
    spin_start "$label"
    r=$(curl -fs --noproxy '*' --max-time 200 "http://$m/speedtest?dir=$d&mb=$mb")
    spin_stop
    if [ -z "$r" ]; then
      if [ -z "$(stats "$n")" ]; then err "$label: tunnel '$n' is not running."
      else warn "Speed test not available: this tunnel runs wattun older than 1.8.1. Update and restart both sides."; fi
      return
    fi
    if [ "$(jget "$r" ok)" = true ]; then
      secs=$(jget "$r" seconds); mbs=$(jget "$r" mb_per_s); mbit=$(jget "$r" mbit_per_s)
      printf '  %s✔%s %s  %s%5.1f MB/s%s  (%.0f Mbit/s, %s MB in %.1f s)\n' "$GRN" "$RST" "$label" "$GRN$BOLD" "$mbs" "$RST" "$mbit" "$mb" "$secs"
    else
      er=$(grep -o '"error":"[^"]*"' <<<"$r" | cut -d'"' -f4)
      printf '  %s✘%s %s  %sfailed%s  %s\n' "$RED" "$RST" "$label" "$RED" "$RST" "${er:-unknown error}"
      [[ "$er" == *"1.8.1"* ]] && warn "Kharej runs an older wattun: update it ($SELF update) and restart its tunnel."
    fi
  done
}

logs_menu() {
  local n=$1
  echo
  printf '  %s last 100 lines  %s follow live (Ctrl+C stops)\n' "$(key_label 1)" "$(key_label 2)"
  printf '  %s problems only   %s since last start\n' "$(key_label 3)" "$(key_label 4)"
  printf '  %s?%s Choice %s[1]%s ' "$CYN" "$RST" "$GRY" "$RST"
  key_read; echo; echo
  case "$KEY" in
    1|enter) journalctl -u "${WAT_PREFIX}@$n" -n 100 --no-pager -o short-iso ;;
    2) journalctl -u "${WAT_PREFIX}@$n" -f -o short-iso ;;
    3) journalctl -u "${WAT_PREFIX}@$n" -n 2000 --no-pager -o short-iso | grep -iE "error|fail|denied|refused|lost|restart" | tail -50 ;;
    4) journalctl -u "${WAT_PREFIX}@$n" -b --no-pager -o short-iso | tail -200 ;;
    *) return 0 ;;
  esac
}

# ======================================================================================
#  Live monitor (all tunnels, 2 s refresh, sparkline of the rate)
# ======================================================================================
declare -A HIST
hist_push() { # name value
  local arr v=${2%%.*}; [[ "$v" =~ ^[0-9]+$ ]] || v=0
  read -ra arr <<<"${HIST[$1]:-}"
  arr+=("$v")
  [ "${#arr[@]}" -gt 16 ] && arr=("${arr[@]:1}")
  HIST[$1]="${arr[*]}"
}
spark() { # "v1 v2 ..." -> ▁▂▃▅▇
  local -a vals chars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  local max=0 v res=''
  read -ra vals <<<"$1"
  for v in "${vals[@]}"; do [ "$v" -gt "$max" ] && max=$v; done
  for v in "${vals[@]}"; do
    if [ "$max" -eq 0 ]; then res+=${chars[0]}; else res+=${chars[$((v*7/max))]}; fi
  done
  printf '%s' "$res"
}
mon_frame() {
  local n r any=0 sp rate pad
  printf '\n  %s◆%s %s %s›%s %sLive monitor%s   %s%s · every 2 s · any key = back%s\e[K\n' "$CYN" "$RST" "$LOGO" "$GRY" "$RST" "$BOLD" "$RST" "$GRY" "$(date '+%H:%M:%S')" "$RST"
  printf '  %s%s%s\e[K\n' "$GRY" "$(rep ─ 74)" "$RST"
  printf '  %sNAME        STATE         RTT     RATE         HISTORY             LOAD%s\e[K\n' "$GRY" "$RST"
  for n in $(tunnels); do
    any=1; r=$(role "$n"); tinfo "$n"; state_cell "$r" "$TI_STATE"
    hist_push "$n" "$TI_RATE"; sp=$(spark "${HIST[$n]}")
    rate=$(human "$TI_RATE"); pad=$((16-${#sp}))
    printf '  %-11s %s%s %-12s%s %5s   %-10s  %s%s%*s%s  %s\e[K\n' "${n:0:11}" "$SC_COL" "$SC_DOT" "$SC_TXT" "$RST" \
      "$([ "$TI_STATE" = up ] && printf '%.0f ms' "$TI_RTT")" "$([ "$TI_STATE" != stopped ] && echo "$rate/s")" "$CYN" "$sp" "$pad" '' "$RST" \
      "$([ "$TI_STATE" = stopped ] || { [ "$r" = Kharej ] && echo "$TI_SESS clients" || echo "$TI_STREAMS streams"; })"
  done
  [ "$any" = 0 ] && printf '  %sNo tunnels yet. Press any key, then n to create one.%s\e[K\n' "$GRY" "$RST"
  printf '\e[K\n'
}
live_monitor() {
  local rc
  if [ "$IS_TTY" != 1 ]; then mon_frame | sed 's/\x1b\[K//g'; return 0; fi
  cur_hide; printf '\e[2J'
  while :; do
    printf '\e[H'; mon_frame; printf '\e[J'
    IFS= read -rsn1 -t 2 KEY; rc=$?
    [ "$rc" -le 128 ] && break
  done
  cur_show
}

# ======================================================================================
#  Tunnel actions
# ======================================================================================
status_all() { # plain, scriptable list
  local n any=0
  for n in $(tunnels); do any=1; status_row "$n"; done
  [ "$any" = 1 ] || { warn "No tunnels yet. Start with Kharej: run $SELF and press n."; return 1; }
}
status_row() {
  local n=$1 r cr load
  r=$(role "$n"); cr=$(carrier_label "$n"); tinfo "$n"; state_cell "$r" "$TI_STATE"
  load=''; [ "$TI_STATE" != stopped ] && { [ "$r" = Kharej ] && load="clients $TI_SESS" || load="streams $TI_STREAMS"; }
  printf '  %-12s %-6s %-5s %s%s %-12s%s %-6s %-11s %s\n' "${n:0:12}" "$r" "$cr" "$SC_COL" "$SC_DOT" "$SC_TXT" "$RST" \
    "$([ "$TI_STATE" = up ] && printf '%.0fms' "$TI_RTT" || echo -)" "$load" "$(ports_summary "$n" 17)"
}
tunnel_card() {
  local n=$1 r cr peer lis par sub='' srv_act srv_up srv_en routing_txt
  r=$(role "$n"); cr=$(cfg "$n" carrier); peer=$(cfg "$n" peer); lis=$(cfg "$n" listen)
  par=$(companion_of "$n")
  tinfo "$n"; state_cell "$r" "$TI_STATE"
  srv_act=$(systemctl is-active "${WAT_PREFIX}@$n" 2>/dev/null || echo inactive)
  srv_up=$(uptime_of "$n")
  srv_en=$(systemctl is-enabled "${WAT_PREFIX}@$n" 2>/dev/null | head -1)

  if [ "$r" = Kharej ]; then routing_txt="Allows: $(ports_summary "$n" 24)"; else routing_txt="Ports: $(ports_summary "$n" 25)"; fi
  if [ -n "$par" ]; then box_top "Tunnel Overview: $n (reverse side of $par)"; else box_top "Tunnel Overview: $n"; fi

  # Section 1: Overview & System
  row_2col "Status:  ${SC_COL}${SC_DOT} ${SC_TXT}${RST}" "Role:      ${BOLD}$r${RST}"
  row_2col "Service: ● ${srv_act} (${srv_up})" "Autostart: ${srv_en:-disabled}"
  row_2col "Carrier: ${BOLD}$cr${RST}" "$routing_txt"

  # Sub-role details
  if [ -n "$par" ]; then
    box_row "  ${GRY}auto reverse → Iran $(cfg "$n" peer-icmp)${RST}"
  elif is_auto_kharej "$n"; then
    if [ -f "$CONF/$n-r.yml" ]; then sub="reverse side: $n-r (Iran $(cfg "$n-r" peer-icmp))"
    elif systemctl is-active -q "${WAT_PREFIX}-autowatch-$n.service" 2>/dev/null; then sub="watching for Iran's first connection (then $n-r is created)"
    else sub="Iran's IP not learned yet: $SELF auto-ip $n IRAN_IP"; fi
    box_row "  ${GRY}$sub${RST}"
  elif [ "$cr" = icmp ] && is_reverse "$n"; then
    if [ "$r" = Iran ]; then box_row "  ${GRY}(reverse) ← pinged by ${peer:--}${RST}"; else box_row "  ${GRY}(reverse) → pings Iran ${peer:--}${RST}"; fi
  elif is_pool "$cr" && is_reverse "$n"; then
    if [ "$r" = Iran ]; then box_row "  ${GRY}(reverse) ← Kharej connects on ${lis:-:-}${RST}"; else box_row "  ${GRY}(reverse) → connects to Iran ${peer:--}${RST}"; fi
  elif [ "$r" = Iran ]; then
    box_row "  ${GRY}→ remote peer: ${peer:--}${RST}"
  else
    [ -n "$lis" ] && box_row "  ${GRY}listening on ${lis}${RST}"
  fi

  sub=$(cdn_summary "$n"); [ -n "$sub" ] && box_row "  ${GRY}CDN: $sub${RST}"
  if [ "$r" = Iran ] && [ "$(uname -s)" = Linux ]; then
    local fks=$(cfg "$n" fake-sni) gov=$(cfg "$n" governor) rot=$(cfg "$n" pool-rotate) dl=$(cfg "$n" dns-listen)
    if [ -n "$fks" ] || [ "$gov" = true ] || [ -n "$rot" ] || [ -n "$dl" ]; then
      box_row "  Anti-Censor: $(detect_preset "$n")${fks:+ (fake-sni $fks)}${dl:+ (dns $dl)}"
    fi
  fi
  local bmode=$(cfg "$n" bond-mode)
  [ -n "$bmode" ] && box_row "  Bond Mode: ${BOLD}$bmode${RST}"
  if [ -f "$CONF/$n.sla" ]; then
    local min_r=$(grep '^sla_min_rate_kbps=' "$CONF/$n.sla" 2>/dev/null | cut -d= -f2)
    local max_rtt=$(grep '^sla_max_rtt_ms=' "$CONF/$n.sla" 2>/dev/null | cut -d= -f2)
    local max_l=$(grep '^sla_max_loss_pct=' "$CONF/$n.sla" 2>/dev/null | cut -d= -f2)
    box_row "  SLA Target: min ${min_r:-0}kbps · max ${max_rtt:-0}ms · max ${max_l:-0}% loss"
  fi

  # Section 2: Real-time telemetry (when not stopped)
  if [ "$TI_STATE" != stopped ]; then
    box_mid
    box_row "${BOLD}Real-Time Network Telemetry:${RST}"
    row_2col "  Latency:     $(ms "$TI_RTT") ms (min $(ms "$(jget "$TI_RAW" min_rtt_ms)"))" "Throughput:  rate $(human "$TI_RATE")/s"
    row_2col "  Packet Loss: $(jget "$TI_RAW" loss_pct)%" "Retrans:     $(jget "$TI_RAW" retrans) pkts"
    row_2col "  Streams:     $TI_STREAMS active" "UDP Flows:   $(jget "$TI_RAW" dgram_flows) active"
    row_2col "  Total Data:  ↓$(human "$TI_IN")  ↑$(human "$TI_OUT")" "Sessions:    $TI_SESS active"
    if [ "$TI_CAR_COUNT" -gt 0 ]; then
      box_mid
      box_row "${BOLD}Bonded Carrier Paths:${RST}"
      local ci ccol cdot ctxt c_pct
      for ((ci=0; ci<TI_CAR_COUNT; ci++)); do
        if [ "${CAR_MUTED[$ci]}" = true ]; then
          ccol=$GRY; cdot='○'; ctxt="MUTED"
        elif [ "${CAR_ALIVE[$ci]}" = true ]; then
          ccol=$GRN; cdot='●'; ctxt="UP"
        else
          ccol=$RED; cdot='○'; ctxt="DOWN"
        fi
        c_pct=$(awk -v sh="${CAR_SHARE[$ci]:-0}" 'BEGIN{printf "%.0f", sh*100}')
        box_row "  ${ccol}${cdot} ${ctxt}${RST} [path $ci] ${CAR_NAME[$ci]} · rtt $(ms "${CAR_RTT[$ci]}") ms · loss $(awk -v l="${CAR_LOSS[$ci]:-0}" 'BEGIN{printf "%.1f", l*100}')% · traffic share ${c_pct}%"
      done
    fi
  fi
  box_bot
}
show_token() {
  if [ -f "$CONF/$1.token" ]; then refresh_token "$1"; printf '%s%s%s\n' "$BOLD$YEL" "$(cat "$CONF/$1.token")" "$RST"
  else err "No token stored for '$1' (tokens exist only on Kharej tunnels)."; return 1; fi
  warn "The token contains the key — treat it like a password: anyone who sees it can use the tunnel."
}
edit_ports() { # name
  local n=$1 r old=() it i pub=() before par
  par=$(companion_of "$n"); [ -n "$par" ] && { hint "$n is the reverse side of $par: editing the ports of $par."; n=$par; }
  r=$(role "$n")
  load_maps "$n"; old=("${MAPS[@]+"${MAPS[@]}"}")
  PE_ROLE=$r; PE_TUNNEL=$n; PE_ALLOW=(); PE_OWNED=(); PE_MSG=''
  for it in ${old[@]+"${old[@]}"}; do PE_OWNED+=("$(spec_L "$it")/$(spec_P "$it")"); done
  systemctl is-active -q "${WAT_PREFIX}@$n" 2>/dev/null || PE_OWNED=()
  port_editor || { warn "No changes saved."; return 0; }
  write_ports "$n" || { err "Could not write the config."; return 1; }
  [ "$r" = Kharej ] && refresh_token "$n"
  [ "$r" = Kharej ] && [ -f "$CONF/$n-r.yml" ] && is_auto_kharej "$n" && write_ports "$n-r"
  ok "Saved: $(ports_summary "$n" 60)"
  hint "Applied within 3 seconds, no restart, no dropped users."
  if [ "$r" = Iran ]; then
    before=" ${PE_OWNED[*]-} "
    for ((i=0; i<${#MAPS[@]}; i++)); do
      it="$(spec_L "${MAPS[$i]}")/$(spec_P "${MAPS[$i]}")"
      case "$before" in *" $it "*) ;; *) pub+=("$it") ;; esac
    done
    [ "${#pub[@]}" -gt 0 ] && fw_open "${pub[*]}"
    hint "On Kharej, make sure the target ports are allowed (or its allowed list is empty)."
  else
    warn "The token was updated with the new allowed ports. Iran servers already connected keep working."
  fi
}
change_peer() {
  local n=$1 cr old v op np
  cr=$(cfg "$n" carrier); old=$(cfg "$n" peer)
  ask_ok "New Kharej address (host or host:port)" "$old" v_host || return 1
  v=$REPLY_V
  if [ "$cr" != icmp ]; then
    op=${old##*:}; [ "$op" = "$old" ] && op=''
    if [[ "$v" != *:* ]]; then
      [ -n "$op" ] || { err "This carrier needs host:port (for example example.com:443)."; return 1; }
      v="$v:$op"; hint "No port given: keeping port $op."
    fi
    v_port "${v##*:}" >/dev/null 2>&1 || { err "The Kharej address needs a valid port, like host:443."; return 1; }
    np=$((10#${v##*:}))
    if is_pool "$cr" && is_reverse "$n" && [ "$np" != "$op" ]; then
      # reverse: Iran listens on the carrier port, so it follows the peer port
      if listen_blocked tcp "$np"; then err "Port $np/tcp is already in use here by $(listen_conflict_desc tcp "$np")."; return 1; fi
      set_value "$n" listen "\":$np\""
      fw_open "$np/tcp"
    fi
    v="${v%:*}:$np"
  fi
  set_value "$n" peer "$v"
  step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n" || return 1
  wait_link "$n" 20 && ok "CONNECTED (RTT ${LINK_RTT} ms)" || warn "Not connected yet."
}
change_key() {
  local n=$1 k t
  if [ "$(role "$n")" = Kharej ]; then
    warn "A new key disconnects every Iran server until it gets the new token."
    confirm "Generate a NEW key and token?" n || return 0
    k=$(new_key); ( umask 077; printf '%s\n' "$k" >"$CONF/$n.key" )
    if [ -f "$CONF/$n.token" ] && read_token "$(cat "$CONF/$n.token")"; then
      make_token "$T_CARRIER" "$T_PEER" "$k" "$T_PATH" "$T_SNI" "$T_ICMP" "$T_PORTS" "$T_REV" "$T_AUTO" >"$CONF/$n.token"
    fi
    step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
    [ -f "$CONF/$n-r.yml" ] && is_auto_kharej "$n" && step "Restarting ${WAT_PREFIX}@$n-r" systemctl restart "${WAT_PREFIX}@$n-r"
    echo; ok "New token (paste it on every Iran server):"; echo
    show_token "$n"
  else
    ask_ok "Paste the new token from Kharej" "" v_token || return 1
    t=$REPLY_V; read_token "$t"
    if [ "$T_CARRIER" = auto ]; then # new auto token: keep the key and token, the variant is chosen by the test
      printf '%s\n' "$T_KEY" >"$CONF/$n.key"
      ( umask 077; printf '%s\n' "$t" >"$CONF/$n.auto" ); chmod 600 "$CONF/$n.auto"
      step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
      hint "This is an auto token. Test again and pick the best connection: $SELF auto-test $n"
      return 0
    fi
    ( umask 077; printf '%s\n' "$T_KEY" >"$CONF/$n.key" ); set_value "$n" peer "$T_PEER"
    step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n" || return 1
    wait_link "$n" 20 && ok "CONNECTED (RTT ${LINK_RTT} ms)" || warn "Not connected yet."
  fi
}
delete_tunnel() {
  local n=$1
  warn "This stops '$n' and deletes its config, key and token."
  if [ "$NONINTERACTIVE" = 1 ]; then REPLY_V=$n # --yes is the confirmation
  else ask "Type the tunnel name to confirm (empty = cancel)" ""; fi
  [ "$REPLY_V" = "$n" ] || { warn "Not deleted."; return 1; }
  if [ -f "$CONF/$n-r.yml" ] && is_auto_kharej "$n"; then # the auto reverse companion goes with its parent
    systemctl disable --now "${WAT_PREFIX}@$n-r" >/dev/null 2>&1
    rm -f "$CONF/$n-r".yml "$CONF/$n-r".ech
    ok "Reverse side '$n-r' deleted."
  fi
  systemctl stop "${WAT_PREFIX}-autowatch-$n.service" >/dev/null 2>&1
  systemctl disable --now "${WAT_PREFIX}@$n" >/dev/null 2>&1
  rm -f "$CONF/$n".yml "$CONF/$n".ech "$CONF/$n".key "$CONF/$n".token "$CONF/$n".auto "$RUN/$n.down" "$RUN/$n.cycles" "$RUN/$n.retest"
  ok "Tunnel '$n' deleted."
  reverse_iran_left || kreply_restore
  return 0
}
# Toggle reverse ICMP on one side. Kharej keeps Iran's IP as its peer and puts the flag in the token.
set_direction() { # name
  local n=$1 r ip cr pp
  r=$(role "$n"); cr=$(cfg "$n" carrier)
  reverse_hint "$cr"
  if is_pool "$cr"; then
    if is_reverse "$n"; then
      confirm "Switch '$n' back to the normal direction (Iran connects to Kharej)?" n || return 1
      if [ "$r" = Kharej ]; then
        pp=$(cfg "$n" peer); pp=${pp##*:}
        v_port "$pp" >/dev/null 2>&1 || { err "Cannot read the carrier port from peer."; return 1; }
        set_value "$n" listen "\":$pp\""
        unset_value "$n" peer; unset_value "$n" sni; unset_value "$n" host
        fw_open "$pp/tcp"
      else
        unset_value "$n" listen
      fi
      unset_value "$n" reverse
    else
      confirm "Switch '$n' to reverse (Kharej connects out to Iran)?" n || return 1
      if [ "$r" = Kharej ]; then
        pp=$(cfg "$n" listen); pp=${pp##*:}
        v_port "$pp" >/dev/null 2>&1 || { err "Cannot read the carrier port from listen."; return 1; }
        ask_ok "Iran server IPv4 address" "" v_ipv4 || return 1; ip=$REPLY_V
        set_value "$n" peer "$ip:$pp"
        unset_value "$n" listen
        if [ -f "$CONF/$n.token" ] && read_token "$(cat "$CONF/$n.token")" && [ -n "$T_SNI" ]; then
          set_value "$n" sni "$T_SNI"; set_value "$n" host "$T_SNI"
        fi
      else
        pp=$(cfg "$n" peer); pp=${pp##*:}
        v_port "$pp" >/dev/null 2>&1 && [ "$pp" != "$(cfg "$n" peer)" ] || { err "The peer has no carrier port, so reverse cannot be set up."; return 1; }
        pp=$((10#$pp))
        if listen_blocked tcp "$pp"; then err "Port $pp/tcp is already in use here by $(listen_conflict_desc tcp "$pp")."; return 1; fi
        set_value "$n" listen "\":$pp\""
        fw_open "$pp/tcp"
      fi
      set_value "$n" reverse true
    fi
  elif is_reverse "$n"; then
    confirm "Switch '$n' back to the normal direction (Iran sends the pings)?" n || return 1
    unset_value "$n" reverse
    [ "$r" = Kharej ] && unset_value "$n" peer
  else
    confirm "Switch '$n' to reverse (Kharej sends the pings)?" n || return 1
    if [ "$r" = Kharej ]; then
      ask_ok "Iran server IPv4 address" "" v_ipv4 || return 1; ip=$REPLY_V
      set_value "$n" peer "$ip"
    fi
    set_value "$n" reverse true
  fi
  if [ "$r" = Iran ] && [ "$cr" = icmp ]; then
    if is_reverse "$n"; then kreply_offer; else reverse_iran_left || kreply_restore; fi
  fi
  if [ "$r" = Kharej ] && [ -f "$CONF/$n.token" ] && read_token "$(cat "$CONF/$n.token")"; then
    T_REV=''; is_reverse "$n" && T_REV=1
    make_token "$T_CARRIER" "$T_PEER" "$T_KEY" "$T_PATH" "$T_SNI" "$T_ICMP" "$T_PORTS" "$T_REV" "$T_AUTO" >"$CONF/$n.token"
  fi
  warn "Change the direction on the $([ "$r" = Kharej ] && echo Iran || echo Kharej) side too (Advanced settings → d), or the link stays down."
  return 0
}
adv_menu() { # name : max-mbps, fec, bind, icmp-type, direction
  local n=$1 r changed=0 v cr
  r=$(role "$n"); cr=$(cfg "$n" carrier)
  while :; do
    page "Advanced settings" "$n"
    summary_line "max-mbps" "$(cfg "$n" max-mbps | sed 's/^$/16 (default)/')"
    summary_line "sessions" "$(cfg "$n" sessions | sed 's/^$/1 (default)/')"
    summary_line "conns" "$(cfg "$n" conns | sed 's/^$/8 (default)/')"
    summary_line "mtu" "$(cfg "$n" mtu | sed 's/^$/auto (default)/')"
    summary_line "fec" "$(cfg "$n" fec | sed 's/^$/off (default)/')"
    [ "$r" = Iran ] && summary_line "bind" "$(cfg "$n" bind | sed 's/^$/0.0.0.0 (default)/')"
    [ "$cr" = icmp ] && summary_line "icmp-type" "$(cfg "$n" icmp-type | sed 's/^$/echo (default)/')"
    if rev_capable "$cr"; then
      if [ "$cr" = icmp ]; then summary_line "direction" "$(is_reverse "$n" && echo "reverse (Kharej sends the pings)" || echo "normal (Iran sends the pings)")"
      else summary_line "direction" "$(is_reverse "$n" && echo "reverse (Kharej connects to Iran)" || echo "normal (Iran connects to Kharej)")"; fi
    fi
    if [ "$r" = Iran ] && [ "$(uname -s)" = Linux ]; then
      if is_pool "$cr"; then
        local fks=$(cfg "$n" fake-sni) fkm=$(cfg "$n" fake-mode)
        local fkl=${fks:-off}${fkm:+ ($fkm mode)}
        [ "$fkm" = ttl ] && fkl="$fkl, ttl $(cfg "$n" fake-ttl || echo auto)"
        summary_line "fake-sni" "$fkl"
        summary_line "pool-rotate" "$(cfg "$n" pool-rotate | sed 's/^$/off (default)/')"
        [ -n "$(cfg "$n" pool-rotate-bytes)" ] && summary_line "pool-rotate-bytes" "$(cfg "$n" pool-rotate-bytes)"
        case "$cr" in
          tls|wss|h2|grpc)
            [ -n "$(cfg "$n" ech)" ] && summary_line "ech" "$(cfg "$n" ech)" ;;
        esac
      elif [ "$cr" = icmp ]; then
        [ -n "$(cfg "$n" governor)" ] && summary_line "governor" "$([ "$(cfg "$n" governor)" = true ] && echo on || echo off)"
      fi
    fi
    echo
    printf '  %s  speed   %s  sessions   %s  conns   %s  MTU   %s  FEC   ' "$(key_label m)" "$(key_label s)" "$(key_label c)" "$(key_label u)" "$(key_label f)"
    [ "$r" = Iran ] && printf '%s  bind   ' "$(key_label a)"
    [ "$cr" = icmp ] && printf "%s  ICMP type   " "$(key_label i)"
    rev_capable "$cr" && printf "%s  direction   " "$(key_label d)"
    [ "$r" = Iran ] && [ "$(uname -s)" = Linux ] && printf '%s  resilience   ' "$(key_label k)"
    printf '%s  back\n' "$(key_label b)"
    key_read
    case "$KEY" in
      m) echo; ask_ok "Speed ceiling in MB/s (- or 0 or default = unset)" "$(cfg "$n" max-mbps)" v_mbps_adv || continue
         case "$REPLY_V" in -|0|default) REPLY_V='' ;; esac
         if [ -z "$REPLY_V" ]; then unset_value "$n" max-mbps; else set_value "$n" max-mbps "$REPLY_V"; fi; changed=1 ;;
      s) echo; ask_ok "Sessions count 1-64 (- or 0 or default = unset)" "$(cfg "$n" sessions)" v_sessions || continue
         case "$REPLY_V" in -|0|default) REPLY_V='' ;; esac
         if [ -z "$REPLY_V" ]; then unset_value "$n" sessions; else set_value "$n" sessions "$REPLY_V"; fi; changed=1 ;;
      c) echo; ask_ok "Conns count 1-128 (- or 0 or default = unset)" "$(cfg "$n" conns)" v_conns || continue
         case "$REPLY_V" in -|0|default) REPLY_V='' ;; esac
         if [ -z "$REPLY_V" ]; then unset_value "$n" conns; else set_value "$n" conns "$REPLY_V"; fi; changed=1 ;;
      u) echo; ask_ok "MTU 576-65535 (- or 0 or default = unset)" "$(cfg "$n" mtu)" v_mtu || continue
         case "$REPLY_V" in -|0|default) REPLY_V='' ;; esac
         if [ -z "$REPLY_V" ]; then unset_value "$n" mtu; else set_value "$n" mtu "$REPLY_V"; fi; changed=1 ;;
      k) [ "$r" = Iran ] || continue; anticensor_menu "$n" ;;
      f) echo; ask_ok "FEC: off or auto" "$(cfg "$n" fec | sed 's/^$/off/')" v_fec || continue
         if [ "$REPLY_V" = off ]; then unset_value "$n" fec; else set_value "$n" fec "$REPLY_V"; fi; changed=1 ;;
      a) [ "$r" = Iran ] || continue; echo; ask_ok "Bind address" "$(cfg "$n" bind | sed 's/^$/0.0.0.0/')" v_bind || continue
         if [ "$REPLY_V" = 0.0.0.0 ]; then unset_value "$n" bind; else set_value "$n" bind "$REPLY_V"; fi; changed=1 ;;
      i) [ "$cr" = icmp ] || continue; echo; hint "Must match the other side."; ask_ok "ICMP type" "$(cfg "$n" icmp-type | sed 's/^$/echo/')" v_icmp || continue
         if [ "$REPLY_V" = echo ]; then unset_value "$n" icmp-type; else set_value "$n" icmp-type "$REPLY_V"; fi; changed=1 ;;
      d) rev_capable "$cr" || continue; echo
         # applied at once, so the direction never sits in the file without running
         set_direction "$n" && step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
         pause ;;
      b|0|q|enter|esc) break ;;
      *) : ;;
    esac
  done
  # Every setting here needs a restart; apply it automatically (an unapplied change only logs "restart needed").
  if [ "$changed" = 1 ]; then
    hint "Applying: restarting '$n' (open connections drop and reconnect)."
    step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
  fi
  return 0
}

# ======================================================================================
#  Automated Anti-Censorship Testing & Verification
# ======================================================================================
anticensor_test() {
  local n=$1 r cr peer s alive=false srtt pkts_in pkts_out fprof ech_st gov_st
  [ -f "$CONF/$n.yml" ] || { err "No tunnel named '$n'."; return 1; }
  r=$(role "$n"); cr=$(cfg "$n" carrier); peer=$(cfg "$n" peer)
  [ "$r" = Iran ] || { err "'$n' is not an Iran tunnel (anti-censorship verification is client-only)."; return 1; }
  echo
  say "  ${BOLD}Anti-Censorship & Link Verification for '$n'${RST} ($r · $cr)"
  echo

  if ! systemctl is-active -q "${WAT_PREFIX}@$n" 2>/dev/null; then
    warn "Service ${WAT_PREFIX}@$n is stopped. Starting it now..."
    systemctl start "${WAT_PREFIX}@$n" 2>/dev/null
    sleep 1
  fi

  # Active profile report
  say "  ${BOLD}Active Anti-Censorship Settings:${RST}"
  local fks=$(cfg "$n" fake-sni) fkm=$(cfg "$n" fake-mode) fkt=$(cfg "$n" fake-ttl)
  local rot=$(cfg "$n" pool-rotate) rbytes=$(cfg "$n" pool-rotate-bytes)
  local ech=$(cfg "$n" ech) gov=$(cfg "$n" governor)
  local dl=$(cfg "$n" dns-listen) sip=$(cfg "$n" src-ip)

  if [ -n "$fks" ]; then
    printf '    • Fake-SNI:     %s (%s mode%s)\n' "$fks" "${fkm:-seq}" "${fkt:+, ttl $fkt}"
  else
    printf '    • Fake-SNI:     %s\n' "${GRY}disabled${RST}"
  fi
  [ -n "$rot" ] && printf '    • Pool-Rotate:  %s%s\n' "$rot" "${rbytes:+ / $rbytes}"
  [ -n "$ech" ] && printf '    • ECH:          %s\n' "$ech"
  [ "$gov" = true ] && printf '    • Governor:     %s\n' "active"
  [ -n "$dl" ] && printf '    • DNS Relay:    %s\n' "$dl"
  [ -n "$sip" ] && printf '    • Source IP:    %s\n' "$sip"
  echo

  spin_start "Probing tunnel connection & DPI filter bypass"
  local wait_sec=${ANTICENSOR_TEST_WAIT:-6}
  for ((i=0; i<wait_sec; i++)); do
    s=$(stats "$n" 2>/dev/null)
    if [ "$(jget "$s" alive)" = true ]; then
      alive=true; break
    fi
    sleep 1
  done
  spin_stop

  if [ "$alive" = true ]; then
    srtt=$(jget "$s" srtt_ms)
    pkts_in=$(jget "$s" pkts_in)
    pkts_out=$(jget "$s" pkts_out)
    fprof=$(jget "$s" filter_profile)
    ech_st=$(jget "$s" ech)

    ok "FILTER BYPASS CONFIRMED: Tunnel is CONNECTED"
    printf '    %s%-18s%s %s ms\n' "$GRY" "RTT:" "$RST" "$(ms "$srtt")"
    printf '    %s%-18s%s in: %s pkts, out: %s pkts\n' "$GRY" "Traffic:" "$RST" "${pkts_in:-0}" "${pkts_out:-0}"
    [ -n "$fprof" ] && printf '    %s%-18s%s %s\n' "$GRY" "Filter Profile:" "$RST" "$fprof"
    [ -n "$ech_st" ] && printf '    %s%-18s%s %s\n' "$GRY" "ECH Status:" "$RST" "$ech_st"

    # Forwarded port check
    load_maps "$n"
    if [ "${#MAPS[@]}" -gt 0 ]; then
      local first_map="${MAPS[0]}"
      local lport=$(spec_L "$first_map")
      local proto=$(spec_P "$first_map")
      if [ -n "$lport" ] && [[ "$lport" =~ ^[0-9]+$ ]]; then
        if [ "$proto" = tcp ]; then
          if timeout 2 bash -c "</dev/tcp/127.0.0.1/$lport" 2>/dev/null; then
            ok "Forwarded port $lport/$proto is listening and accessible"
          fi
        elif port_busy "$lport" "$proto"; then
          ok "Forwarded port $lport/$proto is active"
        fi
      fi
    fi
    echo
    ok "Anti-censorship profile verified successfully."
    return 0
  else
    err "FILTER BYPASS FAILED: Tunnel could not establish link"
    echo
    say "  ${BOLD}Troubleshooting & Recommendations:${RST}"
    if [ -n "$fks" ]; then
      warn "The current allowlisted SNI ($fks) or fake-mode ($fkm) may be blocked by this provider."
      hint "1. Try Emergency Blackout Mode: $SELF blackout $n blackout"
      hint "2. Or switch mode to 'seqsum' or 'auto' (menu: tunnel page -> o -> k -> 3)."
      hint "3. Or try another allowlisted SNI: 'irancell.ir', 'tci.ir', 'divar.ir'."
    else
      warn "No Fake-SNI is active. If your provider enforces an SNI allowlist, connections will be dropped."
      hint "Turn on resilience: $SELF blackout $n mci"
    fi
    if [ "$cr" = icmp ]; then
      hint "ICMP may be filtered or rerouted. Ensure 'governor: true' is enabled."
    fi
    return 1
  fi
}

# ======================================================================================
#  Interactive Anti-Censorship Menu Hub
# ======================================================================================
anticensor_menu() {
  local n=$1 cr r
  cr=$(cfg "$n" carrier); r=$(role "$n")
  [ "$r" = Iran ] || return 0
  local changed=0
  while :; do
    page "Anti-Censorship & Resilience" "$n ($cr)"
    local fs fm ft pr pb ech gov dl sip
    fs=$(cfg "$n" fake-sni)
    fm=$(cfg "$n" fake-mode); [ -n "$fm" ] || fm=seq
    ft=$(cfg "$n" fake-ttl)
    pr=$(cfg "$n" pool-rotate)
    pb=$(cfg "$n" pool-rotate-bytes)
    ech=$(cfg "$n" ech)
    gov=$(cfg "$n" governor)
    dl=$(cfg "$n" dns-listen)
    sip=$(cfg "$n" src-ip)

    say "  ${BOLD}Anti-Censorship Configuration for '$n'${RST}"
    echo
    printf '    %s  Preset Profile         %s\n' "$(key_label 1)" "$(detect_preset "$n")"
    if is_pool "$cr"; then
      printf '    %s  Fake SNI               %s\n' "$(key_label 2)" "${fs:-${GRY}off (disabled)${RST}}"
      printf '    %s  Fake Desync Mode       %s\n' "$(key_label 3)" "$([ -n "$fs" ] && echo "$fm" || echo "${GRY}n/a (fake-sni off)${RST}")"
      printf '    %s  Fake TTL Hop Count     %s\n' "$(key_label 4)" "$([ -n "$fs" ] && [ "$fm" = ttl ] && echo "${ft:-auto}" || echo "${GRY}n/a${RST}")"
      printf '    %s  Pool Rotate (Time)     %s\n' "$(key_label 5)" "${pr:-${GRY}off (disabled)${RST}}"
      printf '    %s  Pool Rotate (Bytes)    %s\n' "$(key_label 6)" "${pb:-${GRY}off (disabled)${RST}}"
    elif [ "$cr" = icmp ]; then
      printf '    %s  Volume Governor        %s\n' "$(key_label 2)" "$([ "$gov" = true ] && echo "${GRN}ON (active)${RST}" || echo "${GRY}OFF${RST}")"
    fi
    case "$cr" in
      tls|wss|h2|grpc)
        printf '    %s  ECH Mode               %s\n' "$(key_label 7)" "${ech:-${GRY}off (disabled)${RST}}" ;;
    esac
    printf '    %s  DNS Forwarder          %s\n' "$(key_label 8)" "${dl:-${GRY}off (disabled)${RST}}"
    printf '    %s  Carrier Source IP      %s\n' "$(key_label 9)" "${sip:-${GRY}off (default route)${RST}}"
    echo
    printf '    %s  Test Filter Bypass & Link Status\n' "$(key_label t)"
    printf '    %s  Anti-Censor Matrix      (test every combination, apply the best)\n' "$(key_label m)"
    printf '    %s  Save Current as Custom Profile\n' "$(key_label p)"
    printf '    %s  Back to Advanced Settings\n' "$(key_label b)"
    echo
    key_read
    case "$KEY" in
      1) # Presets
         echo
         if pick_preset "mci"; then
           apply_preset "$n" "$REPLY_V" && changed=1
         fi
         sleep 1 ;;
      2) # Pick SNI (pool) or Toggle Governor (icmp)
         if [ "$cr" = icmp ]; then
           echo
           if [ "$(cfg "$n" governor)" = true ]; then
             unset_value "$n" governor; ok "Volume governor turned OFF."
           else
             set_value "$n" governor true; ok "Volume governor turned ON."
           fi
           changed=1; sleep 1; continue
         fi
         is_pool "$cr" || continue
         echo
         if pick_sni_preset "${fs:-mci.ir}"; then
           if [ "$REPLY_V" = off ] || [ "$REPLY_V" = 0 ]; then
             sed -i -E '/^fake-(sni|mode|ttl):/d' "$CONF/$n.yml"
             ok "Fake-SNI turned OFF."; changed=1
           else
             set_value "$n" fake-sni "$REPLY_V"
             [ -n "$(cfg "$n" fake-mode)" ] || set_value "$n" fake-mode seqsum
             ok "Fake-SNI set to $REPLY_V"; changed=1
           fi
         fi
         sleep 1 ;;
      3) # Pick Fake Mode
         is_pool "$cr" || continue
         [ -n "$(cfg "$n" fake-sni)" ] || { warn "Turn on Fake-SNI first (option 2)."; sleep 1; continue; }
         echo
         if pick_fake_mode "$fm"; then
           set_value "$n" fake-mode "$REPLY_V"
           [ "$REPLY_V" != ttl ] && unset_value "$n" fake-ttl
           ok "Fake mode set to $REPLY_V"; changed=1
         fi
         sleep 1 ;;
      4) # Fake TTL
         is_pool "$cr" || continue
         [ "$(cfg "$n" fake-mode)" = ttl ] || { warn "Fake TTL is only used in ttl mode."; sleep 1; continue; }
         echo
         ask "Fake TTL (hop count, empty = auto-calibrate)" "$ft"
         if [ -z "$REPLY_V" ]; then
           unset_value "$n" fake-ttl; ok "Fake TTL set to auto-calibrate."; changed=1
         elif v_fake_ttl "$REPLY_V"; then
           set_value "$n" fake-ttl "$REPLY_V"; ok "Fake TTL set to $REPLY_V."; changed=1
         fi
         sleep 1 ;;
      5) # Pool Rotate (Time)
         is_pool "$cr" || continue
         echo
         if pick_pool_rotate "${pr:-30m}"; then
           if [ "$REPLY_V" = off ] || [ "$REPLY_V" = 0 ]; then
             unset_value "$n" pool-rotate; ok "Pool rotate by time turned OFF."; changed=1
           else
             set_value "$n" pool-rotate "$REPLY_V"; ok "Pool rotate set to $REPLY_V."; changed=1
           fi
         fi
         sleep 1 ;;
      6) # Pool Rotate (Bytes)
         is_pool "$cr" || continue
         echo
         if pick_pool_rotate_bytes "${pb:-500MB}"; then
           if [ "$REPLY_V" = off ] || [ "$REPLY_V" = 0 ]; then
             unset_value "$n" pool-rotate-bytes; ok "Pool rotate by bytes turned OFF."; changed=1
           else
             set_value "$n" pool-rotate-bytes "$REPLY_V"; ok "Pool rotate bytes set to $REPLY_V."; changed=1
           fi
         fi
         sleep 1 ;;
      7) # ECH Mode
         case "$cr" in
           tls|wss|h2|grpc)
             echo
             if pick_ech "${ech:-ladder}"; then
               if [ "$REPLY_V" = off ]; then
                 unset_value "$n" ech; ok "ECH turned OFF."; changed=1
               else
                 set_value "$n" ech "$REPLY_V"; ok "ECH set to $REPLY_V."; changed=1
               fi
             fi
             sleep 1 ;;
         esac ;;
      8) # DNS Forwarder Listener
         echo
         if pick_dns_listen "${dl:-off}"; then
           if [ "$REPLY_V" = off ] || [ "$REPLY_V" = 0 ]; then
             unset_value "$n" dns-listen; ok "DNS forwarder listener turned OFF."; changed=1
           else
             set_value "$n" dns-listen "$REPLY_V"; ok "DNS forwarder listening on $REPLY_V."; changed=1
           fi
         fi
         sleep 1 ;;
      9) # Carrier Source IP Binding
         echo
         if pick_src_ip "${sip:-off}"; then
           if [ "$REPLY_V" = off ] || [ "$REPLY_V" = 0 ]; then
             unset_value "$n" src-ip; ok "Carrier source IP binding turned OFF."; changed=1
           else
             set_value "$n" src-ip "$REPLY_V"; ok "Carrier bound to source IP $REPLY_V."; changed=1
           fi
         fi
         sleep 1 ;;
      t|T)
         anticensor_test "$n"
         pause ;;
      m|M)
         ac_matrix_cmd "$n"
         pause ;;
      p|P)
         echo
         ask "Profile name to save" ""
         if [ -n "$REPLY_V" ]; then
           profile_cmd save "$REPLY_V" "$n"
           sleep 1
         fi ;;
      b|0|q|enter|esc) break ;;
      *) : ;;
    esac
  done
  if [ "$changed" = 1 ]; then
    hint "Applying changes: restarting '$n'..."
    step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
  fi
}

# ---- resilience profiles: save one tunnel's working fake-sni/pool-rotate combination, re-apply it later ----
prof_names() { local f; for f in "$CONF/profiles"/*.env; do [ -e "$f" ] || continue; basename "$f" .env; done; }
prof_path() { echo "$CONF/profiles/$1.env"; }
v_prof_name() { [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { err "Profile name: 1-32 letters, digits, - or _."; return 1; }; return 0; }
prof_read() { # file -> the KEY=VALUE lines this manager wrote (comments and anything else are ignored)
  local l
  [ -f "$1" ] || return 0
  while IFS= read -r l; do
    case "$l" in FAKESNI=*|FAKEMODE=*|FAKETTL=*|POOLROT=*|POOLBYTES=*|ECH=*|GOVERNOR=*|DNSLISTEN=*|SRCIP=*) echo "$l" ;; esac
  done <"$1"
}
prof_pick_defaults() { # fill the wizard's resilience defaults from a saved profile (interactive only)
  local names pick l k v
  names=$(prof_names)
  [ -n "$names" ] || return 0
  echo
  hint "Saved resilience profiles: $(echo "$names" | tr '\n' ' ')"
  ask "Start from a saved profile (name, empty = skip)" ""; pick=$REPLY_V
  [ -n "$pick" ] || return 0
  [ -f "$(prof_path "$pick")" ] || { err "No profile named '$pick'."; return 0; }
  while IFS= read -r l; do
    k=${l%%=*}; v=${l#*=}
    case "$k" in
      FAKESNI) T_FAKESNI=$v ;; FAKEMODE) T_FAKEMODE=$v ;; FAKETTL) T_FAKETTL=$v ;;
      POOLROT) T_POOLROT=$v ;; POOLBYTES) T_POOLBYTES=$v ;;
      ECH) T_ECH=$v ;; GOVERNOR) T_GOVERNOR=$v ;;
      DNSLISTEN) T_DNSLISTEN=$v ;; SRCIP) T_SRCIP=$v ;;
    esac
  done < <(prof_read "$(prof_path "$pick")")
  hint "Profile '$pick' loaded as the defaults below; press Enter to keep each."
}
prof_only_tunnel() { # the single Iran pool tunnel, when there is exactly one
  local n count=0 pick=''
  for n in $(tunnels); do
    [ "$(role "$n")" = Iran ] && is_pool "$(cfg "$n" carrier)" || continue
    count=$((count+1)); pick=$n
  done
  [ "$count" = 1 ] && echo "$pick"
  return 0
}

blackout_cmd() { # name [sni_or_preset] : turn the resilience kit on when a censor starts blocking the tunnel.
  local n=$1 sni=${2:-}
  [ "$(uname -s)" = Linux ] || { err "The resilience kit is a Linux feature (fake-SNI needs CAP_NET_RAW, like the icmp carrier)."; return 1; }
  [ -f "$CONF/$n.yml" ] || { err "No tunnel named '$n'."; return 1; }
  [ "$(role "$n")" = Iran ] || {
    err "'$n' is not an Iran tunnel; anti-censorship features are client-only."; return 1; }

  if [ -z "$sni" ] && [ "$NONINTERACTIVE" != 1 ]; then
    echo
    say "  ${BOLD}Blackout Resilience Activation for '$n'${RST}"
    say "  Under an SNI allowlist or blackout, choose an operator preset or allowlisted domain."
    echo
    pick_preset "mci" || return 1; sni=$REPLY_V
  fi
  [ -n "$sni" ] || { err "An allowlisted name or preset is required (blackout $n mci.ir or blackout $n mci)."; return 1; }

  if is_builtin_preset "$sni"; then
    apply_preset "$n" "$sni" || return 1
    if [ -t 0 ] && [ "$NONINTERACTIVE" != 1 ] && [ "${WAT_MANAGER_LIB:-0}" != 1 ]; then
      anticensor_test "$n"
    fi
    return 0
  fi

  # Custom SNI domain
  [ "$(role "$n")" = Iran ] && is_pool "$(cfg "$n" carrier)" && ! is_reverse "$n" || {
    err "'$n' is not a direct Iran tunnel on a pool carrier (tcp, tls, ws, wss, h2, h2c, grpc); the kit is client-only and only attaches there."; return 1; }
  v_sni_name "$sni" || return 1
  [ "$(bin_ver_ok 2.7.0)" = 1 ] || { err "fake-sni needs wattun 2.7.0 or newer on this server (run: $SELF update)."; return 1; }
  set_value "$n" fake-sni "$sni"
  set_value "$n" fake-mode seq
  unset_value "$n" fake-ttl
  ok "Resilience kit on: fake-sni $sni (seq mode, auto ttl). pool-rotate stays off; tune later: tunnel page -> o -> k."
  if step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"; then
    ok "Restart applied. Watch whether the link comes back: $SELF test $n"
    if [ -t 0 ] && [ "$NONINTERACTIVE" != 1 ] && [ "${WAT_MANAGER_LIB:-0}" != 1 ]; then
      anticensor_test "$n"
    fi
  else
    err "Restart failed: run  systemctl restart ${WAT_PREFIX}@$n"; return 1
  fi
  return 0
}

arm_blackout_cmd() { # name
  local n=$1 r
  [ -f "$CONF/$n.yml" ] || { err "No tunnel named '$n'."; return 1; }
  r=$(role "$n")
  if [ "$r" = Kharej ]; then
    say "  ${BOLD}Arming Kharej '$n' in Fortress Mode for Blackout Resilience${RST}"
    if [ "$(uname -s)" = Linux ]; then
      sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 || true
      sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
      sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
      sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1 || true
      sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1 || true
    fi
    fw_open 80/tcp >/dev/null 2>&1 || true
    fw_open 443/tcp >/dev/null 2>&1 || true
    fw_open 4443/tcp >/dev/null 2>&1 || true
    fw_open 8443/tcp >/dev/null 2>&1 || true
    fw_open 53/udp >/dev/null 2>&1 || true
    fw_open 4443/udp >/dev/null 2>&1 || true
    set_value "$n" carrier fortress
    [ -n "$(cfg "$n" dns-relay-upstream)" ] || set_value "$n" dns-relay-upstream "1.1.1.1:53"
    systemctl restart "${WAT_PREFIX}@$n" >/dev/null 2>&1 || true
    ok "Kharej '$n' armed in Fortress Mode (ICMP, TCP:80, TLS:443, WSS:8443, UDP:53)."
    say "  Emergency blackout token for Iran distribution:"
    show_token "$n"
  else
    say "  ${BOLD}Arming Iran '$n' for Autonomous Blackout Failover${RST}"
    set_value "$n" path-probe-max "6s"
    set_value "$n" governor true
    heal_enable >/dev/null 2>&1 || true
    systemctl restart "${WAT_PREFIX}@$n" >/dev/null 2>&1 || true
    ok "Iran '$n' armed for Autonomous Failover (fast silence detection, auto-heal timer active)."
  fi
  return 0
}

audit_blackout_cmd() { # name
  local n=$1 r pid pass_cnt=0 fail_cnt=0
  [ -f "$CONF/$n.yml" ] || { err "No tunnel named '$n'."; return 1; }
  r=$(role "$n")
  echo
  say "  ${BOLD}Blackout Preparedness Audit for '$n' ($r)${RST}"
  echo
  pid=$(systemctl show -p MainPID --value "${WAT_PREFIX}@$n" 2>/dev/null || echo 0)
  if [ -n "$pid" ] && [ "$pid" -gt 0 ] && [ -r "/proc/$pid/status" ]; then
    local cap_eff; cap_eff=$(grep -i CapEff "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
    if [ -n "$cap_eff" ]; then
      ok "Process capabilities active (PID $pid, CapEff $cap_eff)"
      pass_cnt=$((pass_cnt+1))
    else
      warn "Unable to read process capabilities"
      fail_cnt=$((fail_cnt+1))
    fi
  else
    warn "Tunnel process is not currently running"
    fail_cnt=$((fail_cnt+1))
  fi

  if [ "$(uname -s)" = Linux ]; then
    local icmp_ign; icmp_ign=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo 1)
    if [ "$icmp_ign" = 0 ]; then
      ok "Sysctl: net.ipv4.icmp_echo_ignore_all == 0 (ICMP replies enabled)"
      pass_cnt=$((pass_cnt+1))
    else
      warn "Sysctl: net.ipv4.icmp_echo_ignore_all != 0 (ICMP carrier will fail)"
      fail_cnt=$((fail_cnt+1))
    fi
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)
    if [ "$cc" = bbr ]; then
      ok "Sysctl: congestion control is BBR"
      pass_cnt=$((pass_cnt+1))
    else
      hint "Sysctl: congestion control is $cc (BBR recommended for anti-policing)"
    fi
  fi

  if [ "$r" = Kharej ]; then
    local p53; p53=$(ss -ulnp 2>/dev/null | grep -E ':53\s' || true)
    if [ -n "$p53" ] && [[ "$p53" != *"wattun"* ]]; then
      warn "Port 53/udp bound by another process: $p53"
      fail_cnt=$((fail_cnt+1))
    else
      ok "Port 53/udp available or bound by wattun"
      pass_cnt=$((pass_cnt+1))
    fi
  fi

  local dns_up; dns_up=$(cfg "$n" dns-relay-upstream)
  if [ -n "$dns_up" ]; then
    ok "DNS in-band relay configured ($dns_up)"
    pass_cnt=$((pass_cnt+1))
  else
    hint "DNS in-band relay not configured (default upstreams active)"
  fi

  local st; st=$(systemctl is-active "${WAT_PREFIX}@$n" 2>/dev/null || echo inactive)
  if [ "$st" = active ]; then
    ok "Service ${WAT_PREFIX}@$n is active"
    pass_cnt=$((pass_cnt+1))
  else
    warn "Service ${WAT_PREFIX}@$n is $st"
    fail_cnt=$((fail_cnt+1))
  fi

  echo
  if [ "$fail_cnt" -eq 0 ]; then
    say "  ${GRN}${BOLD}OVERALL STATUS: ARMED & READY FOR BLACKOUT${RST} (${pass_cnt} checks passed)"
  else
    say "  ${YEL}${BOLD}OVERALL STATUS: PARTIALLY ARMED${RST} (${pass_cnt} passed, ${fail_cnt} warnings)"
  fi
  echo
  return 0
}

preset_cmd() { # name [preset]
  local n=$1 p=${2:-}
  [ "$(uname -s)" = Linux ] || { err "Anti-censorship presets are a Linux feature."; return 1; }
  [ -f "$CONF/$n.yml" ] || { err "No tunnel named '$n'."; return 1; }
  [ "$(role "$n")" = Iran ] || { err "'$n' is not an Iran tunnel (presets are client-only)."; return 1; }
  if [ -z "$p" ] && [ "$NONINTERACTIVE" != 1 ]; then
    pick_preset "mci" || return 1; p=$REPLY_V
  fi
  [ -n "$p" ] || { err "A preset name is required (preset $n mci). Available: mci, irancell, blackout, conservative"; return 1; }
  v_preset "$p" || return 1
  apply_preset "$n" "$p" || return 1
  if [ -t 0 ] && [ "$NONINTERACTIVE" != 1 ] && [ "${WAT_MANAGER_LIB:-0}" != 1 ]; then
    anticensor_test "$n"
  fi
  return 0
}

profile_cmd() { # profile save|list|show|del|apply NAME [tunnel]
  local sub name tun f names x tmp
  sub=${1:-}; name=${2:-}; tun=${3:-}
  case "$sub" in
    save)
      if is_builtin_preset "$name"; then
        err "'$name' is a built-in preset name. Choose another name for your custom profile."
        return 1
      fi
      v_prof_name "$name" || return 1
      [ -n "$tun" ] || tun=$(prof_only_tunnel)
      [ -n "$tun" ] || { err "Name the tunnel explicitly (profile save $name TUNNEL)."; return 1; }
      [ -f "$CONF/$tun.yml" ] || { err "No tunnel named '$tun'."; return 1; }
      [ "$(uname -s)" = Linux ] || { err "Resilience profiles are a Linux feature (fake-SNI needs CAP_NET_RAW, like the icmp carrier)."; return 1; }
      mkdir -p "$CONF/profiles"
      f=$(prof_path "$name"); tmp="$f.tmp.$$"
      if { echo "# WatTunnel resilience profile: $name"
           echo "# From tunnel $tun, saved $(date -u '+%Y-%m-%d %H:%M UTC'). Apply: $SELF profile apply $name TUNNEL"
           echo "# FAKESNI   allowlisted server name (e.g. mci.ir); empty = fake-SNI off"
           echo "# FAKEMODE  seq | ttl | sum | seqsum | auto | rst"
           echo "# FAKETTL   hop count for fake-mode ttl; empty = auto-calibrate"
           echo "# POOLROT   recycle each healthy pool connection after this long (90s, 30m, 4h); empty = off"
           echo "# POOLBYTES recycle after this much traffic (500MB, 4G); empty = off"
           echo "# ECH       ECH mode: ladder | auto | off"
           echo "# GOVERNOR  ICMP volume pacer: true | false"
           echo "FAKESNI=$(cfg "$tun" fake-sni)"
           echo "FAKEMODE=$(cfg "$tun" fake-mode)"
           echo "FAKETTL=$(cfg "$tun" fake-ttl)"
           echo "POOLROT=$(cfg "$tun" pool-rotate)"
           echo "POOLBYTES=$(cfg "$tun" pool-rotate-bytes)"
           echo "ECH=$(cfg "$tun" ech)"
           echo "GOVERNOR=$(cfg "$tun" governor)"
           echo "DNSLISTEN=$(cfg "$tun" dns-listen)"
           echo "SRCIP=$(cfg "$tun" src-ip)"
         } >"$tmp"; then
        mv -f "$tmp" "$f"
        ok "Profile '$name' saved (from $tun). Re-apply later: $SELF profile apply $name TUNNEL."
      else rm -f "$tmp"; err "Could not write $(prof_path "$name")."; return 1
      fi ;;
    list)
      say "  ${BOLD}Built-in Presets:${RST}"
      echo "  mci          Iran Whitelist - MCI (mci.ir, seqsum, 30m, 500MB, ECH ladder)"
      echo "  irancell     Iran Whitelist - Irancell/Mokhaberat (irancell.ir, seq, 20m, 300MB, ECH ladder)"
      echo "  blackout     Emergency Blackout Mode (mci.ir, auto, 90s, 100MB, ECH ladder)"
      echo "  conservative Conservative / Low-Churn (mci.ir, seq, 4h, 4GB, ECH auto)"
      echo
      say "  ${BOLD}Saved Custom Profiles:${RST}"
      names=$(prof_names)
      if [ -n "$names" ]; then
        echo "$names" | while read -r x; do echo "  $x"; done
      else
        hint "No custom saved profiles."
      fi ;;
    show)
      if is_builtin_preset "$name"; then
        show_builtin_preset "$name"
      else
        v_prof_name "$name" || return 1
        if [ -f "$(prof_path "$name")" ]; then
          cat "$(prof_path "$name")"
        else
          err "No profile named '$name'."
          return 1
        fi
      fi ;;
    del|delete|rm)
      if is_builtin_preset "$name"; then
        err "Cannot delete built-in preset '$name'."
        return 1
      fi
      v_prof_name "$name" || return 1
      [ -f "$(prof_path "$name")" ] || { err "No profile named '$name'."; return 1; }
      rm -f "$(prof_path "$name")"; ok "Profile '$name' deleted." ;;
    apply)
      if is_builtin_preset "$name"; then
        [ -n "$tun" ] || tun=$(prof_only_tunnel)
        [ -n "$tun" ] || { err "Name the tunnel explicitly (profile apply $name TUNNEL)."; return 1; }
        [ -f "$CONF/$tun.yml" ] || { err "No tunnel named '$tun'."; return 1; }
        apply_preset "$tun" "$name" || return 1
      else
        v_prof_name "$name" || return 1
        [ -n "$tun" ] || tun=$(prof_only_tunnel)
        [ -n "$tun" ] || { err "Name the tunnel explicitly (profile apply $name TUNNEL)."; return 1; }
        [ -f "$CONF/$tun.yml" ] || { err "No tunnel named '$tun'."; return 1; }
        [ "$(role "$tun")" = Iran ] || { err "'$tun' is not an Iran tunnel; these keys are client-only."; return 1; }
        if [ -f "$(prof_path "$name")" ]; then
          [ "$(role "$tun")" = Iran ] && is_pool "$(cfg "$tun" carrier)" || { err "'$tun' is not an Iran tunnel on a pool carrier (tcp, tls, ws, wss, h2, grpc); these keys are client-only."; return 1; }
          prof_apply "$name" "$tun" || return 1
        else
          err "No profile named '$name'."
          return 1
        fi
      fi ;;
    *) err "profile: use save, list, show, del or apply."; return 1 ;;
  esac
  return 0
}

prof_apply() { # profile tunnel : write the tunnel's resilience keys from a saved profile, then restart
  local name=$1 tun=$2 l k v changed=0
  local fs='' fm='' ft='' pr='' pb='' ech='' gov='' dl='' sip=''
  while IFS= read -r l; do
    k=${l%%=*}; v=${l#*=}
    case "$k" in
      FAKESNI) fs=$v ;; FAKEMODE) fm=$v ;; FAKETTL) ft=$v ;; POOLROT) pr=$v ;; POOLBYTES) pb=$v ;;
      ECH) ech=$v ;; GOVERNOR) gov=$v ;; DNSLISTEN) dl=$v ;; SRCIP) sip=$v ;;
    esac
  done < <(prof_read "$(prof_path "$name")")
  if [ -n "$fs" ]; then
    [ "$(bin_ver_ok 2.7.0)" = 1 ] || { err "fake-sni needs wattun 2.7.0 or newer (run: $SELF update)."; return 1; }
    set_value "$tun" fake-sni "$fs"; changed=1
  elif [ -n "$(cfg "$tun" fake-sni)" ]; then
    unset_value "$tun" fake-sni; unset_value "$tun" fake-mode; unset_value "$tun" fake-ttl; changed=1
  fi
  if [ -n "$fs" ] && [ -n "$fm" ]; then
    case "$fm" in
      auto|rst) [ "$(bin_ver_ok 2.9.0)" = 1 ] || { err "fake-mode $fm needs wattun 2.9.0 or newer (run: $SELF update)."; return 1; } ;;
      seqsum) [ "$(bin_ver_ok 2.8.0)" = 1 ] || { err "fake-mode seqsum needs wattun 2.8.0 or newer (run: $SELF update)."; return 1; } ;;
      sum) [ "$(bin_ver_ok 2.7.1)" = 1 ] || { err "fake-mode sum needs wattun 2.7.1 or newer (run: $SELF update)."; return 1; } ;;
    esac
    set_value "$tun" fake-mode "$fm"; changed=1
    if [ "$fm" = ttl ] && [ -n "$ft" ]; then set_value "$tun" fake-ttl "$ft"; else unset_value "$tun" fake-ttl; fi
  fi
  if [ -n "$pr" ] && [ "$pr" != 0 ] && [ "$pr" != off ]; then
    [ "$(bin_ver_ok 2.8.0)" = 1 ] || { err "pool-rotate needs wattun 2.8.0 or newer (run: $SELF update)."; return 1; }
    set_value "$tun" pool-rotate "$pr"; changed=1
  elif [ -n "$(cfg "$tun" pool-rotate)" ]; then unset_value "$tun" pool-rotate; changed=1
  fi
  if [ -n "$pb" ] && [ "$pb" != 0 ] && [ "$pb" != off ]; then
    [ "$(bin_ver_ok 2.8.1)" = 1 ] || { err "pool-rotate-bytes needs wattun 2.8.1 or newer (run: $SELF update)."; return 1; }
    set_value "$tun" pool-rotate-bytes "$pb"; changed=1
  elif [ -n "$(cfg "$tun" pool-rotate-bytes)" ]; then unset_value "$tun" pool-rotate-bytes; changed=1
  fi
  if [ -n "$ech" ] && [ "$ech" != off ]; then
    [ "$(bin_ver_ok 2.9.0)" = 1 ] || { err "ech needs wattun 2.9.0 or newer (run: $SELF update)."; return 1; }
    set_value "$tun" ech "$ech"; changed=1
  elif [ -n "$(cfg "$tun" ech)" ]; then unset_value "$tun" ech; changed=1
  fi
  if [ "$gov" = true ] || [ "$gov" = on ]; then
    [ "$(bin_ver_ok 2.9.0)" = 1 ] || { err "governor needs wattun 2.9.0 or newer (run: $SELF update)."; return 1; }
    set_value "$tun" governor true; changed=1
  elif [ -n "$(cfg "$tun" governor)" ]; then unset_value "$tun" governor; changed=1
  fi
  if [ -n "$dl" ] && [ "$dl" != off ]; then
    set_value "$tun" dns-listen "$dl"; changed=1
  elif [ -n "$(cfg "$tun" dns-listen)" ]; then unset_value "$tun" dns-listen; changed=1
  fi
  if [ -n "$sip" ] && [ "$sip" != off ]; then
    set_value "$tun" src-ip "$sip"; changed=1
  elif [ -n "$(cfg "$tun" src-ip)" ]; then unset_value "$tun" src-ip; changed=1
  fi
  [ "$changed" = 1 ] || { hint "Nothing to change."; return 0; }
  ok "Profile '$name' applied to $tun."
  if step "Restarting ${WAT_PREFIX}@$tun" systemctl restart "${WAT_PREFIX}@$tun"; then ok "Restart applied."
  else err "Restart failed: run  systemctl restart ${WAT_PREFIX}@$tun"; return 1; fi
  return 0
}

change_type() { # name : one place to change how the two servers connect, whatever kind of tunnel this is
  local n=$1 c; c=$(cfg "$n" carrier)
  echo
  if [ "$(role "$n")" = Iran ]; then
    if [ -f "$CONF/$n.auto" ]; then
      hint "Every type is tested again; pick any that works, join several (c), or force one that failed (f)."
      auto_test_cmd "$n"; return
    fi
    say "  Current: ${BOLD}$c${RST}. This tunnel was made with a fixed-type token, so the Kharej side decides the type."
    hint "1. On the Kharej server, make a new tunnel and choose Auto ($SELF, n, Kharej, 1); Kharej then accepts every type."
    hint "2. Paste its token here with t. From then on, m on this page tests every type and lets you switch any time."
    return 0
  fi
  if is_auto_kharej "$n"; then
    say "  This is an ${BOLD}Auto${RST} tunnel: it accepts every connection type at once."
    hint "Choose the type on the Iran server: its tunnel page, m. It can switch, or join several types into one tunnel."
    return 0
  fi
  say "  Current: ${BOLD}$c${RST}, fixed when the tunnel was made."
  hint "To switch freely: make a new tunnel here with Auto ($SELF, n, Kharej, 1), paste its token on the Iran server,"
  hint "then delete this one. After that the type is chosen and changed on the Iran side (tunnel page, m)."
}
# ======================================================================================
#  Kernel Speed Boost (/boost)
# ======================================================================================
BOOST_SYSCTL=/etc/sysctl.d/99-$WAT_PREFIX-boost.conf
is_container() {
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then return 0; fi
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container -q 2>/dev/null; then return 0; fi
  if [ -f /proc/user_beancounters ]; then return 0; fi
  if [ ! -w /proc/sys/net/ipv4/tcp_congestion_control ]; then return 0; fi
  return 1
}
boost_status() {
  local cc qdisc rmax wmax
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo unknown)
  rmax=$(sysctl -n net.core.rmem_max 2>/dev/null || cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
  wmax=$(sysctl -n net.core.wmem_max 2>/dev/null || cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 0)
  say "  Kernel Speed Boost Status:"
  if [ -f "$BOOST_SYSCTL" ]; then
    say "    • Configuration File: ${GRN}$BOOST_SYSCTL active${RST}"
  else
    say "    • Configuration File: ${GRY}none ($BOOST_SYSCTL not present)${RST}"
  fi
  say "    • Congestion Control: ${BOLD}$cc${RST} $([ "$cc" = bbr ] && printf '%s(optimal)%s' "$GRN" "$RST")"
  say "    • Queue Discipline:   ${BOLD}$qdisc${RST} $([ "$qdisc" = fq ] && printf '%s(optimal)%s' "$GRN" "$RST")"
  say "    • Max Read Buffer:    ${BOLD}$(human "$rmax")${RST} ($rmax B)"
  say "    • Max Write Buffer:   ${BOLD}$(human "$wmax")${RST} ($wmax B)"
  if is_container; then
    warn "Running inside a container/namespace with restricted sysctl permissions."
  fi
}
boost_apply() {
  if is_container; then
    warn "Container environment detected. Sysctl writes may be restricted by the host."
  fi
  mkdir -p "${BOOST_SYSCTL%/*}"
  cat >"$BOOST_SYSCTL" <<EOF
# WatTunnel High-Speed Transport Engine Tunables (/boost)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
EOF
  chmod 644 "$BOOST_SYSCTL"
  modprobe tcp_bbr 2>/dev/null || true
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -p "$BOOST_SYSCTL" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  fi
  ok "Boost parameters written to $BOOST_SYSCTL and applied."
  boost_status
}
boost_undo() {
  rm -f "$BOOST_SYSCTL"
  if command -v sysctl >/dev/null 2>&1; then
    sysctl --system >/dev/null 2>&1 || true
  fi
  ok "Removed $BOOST_SYSCTL and reloaded system defaults."
  boost_status
}
boost_cmd() {
  case "${1:-}" in
    --status|-s|status) boost_status ;;
    --undo|-u|undo) boost_undo ;;
    --yes|-y|apply|"") boost_apply ;;
    *) err "Usage: $SELF boost [--status|--undo|--yes]"; return 1 ;;
  esac
}
boost_menu() {
  while :; do
    page "Kernel Speed Boost (/boost)"
    boost_status
    echo
    printf '  %s apply boost tunables   %s undo / restore defaults   %s back\n' \
      "$(key_label a)" "$(key_label u)" "$(key_label b)"
    key_read
    case "$KEY" in
      a) boost_apply; pause ;;
      u) confirm "Rollback boost tunables?" y && boost_undo; pause ;;
      b|0|q|enter|esc) return 0 ;;
    esac
  done
}

# ======================================================================================
#  Off-Peak Auto-Optimize (Timer)
# ======================================================================================
OPTIMIZE_UNIT=$WAT_PREFIX-auto-optimize
optimize_enable() {
  local mgr=/usr/local/bin/wattun-manager
  [ "$SANDBOX" = 1 ] && mgr=$MGR
  {
    printf '[Unit]\nDescription=WatTunnel off-peak auto-optimize%s\n[Service]\nType=oneshot\n' "$([ "$SANDBOX" = 1 ] && echo " (sandbox $WAT_PREFIX)")"
    unit_env_lines
    printf 'ExecStart=%s auto-optimize\n' "$mgr"
  } >"/etc/systemd/system/$OPTIMIZE_UNIT.service"
  cat >"/etc/systemd/system/$OPTIMIZE_UNIT.timer" <<EOF
[Unit]
Description=WatTunnel off-peak auto-optimize daily at 04:30
[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
  chmod 644 "/etc/systemd/system/$OPTIMIZE_UNIT.service" "/etc/systemd/system/$OPTIMIZE_UNIT.timer"
  systemctl daemon-reload && systemctl enable --now "$OPTIMIZE_UNIT.timer" >/dev/null 2>&1 && ok "Auto-optimize timer enabled (daily at 04:30)."
}
optimize_disable() {
  systemctl disable --now "$OPTIMIZE_UNIT.timer" >/dev/null 2>&1; ok "Auto-optimize timer disabled."
}
auto_optimize_all() {
  local n
  for n in $(tunnels); do
    if [ "$(role "$n")" = Iran ] && [ -f "$CONF/$n.auto" ]; then
      logger -t wattun-auto-optimize "running scheduled off-peak optimization for $n"
      AUTO_OPTIMIZE=1 auto_retest "$n"
    fi
  done
}

# ======================================================================================
#  Backup & Restore, Bulk Operations
# ======================================================================================
backup_cmd() { # [dest.tar.gz]
  local dest=${1:-wattun-backup-$(date +%Y%m%d%H%M%S).tar.gz}
  dest=$(readlink -f "$dest" 2>/dev/null || echo "$dest")
  say "  Backing up $CONF to $dest..."
  tar -czf "$dest" -C "${CONF%/*}" "${CONF##*/}" || { err "Backup failed"; return 1; }
  chmod 600 "$dest"
  ok "Backup saved: $dest ($(du -h "$dest" | cut -f1))"
}
restore_cmd() { # <archive.tar.gz>
  local src=${1:-}
  [ -f "$src" ] || { err "Backup archive '$src' not found."; return 1; }
  say "  Restoring $CONF from $src..."
  mkdir -p "$CONF"
  tar -xzf "$src" -C "${CONF%/*}" || { err "Restore extraction failed"; return 1; }
  chmod 700 "$CONF"
  chmod 600 "$CONF"/*.key 2>/dev/null || true
  chmod 600 "$CONF"/*.yml 2>/dev/null || true
  ok "Restored configuration to $CONF."
  systemctl daemon-reload 2>/dev/null || true
  ok "Ready. You can start or restart your tunnels now."
}
start_all() {
  local n c=0
  for n in $(tunnels); do
    if ! systemctl is-active -q "${WAT_PREFIX}@$n" 2>/dev/null; then
      step "Starting ${WAT_PREFIX}@$n" systemctl start "${WAT_PREFIX}@$n"; c=$((c+1))
    fi
  done
  [ "$c" -gt 0 ] && ok "Started $c tunnel(s)." || warn "All tunnels are already active."
}
stop_all() {
  local n c=0
  for n in $(tunnels); do
    if systemctl is-active -q "${WAT_PREFIX}@$n" 2>/dev/null; then
      step "Stopping ${WAT_PREFIX}@$n" systemctl stop "${WAT_PREFIX}@$n"; c=$((c+1))
    fi
  done
  [ "$c" -gt 0 ] && ok "Stopped $c tunnel(s)." || warn "All tunnels are already stopped."
}
batch_actions_menu() {
  while :; do
    page "Batch Tunnel Actions"
    say "  ${BOLD}Select a bulk operation:${RST}"
    echo
    printf '  %s start all tunnels      %s stop all tunnels       %s restart all tunnels\n' "$(key_label 1)" "$(key_label 2)" "$(key_label 3)"
    printf '  %s status of all tunnels  %s backup all configs     %s restore configs\n' "$(key_label 4)" "$(key_label 5)" "$(key_label 6)"
    printf '  %s back\n' "$(key_label b)"
    key_read
    case "$KEY" in
      1) start_all; pause ;;
      2) confirm "Stop all active tunnels?" n && stop_all; pause ;;
      3) confirm "Restart all tunnels? Open connections drop." n && restart_all; pause ;;
      4) status_all; pause ;;
      5) echo; ask "Backup destination file" "wattun-backup-$(date +%Y%m%d).tar.gz"; backup_cmd "$REPLY_V"; pause ;;
      6) echo; ask "Path to backup .tar.gz" ""; restore_cmd "$REPLY_V"; pause ;;
      b|0|q|enter|esc) return 0 ;;
    esac
  done
}

# ======================================================================================
#  Bonding Manager Submenu
# ======================================================================================
bonding_menu() { # name
  local n=$1 r cr
  r=$(role "$n"); cr=$(cfg "$n" carrier)
  while :; do
    page "Bonding Manager" "$n"
    tinfo "$n"
    local bmode=$(cfg "$n" bond-mode)
    say "  Bond Carrier:  ${BOLD}$cr${RST}"
    say "  Bond Mode:     ${BOLD}${bmode:-balanced}${RST} ${GRY}(balanced | active-backup | replicate)${RST}"
    echo
    if [ "$TI_CAR_COUNT" -gt 0 ]; then
      printf '  %s%4s  %-10s %-8s %8s %8s %12s%s\n' "$GRY" '#' PATH STATE RTT LOSS SHARE "$RST"
      local ci ccol cdot ctxt c_pct
      for ((ci=0; ci<TI_CAR_COUNT; ci++)); do
        if [ "${CAR_MUTED[$ci]}" = true ]; then
          ccol=$GRY; cdot='○'; ctxt="MUTED"
        elif [ "${CAR_ALIVE[$ci]}" = true ]; then
          ccol=$GRN; cdot='●'; ctxt="UP"
        else
          ccol=$RED; cdot='○'; ctxt="DOWN"
        fi
        c_pct=$(awk -v s="${CAR_SHARE[$ci]:-0}" 'BEGIN{printf "%.0f", s*100}')
        printf '  %s%4s%s  %-10s %s%s %-6s%s %6.0f ms %7.1f%% %11s%%\n' "$CYN" "$ci" "$RST" \
          "${CAR_NAME[$ci]}" "$ccol" "$cdot" "$ctxt" "$RST" "${CAR_RTT[$ci]}" "$(awk -v l="${CAR_LOSS[$ci]:-0}" 'BEGIN{printf "%.1f", l*100}')" "$c_pct"
      done
    else
      say "  ${GRY}No multi-carrier telemetry active yet (tunnel stopped or single carrier).${RST}"
    fi
    echo
    printf '  %s toggle/mute path   %s change bond mode   %s add carrier   %s remove carrier   %s back\n' \
      "$(key_label t)" "$(key_label m)" "$(key_label a)" "$(key_label d)" "$(key_label b)"
    key_read
    case "$KEY" in
      t)
        echo
        ask_ok "Path index to toggle mute" "0" v_num || continue
        local pidx=$REPLY_V m=$(cfg "$n" metrics)
        if [ -n "$m" ]; then
          local res
          res=$(curl -fs --noproxy '*' --max-time 3 "http://$m/carrier/toggle?path=$pidx" 2>/dev/null)
          if [ -n "$res" ]; then
            ok "Toggled mute on path $pidx (muted: $(jget "$res" muted))."
          else
            err "Failed to toggle path $pidx on metrics server http://$m."
          fi
        else
          warn "Tunnel '$n' has no metrics endpoint configured."
        fi
        pause ;;
      m)
        echo
        say "  Choose bond mode:"
        say "    ${CYN}1${RST} balanced       (smooth weighted round-robin based on path capacities)"
        say "    ${CYN}2${RST} active-backup  (100% on primary path, 50ms keepalives on secondary, fast cutover)"
        say "    ${CYN}3${RST} replicate      (replicate datagrams across all paths for zero loss)"
        ask_ok "Choice" "1" v_nonempty || continue
        case "$REPLY_V" in
          1|balanced) set_value "$n" bond-mode balanced ;;
          2|active-backup) set_value "$n" bond-mode active-backup ;;
          3|replicate) set_value "$n" bond-mode replicate ;;
          *) warn "Unknown bond mode '$REPLY_V'."; continue ;;
        esac
        ok "Set bond-mode: $(cfg "$n" bond-mode)"
        confirm "Restart '$n' to apply mode change?" y && step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
        pause ;;
      a)
        echo
        ask_ok "Carrier name to add (tcp, tls, ws, wss, udp, icmp...)" "tls" v_nonempty || continue
        local ncar=$REPLY_V cur_car=$(cfg "$n" carrier)
        if [[ "$cur_car" == *"$ncar"* ]]; then
          warn "Carrier '$ncar' is already in carrier list '$cur_car'."
        else
          set_value "$n" carrier "$cur_car+$ncar"
          ok "Updated carrier: $(cfg "$n" carrier)"
          confirm "Restart '$n' to apply new carrier bond?" y && step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
        fi
        pause ;;
      d)
        echo
        ask_ok "Carrier name to remove" "" v_nonempty || continue
        local rcar=$REPLY_V cur_car=$(cfg "$n" carrier)
        if [[ "$cur_car" != *"$rcar"* ]]; then
          warn "Carrier '$rcar' not found in '$cur_car'."
        else
          local new_car
          new_car=$(echo "$cur_car" | sed -E "s/(^|\+)$rcar(\+|$)/\1/g; s/^\+//; s/\+$//")
          if [ -z "$new_car" ]; then
            err "Cannot remove the only carrier."
          else
            set_value "$n" carrier "$new_car"
            ok "Updated carrier: $(cfg "$n" carrier)"
            confirm "Restart '$n' to apply?" y && step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"
          fi
        fi
        pause ;;
      b|0|q|enter|esc) break ;;
    esac
  done
}

# ======================================================================================
#  Auto Mode Settings Submenu
# ======================================================================================
auto_menu() { # name
  local n=$1 cur pol sla_f
  sla_f="$CONF/$n.sla"
  while :; do
    page "Auto Mode Settings & SLA" "$n"
    cur=$(auto_current_key "$n" 2>/dev/null || cfg "$n" carrier)
    pol=$(cat "$CONF/$n.policy" 2>/dev/null || echo speed)
    say "  Current Variant:  ${BOLD}${cur:--}${RST}"
    say "  Selection Policy: ${BOLD}$pol${RST} ${GRY}(speed | latency | direct | bond)${RST}"
    echo
    say "  ${BOLD}Service Level Agreement (SLA) Thresholds:${RST}"
    if [ -f "$sla_f" ]; then
      local min_r=$(grep '^sla_min_rate_kbps=' "$sla_f" 2>/dev/null | cut -d= -f2)
      local max_rtt=$(grep '^sla_max_rtt_ms=' "$sla_f" 2>/dev/null | cut -d= -f2)
      local max_l=$(grep '^sla_max_loss_pct=' "$sla_f" 2>/dev/null | cut -d= -f2)
      say "    • Min Throughput: ${min_r:-0} kbps"
      say "    • Max Latency:    ${max_rtt:-0} ms"
      say "    • Max Loss:       ${max_l:-0} %"
    else
      say "    ${GRY}No SLA configured (heal only triggers on complete link disconnect).${RST}"
    fi
    echo
    local opt_timer_st="off"
    systemctl is-active -q "$WAT_PREFIX-auto-optimize.timer" 2>/dev/null && opt_timer_st="${GRN}active${RST}"
    say "  Off-Peak Auto-Optimize Timer: $opt_timer_st ${GRY}(daily scheduled re-evaluations)${RST}"
    echo
    printf '  %s change policy   %s configure SLA   %s retest & re-rank now   %s toggle timer   %s back\n' \
      "$(key_label p)" "$(key_label s)" "$(key_label r)" "$(key_label o)" "$(key_label b)"
    key_read
    case "$KEY" in
      p)
        echo
        say "  Choose carrier selection policy:"
        say "    ${CYN}1${RST} speed    (rank by Down+Up throughput, lowest RTT tiebreak)"
        say "    ${CYN}2${RST} latency  (rank by lowest round-trip latency)"
        say "    ${CYN}3${RST} direct   (prioritize direct unproxied paths over CDN)"
        say "    ${CYN}4${RST} bond     (automatically bond top direct performers)"
        ask_ok "Choice" "1" v_nonempty || continue
        case "$REPLY_V" in
          1|speed) echo speed >"$CONF/$n.policy" ;;
          2|latency) echo latency >"$CONF/$n.policy" ;;
          3|direct) echo direct >"$CONF/$n.policy" ;;
          4|bond) echo bond >"$CONF/$n.policy" ;;
          *) warn "Unknown policy '$REPLY_V'."; continue ;;
        esac
        ok "Policy saved: $(cat "$CONF/$n.policy")"
        pause ;;
      s)
        echo
        local cur_min=0 cur_rtt=0 cur_loss=0
        if [ -f "$sla_f" ]; then
          cur_min=$(grep '^sla_min_rate_kbps=' "$sla_f" | cut -d= -f2)
          cur_rtt=$(grep '^sla_max_rtt_ms=' "$sla_f" | cut -d= -f2)
          cur_loss=$(grep '^sla_max_loss_pct=' "$sla_f" | cut -d= -f2)
        fi
        ask_ok "Minimum required throughput in kbps (0 = none)" "${cur_min:-0}" v_num || continue
        cur_min=$REPLY_V
        ask_ok "Maximum tolerable RTT in ms (0 = none, e.g. 300)" "${cur_rtt:-0}" v_num || continue
        cur_rtt=$REPLY_V
        ask_ok "Maximum tolerable packet loss % (0 = none, e.g. 10)" "${cur_loss:-0}" v_num || continue
        cur_loss=$REPLY_V
        {
          echo "sla_min_rate_kbps=$cur_min"
          echo "sla_max_rtt_ms=$cur_rtt"
          echo "sla_max_loss_pct=$cur_loss"
        } >"$sla_f"
        chmod 600 "$sla_f"
        ok "SLA configured."
        pause ;;
      r)
        echo
        say "  Running auto-test & policy re-evaluation..."
        AUTO_OPTIMIZE=1 auto_retest "$n"
        pause ;;
      o)
        echo
        if systemctl is-active -q "$WAT_PREFIX-auto-optimize.timer" 2>/dev/null; then
          optimize_disable
        else
          optimize_enable
        fi
        sleep 1 ;;
      b|0|q|enter|esc) break ;;
    esac
  done
}

# ======================================================================================
#  Bandwidth Quotas & Limits Submenu
# ======================================================================================
limits_menu() { # name
  local n=$1 r cr
  r=$(role "$n"); cr=$(cfg "$n" carrier)
  while :; do
    page "Bandwidth Quotas & Rate Limits" "$n"
    say "  Global Speed Ceiling (max-mbps): $(cfg "$n" max-mbps | sed 's/^$/16 (default)/') MB/s"
    echo
    say "  ${BOLD}Configured Per-Port Limits & Quotas:${RST}"
    local -a p_limits=()
    mapfile -t p_limits < <(grep -E '^[[:space:]]*-[[:space:]]+[0-9]+' "$CONF/$n.yml" | grep -E 'rate=|quota=' || true)
    if [ "${#p_limits[@]}" -gt 0 ]; then
      local it
      for it in "${p_limits[@]}"; do
        say "    $it"
      done
    else
      say "    ${GRY}No per-port rate limits or quotas active.${RST}"
    fi
    echo
    local m=$(cfg "$n" metrics)
    if [ -n "$m" ]; then
      local prt_json
      prt_json=$(curl -fs --noproxy '*' --max-time 2 "http://$m/ports" 2>/dev/null)
      if [ -n "$prt_json" ]; then
        say "  ${BOLD}Live Port Quota Usage:${RST}"
        local pobj
        while read -r pobj; do
          [ -n "$pobj" ] || continue
          local lp qu ql qe
          lp=$(jget "$pobj" port)
          qu=$(jget "$pobj" quota_used)
          ql=$(jget "$pobj" quota_limit)
          qe=$(jget "$pobj" quota_exceeded)
          if [ "${ql:-0}" -gt 0 ]; then
            say "    Port $lp: used $(human "$qu") / $(human "$ql") $([ "$qe" = true ] && printf '%s[EXCEEDED]%s' "$RED$BOLD" "$RST")"
          fi
        done < <(grep -o '{[^{}]*}' <<<"$prt_json")
      fi
    fi
    echo
    printf '  %s speed ceiling   %s add/edit port limit   %s reset port quota   %s back\n' \
      "$(key_label m)" "$(key_label e)" "$(key_label r)" "$(key_label b)"
    key_read
    case "$KEY" in
      m)
        echo
        ask_ok "Global speed ceiling in MB/s (- or 0 or default = unset)" "$(cfg "$n" max-mbps)" v_mbps_adv || continue
        case "$REPLY_V" in -|0|default) REPLY_V='' ;; esac
        if [ -z "$REPLY_V" ]; then unset_value "$n" max-mbps; else set_value "$n" max-mbps "$REPLY_V"; fi
        ok "Saved. Restart '$n' to apply."
        pause ;;
      e)
        echo
        ask_ok "Port to limit" "" v_port || continue
        local lport=$REPLY_V
        ask_ok "Rate limit (e.g. 5MB, 300k, 0 = none)" "0" v_pool_bytes || continue
        local lrate=$REPLY_V
        ask_ok "Quota limit (e.g. 100GB, 500MB, 0 = none)" "0" v_pool_bytes || continue
        local lquota=$REPLY_V
        set_port_limit "$n" "$lport" "$lrate" "$lquota"
        ok "Saved limit for port $lport. Hot-reloaded automatically by engine."
        pause ;;
      r)
        echo
        ask_ok "Port to reset quota for" "" v_port || continue
        local rport=$REPLY_V
        if [ -n "$m" ]; then
          local rres
          rres=$(curl -fs --noproxy '*' --max-time 3 -X POST "http://$m/quota/reset?port=$rport" 2>/dev/null)
          if [ -n "$rres" ]; then
            ok "Quota for port $rport reset."
          else
            err "Failed to reset quota on metrics server http://$m."
          fi
        else
          warn "Tunnel '$n' has no metrics endpoint configured."
        fi
        pause ;;
      b|0|q|enter|esc) break ;;
    esac
  done
}

tunnel_page() {
  local n=$1 r run
  while :; do
    [ -f "$CONF/$n.yml" ] || return 0
    r=$(role "$n")
    page "Tunnel $n" "$r"
    tunnel_card "$n"
    run=$(systemctl is-active "${WAT_PREFIX}@$n" 2>/dev/null)
    local run_txt; [ "$run" = active ] && run_txt="Stop Tunnel Daemon" || run_txt="Start Tunnel Daemon"
    echo
    printf '  %s[Actions & Diagnostics]%s                 %s[Configuration & Network]%s\n' "$CYN$BOLD" "$RST" "$CYN$BOLD" "$RST"
    printf '    %s Live Logs                           %s Port Forwarding Mappings\n' "$(key_label l)" "$(key_label p)"
    printf '    %s Live Throughput Monitor             %s Change Carrier & Desync Mode\n' "$(key_label m)" "$(key_label c)"
    printf '    %s Built-in Speedtest                  %s Bonding Manager (Multi-Path)\n' "$(key_label v)" "$(key_label b)"
    printf '    %s Full Link Diagnostics               %s Quotas & Bandwidth Ceilings\n' "$(key_label d)" "$(key_label q)"
    if [ "$r" = Kharej ]; then
      printf '                                           %s Show Emergency Token / Key\n' "$(key_label t)"
    else
      printf '                                           %s Auto Mode & SLA Settings\n' "$(key_label a)"
    fi
    echo
    printf '  %s[Service Lifecycle]%s                     %s[Danger Zone]%s\n' "$CYN$BOLD" "$RST" "$RED$BOLD" "$RST"
    printf '    %s Restart Tunnel Daemon               %s %sDelete Tunnel Permanently%s\n' "$(key_label r)" "$(key_label x)" "$RED" "$RST"
    printf '    %s %-32s  %s Advanced YAML Settings\n' "$(key_label s)" "$run_txt" "$(key_label o)"
    printf '    %s Toggle Autostart at Boot\n' "$(key_label e)"
    echo
    hr
    printf '    %s Back to Dashboard                                        %s Help\n' "$(key_label 0)" "$(key_label '?')"
    key_read
    case "$KEY" in
      d|D) page "Diagnose" "$n"; run_flow test_tunnel "$n"; pause ;;
      v|V) page "Speed test" "$n"; run_flow speed_test "$n"; pause ;;
      l|L) page "Logs" "$n"; run_flow logs_menu "$n"; pause ;;
      m|M) run_flow live_monitor ;;
      p|P) run_flow edit_ports "$n"; pause ;;
      q|Q) run_flow limits_menu "$n" ;;
      c|C) page "Connection type" "$n"; run_flow change_type "$n"; pause ;;
      b|B) run_flow bonding_menu "$n" ;;
      a|A) [ "$r" = Iran ] && run_flow auto_menu "$n" ;;
      h|H) [ "$r" = Iran ] && { page "Kharej address" "$n"; echo; run_flow change_peer "$n"; pause; } ;;
      t|T) if [ "$r" = Kharej ]; then
           page "Token" "$n"; echo; say "  Paste this on the Iran server ($SELF → n → Iran):"; echo; show_token "$n"; echo; warn "The token contains the key. Share it privately."
         else page "New token" "$n"; echo; run_flow change_key "$n"; fi
         pause ;;
      k|K) if [ "$r" = Kharej ]; then page "New key" "$n"; run_flow change_key "$n"; pause; else anticensor_menu "$n"; fi ;;
      o|O) run_flow adv_menu "$n" ;;
      r|R) echo; if confirm "Restart '$n'? Open connections drop." n; then step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"; sleep 1; fi ;;
      s|S) echo
         if [ "$run" = active ]; then systemctl stop "${WAT_PREFIX}@$n" 2>/dev/null; ok "Stopped (it still starts at boot if enabled)."; sleep 1
         else start_unit "$n"; sleep 1; fi ;;
      e|E) echo
         if systemctl is-enabled -q "${WAT_PREFIX}@$n" 2>/dev/null; then systemctl disable "${WAT_PREFIX}@$n" >/dev/null 2>&1; ok "Will NOT start at boot."
         else systemctl enable "${WAT_PREFIX}@$n" >/dev/null 2>&1; ok "Will start at boot."; fi
         sleep 1 ;;
      x|X) page "Delete tunnel" "$n"; echo; run_flow delete_tunnel "$n"; pause ;;
      0|esc) return 0 ;;
      \?|\/|help) flash "Keys: l=logs, m=monitor, v=speedtest, d=diagnostics, p=ports, c=carrier, b=bonding, q=limits, r=restart, s=stop, x=delete, 0=back" ;;
      *) : ;;
    esac
  done
}

# ======================================================================================
#  Auto-heal, update, rollback, uninstall, settings
# ======================================================================================
heal_enable() {
  local mgr=/usr/local/bin/wattun-manager
  [ "$SANDBOX" = 1 ] && mgr=$MGR
  {
    printf '[Unit]\nDescription=WatTunnel auto-heal%s\n[Service]\nType=oneshot\n' "$([ "$SANDBOX" = 1 ] && echo " (sandbox $WAT_PREFIX)")"
    unit_env_lines
    printf 'ExecStart=%s heal\n' "$mgr"
  } >"/etc/systemd/system/$HEAL_UNIT.service"
  cat >"/etc/systemd/system/$HEAL_UNIT.timer" <<EOF
[Unit]
Description=WatTunnel auto-heal every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
  chmod 644 "/etc/systemd/system/$HEAL_UNIT.service" "/etc/systemd/system/$HEAL_UNIT.timer"
  systemctl daemon-reload && systemctl enable --now "$HEAL_UNIT.timer" >/dev/null 2>&1 && ok "Auto-heal enabled."
}
heal_disable() { systemctl disable --now "$HEAL_UNIT.timer" >/dev/null 2>&1; ok "Auto-heal disabled."; }
heal() { # restart Iran tunnels whose link is down or breaches SLA 3 checks in a row
  local n cnt f st cyc sla_f b_f
  mkdir -p "$RUN"
  for n in $(tunnels); do
    [ "$(role "$n")" = Iran ] && systemctl is-enabled -q "${WAT_PREFIX}@$n" || continue
    f="$RUN/$n.down"
    b_f="$RUN/$n.sla_breach"
    st=$(systemctl is-active "${WAT_PREFIX}@$n" 2>/dev/null)
    if [ "$st" = inactive ]; then rm -f "$f" "$RUN/$n.cycles" "$b_f"; continue; fi # stopped on purpose: leave it alone
    local s_raw; s_raw=$(stats "$n")
    local rx_age; rx_age=$(jget "$s_raw" last_rx_age_ms 2>/dev/null || echo -1)
    if [ "$(jget "$s_raw" alive)" = true ] && [ "$rx_age" -ge 0 ] && [ "$rx_age" -lt 35000 ]; then
      rm -f "$f" "$RUN/$n.cycles"
      sla_f="$CONF/$n.sla"
      if [ -f "$sla_f" ]; then
        local min_r max_rtt max_loss rtt loss rate_kbps breached=0
        min_r=$(grep '^sla_min_rate_kbps=' "$sla_f" 2>/dev/null | cut -d= -f2)
        max_rtt=$(grep '^sla_max_rtt_ms=' "$sla_f" 2>/dev/null | cut -d= -f2)
        max_loss=$(grep '^sla_max_loss_pct=' "$sla_f" 2>/dev/null | cut -d= -f2)
        rtt=$(jget "$s_raw" srtt_ms)
        loss=$(jget "$s_raw" loss_pct)
        rate_kbps=$(( $(jget "$s_raw" rate_bps) / 1000 ))
        [ -n "$max_rtt" ] && [ "$max_rtt" -gt 0 ] && [ "${rtt%.*}" -gt "$max_rtt" ] 2>/dev/null && breached=1
        [ -n "$max_loss" ] && [ "$max_loss" -gt 0 ] && [ "${loss%.*}" -gt "$max_loss" ] 2>/dev/null && breached=1
        [ -n "$min_r" ] && [ "$min_r" -gt 0 ] && [ "$rate_kbps" -lt "$min_r" ] 2>/dev/null && breached=1
        if [ "$breached" = 1 ]; then
          local b_cnt=$(( $(cat "$b_f" 2>/dev/null || echo 0) + 1 ))
          echo "$b_cnt" >"$b_f"
          if [ "$b_cnt" -ge 3 ]; then
            logger -t wattun-heal "tunnel $n breached SLA for 3 consecutive checks (rtt=${rtt}ms, loss=${loss}%, rate=${rate_kbps}kbps), triggering re-evaluation"
            rm -f "$b_f"
            touch "$RUN/$n.sla_triggered"
            if [ -f "$CONF/$n.auto" ]; then
              heal_retest "$n"
            fi
          fi
        else
          rm -f "$b_f"
        fi
      fi
      continue
    fi
    cnt=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$cnt" >"$f"
    if [ "$cnt" -ge 3 ]; then
      logger -t wattun-heal "tunnel $n down for $cnt checks, restarting"
      systemctl restart "${WAT_PREFIX}@$n"; rm -f "$f"
      cyc=$(( $(cat "$RUN/$n.cycles" 2>/dev/null || echo 0) + 1 )); echo "$cyc" >"$RUN/$n.cycles"
      # a direct Iran pool tunnel that restarts do not fix: tell the operator the kit exists (blackout Cmd)
      if [ "$cyc" -ge 2 ] && ! is_reverse "$n" && is_pool "$(cfg "$n" carrier)" \
         && [ "$(cfg "$n" fake-sni)" = '' ]; then
        logger -t wattun-heal "tunnel $n: restarts do not fix it and its carrier port is plain TCP; if the route is being SNI-filtered, run: wattun blackout $n <allowlisted-name>"
      fi
      # still down after three restart cycles (9 checks) on a pool/icmp tunnel: try the full matrix unattended
      if [ "$cyc" -ge 3 ] && ! is_reverse "$n" && { is_pool "$(cfg "$n" carrier)" || [ "$(cfg "$n" carrier)" = icmp ]; }; then
        heal_matrix "$n"
      fi
      # auto tunnel still down after two restart cycles (6 checks): test the other connection types in the background
      # (a plain CDN tunnel gets a fresh Cloudflare edge scan instead: dead edge IPs are replaced)
      if [ "$cyc" -ge 2 ] && { [ -f "$CONF/$n.auto" ] || { cdn_ok && cdn_tunnel_p "$n"; }; }; then heal_retest "$n"; fi
    fi
  done
}
# A running tunnel keeps executing the binary it was started with. Once update/rollback replaces the file,
# /proc/PID/exe reads "... (deleted)": that tunnel still runs the OLD version until it is restarted.
bin_ver() { "${1:-$BIN}" -version 2>/dev/null | awk '{print $2; exit}'; }
is_stale() {
  local pid
  pid=$(systemctl show -p MainPID --value "${WAT_PREFIX}@$1" 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != 0 ] && [[ "$(readlink "/proc/$pid/exe" 2>/dev/null)" == *"(deleted)"* ]]
}
stale_tunnels() { local n; for n in $(tunnels); do systemctl is-active -q "${WAT_PREFIX}@$n" 2>/dev/null && is_stale "$n" && printf '%s ' "$n"; done; }
restart_stale() { # offer to restart tunnels that still run the old binary, then prove they switched
  local st n bad=''
  st=$(stale_tunnels)
  [ -n "$st" ] || { ok "All running tunnels use wattun $(bin_ver)."; return 0; }
  warn "Still running the OLD binary: ${BOLD}${st% }${RST}"
  hint "They switch to $(bin_ver) only after a restart. A restart drops open connections for a few seconds."
  confirm "Restart them now?" y || { hint "Later: open the tunnel and press [r], or Settings -> restart all."; return 0; }
  for n in $st; do step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"; done
  sleep 1
  for n in $st; do is_stale "$n" && bad="$bad $n"; done
  if [ -n "$bad" ]; then err "Still on the old binary:$bad (see: journalctl -u ${WAT_PREFIX}@NAME)"; return 1; fi
  ok "Tunnels now run wattun $(bin_ver)."
}
restart_all() {
  local n c=0
  for n in $(tunnels); do
    if systemctl is-enabled -q "${WAT_PREFIX}@$n" 2>/dev/null || systemctl is-active -q "${WAT_PREFIX}@$n" 2>/dev/null; then
      step "Restarting ${WAT_PREFIX}@$n" systemctl restart "${WAT_PREFIX}@$n"; c=$((c+1))
    fi
  done
  [ "$c" -gt 0 ] || warn "No tunnels to restart."
}
update() { # [installer args...]
  local url="https://raw.githubusercontent.com/$REPO/main/install.sh" tmp before after mbefore imgr a
  local ienv=()
  if [ "$SANDBOX" = 1 ]; then
    for a in "$@"; do [ "$a" = --uninstall ] && { err "Sandbox: use the manager's uninstall (Settings), not the installer's --uninstall (it removes the production units)."; return 1; }; done
    imgr=$MGR; [ "$MGR" = /usr/local/bin/wattun-manager ] && imgr=${BIN%/*}/wattun-manager
    mkdir -p "${BIN%/*}" || { err "Cannot create ${BIN%/*}"; return 1; }
    say "  Sandbox $WAT_PREFIX: the update writes only $BIN, $imgr and $CONF (not /usr/local/bin, not wattun@.service)."
  fi
  before=$(bin_ver); mbefore=$(cksum <"${imgr:-$MGR}" 2>/dev/null)
  tmp=$(mktemp /tmp/wattun-install.XXXXXX)
  trap 'rm -f "$tmp" "$tmp.unit" ${mkeep:+"$mkeep"}' EXIT # a kill mid-update must not leave root-owned temp files
  [ "$SANDBOX" = 1 ] && ienv=(WAT_BIN="$BIN" WAT_MGR="$imgr" WAT_CONF="$CONF" WAT_UNIT="$tmp.unit" WAT_REQUIRE_SANDBOX=1) # the installer's unit file goes to a throwaway path
  # raw.githubusercontent.com caches main for minutes: resolve main to a commit sha and fetch everything by it
  local sha mref="" mkeep
  sha=$(curl -fsSL --max-time 10 "${WAT_PROXY:-}https://api.github.com/repos/$REPO/commits/main" 2>/dev/null | grep -m1 '"sha"' | sed -n 's/.*"sha"[^"]*"\([0-9a-f]\{40\}\)".*/\1/p')
  if [ -n "$sha" ]; then url="https://raw.githubusercontent.com/$REPO/$sha/install.sh"; mref=$sha; ienv+=(WAT_MGR_REF="$sha")
  else warn "Could not resolve the latest commit; using the main branch (GitHub's cache may be a few minutes old)."; fi
  # keep the current manager so a bad replacement can be undone
  mkeep=$(mktemp /tmp/wattun-mgr.XXXXXX); cp -f "${imgr:-$MGR}" "$mkeep" 2>/dev/null || { rm -f "$mkeep"; mkeep=""; }
  spin_start "Downloading the installer"
  curl -fsSL --max-time 60 --retry 2 -o "$tmp" "${WAT_PROXY:-}$url"; local rc=$?
  spin_stop
  if [ "$rc" -ne 0 ] || ! head -c 2 "$tmp" | grep -q '#!'; then
    rm -f "$tmp" "$mkeep"; err "Update failed (could not download the installer). If GitHub is blocked: WAT_PROXY=https://ghproxy.net/ $SELF update"; return 1
  fi
  ok "Installer downloaded${mref:+ (${mref:0:7})}"
  env ${ienv[@]+"${ienv[@]}"} WAT_FROM_MANAGER=1 bash "$tmp" "$@"; rc=$?
  rm -f "$tmp" "$tmp.unit"
  trap - EXIT
  [ "$rc" -eq 0 ] || { rm -f "$mkeep"; err "The installer reported an error. Nothing was changed: still wattun ${before:-?}."; return 1; }
  # self-check: in a sandbox the new manager must understand WAT_PREFIX, or it would drive the production paths
  if [ "$SANDBOX" = 1 ] && [ -n "$mkeep" ] && ! grep -q 'WAT_PREFIX' "${imgr:-$MGR}" 2>/dev/null; then
    install -m 755 "$mkeep" "${imgr:-$MGR}.new" && mv -f "${imgr:-$MGR}.new" "${imgr:-$MGR}"
    rm -f "$mkeep"; err "The new manager has no sandbox (WAT_PREFIX) support; the previous manager was restored."; return 1
  fi
  rm -f "$mkeep"
  after=$(bin_ver)
  echo
  if [ -z "$after" ]; then err "$BIN does not run after the update. Roll back from the dashboard ([r])."; return 1
  elif [ "$after" != "$before" ]; then ok "wattun updated: ${BOLD}${before:-none} -> $after${RST}"
  else ok "wattun is already the latest release (${BOLD}$after${RST})."; fi
  [ "$(cksum <"${imgr:-$MGR}" 2>/dev/null)" != "$mbefore" ] && ok "Manager updated."
  restart_stale
  return 0
}
rollback() {
  [ -x "$BIN.prev" ] || { warn "No previous version saved."; return 0; }
  say "  Current: ${BOLD}$($BIN -version 2>&1)${RST}    Previous: ${BOLD}$($BIN.prev -version 2>&1)${RST}"
  echo
  confirm "Roll back to the previous version?" n || return 0
  cp -f "$BIN" "$BIN.rb" && mv -f "$BIN.prev" "$BIN" && mv -f "$BIN.rb" "$BIN.prev"
  ok "Rolled back: wattun is now ${BOLD}$(bin_ver)${RST}."
  restart_stale
  return 0
}
uninstall_all() {
  local n list=() u units
  for n in $(tunnels); do list+=("$n"); done
  echo
  if [ "${#list[@]}" -gt 0 ]; then
    warn "These tunnels will be stopped:"
    for n in "${list[@]}"; do printf '      %s%-14s%s %s · %s\n' "$BOLD" "$n" "$RST" "$(role "$n")" "$(cfg "$n" carrier)"; done
  else hint "No tunnels are configured."; fi
  echo
  if [ "$NONINTERACTIVE" = 1 ]; then REPLY_V=uninstall # --yes is the confirmation
  else ask "Type 'uninstall' to remove WatTunnel (empty = cancel)" ""; fi
  [ "$REPLY_V" = uninstall ] || { warn "Cancelled."; return 1; }
  heal_disable >/dev/null 2>&1; rm -f "/etc/systemd/system/$HEAL_UNIT.service" "/etc/systemd/system/$HEAL_UNIT.timer"
  # loaded instances plus every configured name (enabled-but-unloaded ones are not in list-units)
  units=$(systemctl list-units --all --plain --no-legend "${WAT_PREFIX}@*" 2>/dev/null | awk '{print $1}')
  for n in "${list[@]}"; do units+=$'\n'"${WAT_PREFIX}@$n.service"; done
  for u in $(printf '%s\n' "$units" | sort -u); do
    systemctl disable --now "$u" >/dev/null 2>&1
  done
  kreply_restore
  for u in $(systemctl list-units --all --plain --no-legend "${WAT_PREFIX}-autowatch-*" "${WAT_PREFIX}-autoretest-*" 2>/dev/null | awk '{print $1}'); do
    systemctl stop "$u" >/dev/null 2>&1
  done
  rm -f "/etc/systemd/system/${WAT_PREFIX}@.service" "$BIN" "$BIN.prev"
  [ "$SANDBOX" = 1 ] && rm -rf "$RUN" "$AUTO_RUN"
  if [ "$SANDBOX" = 1 ] && [ "${BIN%/*}" = "/opt/$WAT_PREFIX" ]; then rm -rf "/opt/$WAT_PREFIX"; ok "Removed /opt/$WAT_PREFIX"; fi
  systemctl daemon-reload
  ok "Services and binaries removed."
  if [ -d "$CONF" ] && confirm "Also delete $CONF (tunnel configs, keys, tokens)?" "$([ "$SANDBOX" = 1 ] || [ "$NONINTERACTIVE" = 1 ] && echo y || echo n)"; then rm -rf "$CONF"; ok "Configuration deleted."; fi
  ok "WatTunnel removed."
  if [ "$SANDBOX" = 1 ]; then
    if [ "${MGR%/*}" = "/opt/$WAT_PREFIX" ]; then rm -rf "/opt/$WAT_PREFIX"; ok "Removed /opt/$WAT_PREFIX (including this script)"
    else hint "Sandbox: this script ($MGR) was left in place; delete it by hand if you copied it."; fi
  else rm -f "$MGR"; fi
  return 0
}
settings_menu() {
  local heal_on anim_on
  while :; do
    systemctl is-enabled -q "$HEAL_UNIT.timer" 2>/dev/null && heal_on="${GRN}[ON]${RST}" || heal_on="${GRY}[OFF]${RST}"
    [ "$(conf_get anim 1)" = 1 ] && anim_on="${GRN}[ON]${RST}" || anim_on="${GRY}[OFF]${RST}"
    page "Settings"
    say "  Auto-heal   $heal_on   ${GRY}restarts an Iran tunnel whose link stays down for 3 minutes${RST}"
    say "  Animations  $anim_on   ${GRY}spinners and the intro (WAT_NO_ANIM=1 also turns them off)${RST}"
    echo
    printf '  %s toggle auto-heal   %s toggle animations   %s kernel speed boost (/boost)\n' "$(key_label h)" "$(key_label a)" "$(key_label b)"
    printf '  %s restart all tunnels\n' "$(key_label r)"
    echo
    say "  ${BOLD}Maintenance${RST}"
    printf '  %s roll back to the previous version   %s uninstall WatTun   %s back\n' "$(key_label v)" "$(key_label x)" "$(key_label 0)"
    key_read
    case "$KEY" in
      v|V) page "Roll back"; echo; run_flow rollback; pause ;;
      x|X) page "Uninstall"; if run_flow uninstall_all; then exit 0; fi; pause ;;
      h) echo; if systemctl is-enabled -q "$HEAL_UNIT.timer" 2>/dev/null; then heal_disable; else heal_enable; fi; sleep 1 ;;
      r) echo; if confirm "Restart all tunnels? Open connections drop." n; then restart_all; sleep 1; fi ;;
      a) if [ "$(conf_get anim 1)" = 1 ]; then conf_set anim 0; ANIM=0; else conf_set anim 1; [ "$IS_TTY" = 1 ] && [ "${WAT_NO_ANIM:-0}" != 1 ] && ANIM=1; fi ;;
      b|B) boost_menu ;;
      0|q|enter|esc) return 0 ;;
      *) : ;;
    esac
  done
}

# ======================================================================================
#  Main dashboard
# ======================================================================================
need_tunnel() { [ -f "$CONF/$1.yml" ] || { err "No tunnel named '$1'. See: $SELF status"; return 1; }; }
main_menu() {
  local num d rest
  while :; do
    page_full "Dashboard" "$([ -n "$VER" ] && echo "wattun $VER")"
    dash_table
    local st; st=$(stale_tunnels)
    [ -n "$st" ] && printf '\n  %s!%s %s%s%s still run the old binary. Press its number, then %s[r]%s restart, to use wattun %s.\n' \
      "$YEL" "$RST" "$BOLD" "${st% }" "$RST" "$CYN" "$RST" "$VER"
    dash_actions
    while :; do
      printf '\r%s  %s▸%s %s%s%s' "$EL" "$CYN" "$RST" "$YEL" "$PMSG" "$RST"; PMSG=''
      key_read
      printf '\r%s' "$EL"
      [ "$IS_TTY" = 1 ] || echo
      case "$KEY" in
        [1-9])
          num=$KEY
          if [ "${#DASH_N[@]}" -gt 9 ]; then printf '%s' "$KEY"; IFS= read -r -t 5 rest || true; num="$KEY$rest"; fi
          if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#DASH_N[@]}" ]; then tunnel_page "${DASH_N[$((num-1))]}"; break
          else flash "No tunnel number $num."; fi ;;
        n|N) new_tunnel; break ;;
        a|A) batch_actions_menu; break ;;
        m|M) if [ "${#DASH_N[@]}" -gt 0 ]; then run_flow live_monitor; fi; break ;;
        s|S) settings_menu; break ;;
        u|U) page "Update"; echo; if update; then echo; hint "The manager reloads itself to show the new version."; pause; exec "$MGR"; fi; pause; break ;;
        q|Q) cur_show; echo; exit 0 ;;
        enter) break ;;
        *) if [ "${#DASH_N[@]}" -gt 0 ]; then flash "Unknown key '$KEY'. Press a tunnel's number to manage it, or n, m, u, s, q."
           else flash "Unknown key '$KEY'. Press n to create your first tunnel."; fi ;;
      esac
    done
  done
}

# Flags of kharej / iran / cdn-tune / auto-test / delete / uninstall -> NI_* presets and NI_POS (positional words).
# Both "--flag value" and "--flag=value" work. A bad value stops here with a message on stderr (rc 1).
ni_parse() {
  local f v hasv
  NI_POS=()
  while [ $# -gt 0 ]; do
    f=$1; shift; hasv=0; v=''
    case "$f" in --*=*) v=${f#*=}; f=${f%%=*}; hasv=1 ;; esac
    case "$f" in
      --yes) NI_YES=1; continue ;;
      --governor)
        if [ "$hasv" = 1 ]; then
          v_governor "$v" || return 1
          case "${v,,}" in on|1|true) NI_GOVERNOR=true ;; *) NI_GOVERNOR=false ;; esac
        elif [ $# -gt 0 ] && [[ "$1" != --* ]]; then
          v=$1; shift; v_governor "$v" || return 1
          case "${v,,}" in on|1|true) NI_GOVERNOR=true ;; *) NI_GOVERNOR=false ;; esac
        else
          NI_GOVERNOR=true
        fi; continue ;;
      --carrier|--name|--listen|--path|--addr|--sni|--cdn-domain|--ports|--max-mbps|--token|--map|--pick|--sessions|--conns|--mtu|--policy|--fake-sni|--fake-mode|--fake-ttl|--pool-rotate|--pool-rotate-bytes|--preset|--ech|--dns-listen|--src-ip)
        if [ "$hasv" = 0 ]; then
          [ $# -gt 0 ] || { err "$f needs a value"; return 1; }
          v=$1; shift
        fi ;;
      --*) err "Unknown option '$f'. See: $SELF help"; return 1 ;;
      *) NI_POS+=("$f"); continue ;;
    esac
    case "$f" in
      --carrier) case "$v" in wss|grpc|tcp|tls|ws|h2|h2c|udp|icmp|auto|fortress) NI_CARRIER=$v ;; *) err "--carrier: use wss, grpc, tcp, tls, ws, h2, h2c, udp, icmp, auto or fortress (got '$v')"; return 1 ;; esac ;;
      --preset) v_preset "$v" || return 1; NI_PRESET=$(preset_canonical "$v") ;;
      --ech)
        v_ech "$v" || return 1
        case "${v,,}" in
          off|auto|ladder) NI_ECH=${v,,} ;;
          *) NI_ECH=$v ;;
        esac ;;
      --name) v_name_fmt "$v" || return 1; NI_NAME=$v ;;
      --listen) v_port "$v" || return 1; NI_LISTEN=$((10#$v)) ;;
      --path) v_path "$v" || return 1; NI_PATH=$v ;;
      --addr) v_host "$v" || return 1; NI_ADDR=$v ;;
      --sni) v_host "$v" || return 1; NI_SNI=$v ;;
      --cdn-domain) v_domain_opt "$v" || return 1; NI_CDN=$v ;;
      --ports) [ -n "$v" ] || { err "--ports needs a list such as 18999,2000,53/udp"; return 1; }; NI_PORTS=$v ;;
      --max-mbps) v_mbps "$v" || return 1; NI_MBPS=$v ;;
      --fake-sni) v_sni_name "$v" || return 1; NI_FAKESNI=$v ;;
      --fake-mode) case "$v" in seq|ttl|sum|seqsum|auto|rst) NI_FAKEMODE=$v ;; *) err "--fake-mode: use seq, ttl, sum, seqsum, auto or rst (got '$v')"; return 1 ;; esac ;;
      --fake-ttl) [[ "$v" =~ ^[0-9]{1,3}$ ]] && [ "$v" -le 255 ] || { err "--fake-ttl: use a hop count 0-255 (0 = auto, got '$v')"; return 1; }; NI_FAKETTL=$v ;;
      --pool-rotate) v_pool_rotate "$v" || return 1; NI_POOLROT=$v ;;
      --pool-rotate-bytes) v_pool_bytes "$v" || return 1; NI_POOLBYTES=$v ;;
      --token) v_token "$v" || return 1; NI_TOKEN=$v ;;
      --map) [ -n "$v" ] || { err "--map needs a list such as 39901:18999,8443:443"; return 1; }; NI_MAP=$v ;;
      --pick) case "$v" in best|bond) NI_PICK=$v ;; *,*) [[ "$v" =~ ^[0-9]+(,[0-9]+)+$ ]] || { err "--pick: rows joined with commas, such as 1,3 (got '$v')"; return 1; }; NI_PICK=$v ;; *) [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] || { err "--pick: use best, bond, a row number or rows such as 1,3 (got '$v')"; return 1; }; NI_PICK=$((10#$v)) ;; esac ;;
      --sessions) [[ "$v" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$v))" -ge 1 ] || { err "--sessions: use a number of sessions, 1 or more (got '$v')"; return 1; }; NI_SESSIONS=$((10#$v)) ;;
      --conns) v_conns "$v" || return 1; NI_CONNS=$((10#$v)) ;;
      --mtu) v_mtu "$v" || return 1; NI_MTU=$((10#$v)) ;;
      --policy) case "$v" in speed|latency|direct|bond) NI_POLICY=$v ;; *) err "--policy: use speed, latency, direct or bond (got '$v')"; return 1 ;; esac ;;
      --dns-listen) v_dns_listen "$v" || return 1; NI_DNSLISTEN=$v ;;
      --src-ip) v_src_ip "$v" || return 1; NI_SRCIP=$v ;;
    esac
  done
  return 0
}
v_name_fmt() { [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] && return 0; err "--name: use 1-32 letters, digits, - or _ (got '$1')"; return 1; }
# Run a command-line flow without a subshell (so ERRN counts) and make sure a failure always says something on stderr.
ni_run() { # fn args...
  local rc
  ERRN=0
  "$@"; rc=$?
  if [ "$rc" -ne 0 ] && [ "$ERRN" -eq 0 ] && [ "$NONINTERACTIVE" = 1 ]; then err "failed (rc $rc), see the output above"; fi
  return "$rc"
}

usage() {
  cat <<EOF
WatTun manager $VER

Usage: $SELF [command]

  (no command)          dashboard: all tunnels; manage one, create, update...
  new [kharej|iran]     create a tunnel (do Kharej FIRST: it makes the token)
  kharej | iran         same as new kharej / new iran
  status | list         one line per tunnel
  monitor               live dashboard (any key exits)
  ports NAME            edit the port mappings of a tunnel
  test NAME             connection doctor + speed test
  speedtest NAME [MB]   speed test only (default 10 MB each way)
  logs NAME             follow the log
  token NAME            print the Kharej token again
  preset NAME [PRESET]  apply built-in anti-censorship preset (mci, irancell, blackout, conservative)
  test-bypass NAME      automated connectivity & filter bypass test for anti-censorship profile
  profile save|list|show|del|apply   resilience profiles: save one tunnel's fake-sni/pool-rotate combination
                        under a name and re-apply it later (profile save NAME [tunnel])
  blackout NAME [SNI|PRESET] turn on resilience: accepts operator preset (mci, irancell, blackout, conservative)
                        or custom allowlisted SNI (e.g. mci.ir), restarts, tests filter bypass.
                        Fine-tuning (mode, ttl, pool-rotate, ech): tunnel page -> o -> k. Linux only.
  arm-blackout NAME     arm Kharej in Fortress mode (multi-carrier listeners, sysctls, firewall)
                        or arm Iran for autonomous failover (silence detection, heal timer)
  audit-blackout NAME   audit blackout readiness (capabilities, sysctls, port conflicts, DNS relay)
  matrix NAME           anti-censor matrix: test EVERY resilience combination (fake-SNI x mode x ECH)
                        from this Iran server with throw-away clients, apply the best that connects.
                        Kharej is never contacted except through the tunnel itself. Linux only.
  boost [--status|--undo|--yes]  kernel speed boost (BBR, 64MB buffers, FQ)
  backup [dest.tar.gz]  backup all tunnel configs and keys to archive
  restore <archive.tar.gz> restore tunnel configs and keys from archive
  start-all | stop-all  bulk start or stop all tunnels
  restart-all           restart all tunnels
  auto-optimize         run off-peak carrier re-evaluation for auto tunnels
  auto-test NAME        test every connection type again for an auto Iran tunnel, offer to switch
  auto-ip NAME IP       auto Kharej tunnel: set Iran's IP by hand (creates NAME-r, the reverse side)
  cdn-tune NAME [full]  Iran CDN tunnel (ws/wss/h2/h2c/grpc): find the Cloudflare edges that serve the domain over ECH + TLS settings, apply (needs wattun 2.2.0)
  heal                  restart Iran tunnels whose link is down (used by the timer)
  update | rollback     install the latest release / go back one version
  delete NAME           stop a tunnel and delete its config, key and token (asks you to type the name)
  uninstall             remove WatTun from this server (asks first)
  help                  this text

Unattended mode (no tty, nothing is asked; --yes turns it on, and so does any --flag when stdin is not a tty;
or NONINTERACTIVE=1). Plain output, errors on stderr, exit code 0 = done, 1 = failed:
  kharej --carrier wss|grpc|tcp|tls|ws|h2|h2c|udp|icmp|auto --name NAME [--listen PORT] [--path /wat] [--addr HOST]
         [--sni HOST] [--cdn-domain D] [--ports 18999,2000,53/udp] [--max-mbps N] --yes
         creates and starts the Kharej tunnel; the last lines are TUNNEL=NAME and TOKEN=wat1:...
         (--addr skips the public-IP detection; --cdn-domain is for auto; --listen/--path/--sni/--max-mbps for the others)
  iran --token TOKEN --map 39901:18999[,8443:443] [--name NAME] [--pick best|bond|N|N,N...] [--sessions N] [--max-mbps N] --yes
         creates and starts the Iran tunnel. Auto token: runs the test, --pick chooses a row (default best, bond = all
         working direct carriers, 1,3 = join those rows). CDN token: automatic CDN tuning. Ends with LINK=up|down and TUNNEL=NAME; exit 1 if down.
         --sessions N writes "sessions: N" (only with wattun 2.3.0 or newer; otherwise it is ignored with a warning)
         --preset mci|irancell|blackout|conservative applies an operator-tailored anti-censorship preset
         --fake-sni NAME [--fake-mode seq|ttl|sum|seqsum|auto|rst] [--fake-ttl 0-255] enables the fake-SNI desync on a
         fixed-type token (wattun 2.7.0 or newer; Linux only, needs CAP_NET_RAW; --fake-ttl only with --fake-mode ttl;
         seqsum needs 2.8.0, sum needs 2.7.1, auto/rst need 2.9.0)
         [--pool-rotate 90s|30m|4h] [--pool-rotate-bytes 500MB|4G] recycle each healthy pool connection after this
         long / this much traffic (pool-rotate needs wattun 2.8.0, --pool-rotate-bytes 2.8.1; Linux only)
         [--ech off|auto|ladder] Encrypted Client Hello mode (ladder relays DoH via tunnel port 53; 2.9.0+)
         [--governor on|off] ICMP volume pacer against reroute triggers (2.9.0+)
  cdn-tune NAME [full] --yes      apply the best CDN variant without asking
  auto-test NAME --yes            re-test an auto Iran tunnel, switch to --pick (default best) without asking
  delete NAME --yes               delete a tunnel without asking
  uninstall --yes                 uninstall without asking; also deletes the config directory
  Flags also accept --flag=value.

Environment: WAT_NO_ANIM=1 (no animations)  NO_COLOR=1 (no colours)  WAT_PROXY=https://ghproxy.net/

Sandbox: WAT_PREFIX=wattest wattun-manager ... keeps everything under /etc/wattest, /opt/wattest and wattest@ units.
  Other overrides: WAT_CONF, WAT_BIN, WAT_RUN, WAT_AUTO_RUN (single paths). The first run needs: WAT_PREFIX=wattest wattun-manager update
EOF
}

main() {
  [ -x "$BIN" ] && VER=$("$BIN" -version 2>/dev/null | awk '{print $2; exit}')
  case "${1:-}" in help|-h|--help) usage; return 0 ;; esac
  case "${1:-}" in kharej|iran|cdn-tune|auto-test|delete|uninstall|preset|blackout|test-bypass|test-anticensor|matrix|arm-blackout|audit-blackout|boost) ni_parse "${@:2}" || exit 1 ;; esac
  case "${1:-}" in auto-retest) [ "${2:-}" = --yes ] && NONINTERACTIVE=1 ;; esac
  if [ "$NONINTERACTIVE" = 1 ]; then
    case "${1:-}" in ''|new|monitor|ports|logs) err "'${1:-(no command)}' needs a terminal; unattended use: kharej, iran, cdn-tune, auto-test, delete, uninstall, status, test, token, matrix (see: help)"; exit 1 ;; esac
    case "${1:-}" in delete|uninstall) [ "$NI_YES" = 1 ] || { err "$1 without a terminal needs --yes"; exit 1; } ;; esac
  fi
  [ "$(id -u)" -eq 0 ] || { err "Run as root."; exit 1; }
  if [ ! -x "$BIN" ]; then
    if [ "$SANDBOX" = 1 ]; then
      [ "${1:-}" = update ] || { err "Sandbox $WAT_PREFIX: no wattun binary at $BIN yet. Install it with: $SELF update"; exit 1; }
    else err "wattun is not installed. Run install.sh first."; exit 1; fi
  fi
  case "${1:-}" in heal|auto-watch|auto-retest) ;; *)
    [ "$SANDBOX" = 1 ] && hint "Sandbox $WAT_PREFIX: configs $CONF, binary $BIN, units ${WAT_PREFIX}@NAME, runtime $RUN (production wattun is not touched)." ;;
  esac
  mkdir -p "$CONF" "$RUN"; chmod 700 "$CONF"
  trap on_int INT
  trap cleanup EXIT
  trap 'cleanup; exit 143' TERM HUP
  case "${1:-}" in
    "") main_menu ;;
    new) new_tunnel "${2:-}" ;;
    kharej) if [ "$NONINTERACTIVE" = 1 ]; then ni_run wizard_kharej; else run_flow wizard_kharej; fi ;;
    iran) if [ "$NONINTERACTIVE" = 1 ]; then ni_run wizard_iran; else run_flow wizard_iran; fi ;;
    delete) need_tunnel "${NI_POS[0]:?name}" && if [ "$NONINTERACTIVE" = 1 ]; then ni_run delete_tunnel "${NI_POS[0]}"; else run_flow delete_tunnel "${NI_POS[0]}"; fi ;;
    uninstall) if [ "$NONINTERACTIVE" = 1 ]; then ni_run uninstall_all; else run_flow uninstall_all; fi ;;
    status|list) status_all ;;
    start-all) start_all ;;
    stop-all) stop_all ;;
    restart-all) restart_all ;;
    status-all) status_all ;;
    backup) shift; backup_cmd "$@" ;;
    restore) shift; restore_cmd "$@" ;;
    boost) shift; boost_cmd "$@" ;;
    auto-optimize) auto_optimize_all ;;
    monitor) live_monitor ;;
    ports) need_tunnel "${2:?name}" && run_flow edit_ports "$2" ;;
    test) need_tunnel "${2:?name}" && test_tunnel "$2" ;;
    speedtest) need_tunnel "${2:?name}" && speed_test "$2" "${3:-10}" ;;
    logs) need_tunnel "${2:?name}" && journalctl -u "${WAT_PREFIX}@$2" -f -o short-iso ;;
    token) need_tunnel "${2:?name}" && show_token "$2" ;;
    preset) need_tunnel "${NI_POS[0]:-${2:-}}" && ni_run preset_cmd "${NI_POS[0]:-${2:-}}" "${NI_POS[1]:-${3:-}}" ;;
    test-anticensor|test-bypass) need_tunnel "${NI_POS[0]:-${2:-}}" && ni_run anticensor_test "${NI_POS[0]:-${2:-}}" ;;
    profile) shift; profile_cmd "$@" ;;
    blackout) need_tunnel "${NI_POS[0]:-${2:-}}" && ni_run blackout_cmd "${NI_POS[0]:-${2:-}}" "${NI_POS[1]:-${3:-}}" ;;
    arm-blackout) need_tunnel "${NI_POS[0]:-${2:-}}" && ni_run arm_blackout_cmd "${NI_POS[0]:-${2:-}}" ;;
    audit-blackout) need_tunnel "${NI_POS[0]:-${2:-}}" && ni_run audit_blackout_cmd "${NI_POS[0]:-${2:-}}" ;;
    matrix|anti-censor-matrix) need_tunnel "${NI_POS[0]:-${2:-}}" && ni_run ac_matrix_cmd "${NI_POS[0]:-${2:-}}" ;;
    heal) heal ;;
    auto-test) need_tunnel "${NI_POS[0]:?name}" && ni_run auto_test_cmd "${NI_POS[0]}" ;;
    auto-ip) need_tunnel "${2:?name}" && auto_ip "$2" "${3:-}" ;;
    auto-watch) need_tunnel "${2:?name}" && auto_watch "$2" ;;
    auto-retest) need_tunnel "${2:?name}" && auto_retest "$2" ;;
    cdn-tune) need_tunnel "${NI_POS[0]:?name}" && ni_run cdn_tune_cmd "${NI_POS[0]}" "${NI_POS[1]:-}" ;;
    update) shift; update "$@" ;;
    rollback) rollback ;;
    *) usage; exit 1 ;;
  esac
}

if [ "$LIB" != 1 ]; then main "$@"; fi
