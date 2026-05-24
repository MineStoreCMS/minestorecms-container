# shellcheck shell=bash
# UI library for docker-installer.sh and minestore CLI.
# Sourced (not executed). Idempotent.

if [ -n "${MINESTORE_UI_SH_LOADED:-}" ]; then return 0; fi
MINESTORE_UI_SH_LOADED=1

# Detect color support.
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && command -v tput >/dev/null 2>&1; then
    NCOLORS=$(tput colors 2>/dev/null || echo 0)
    if [ "$NCOLORS" -ge 8 ]; then
        UI_COLOR=1
    fi
fi
UI_COLOR="${UI_COLOR:-0}"

if [ "$UI_COLOR" = "1" ]; then
    C_NC=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_PRIMARY=$'\033[38;5;208m'      # orange
    C_SUCCESS=$'\033[38;5;46m'       # green
    C_INFO=$'\033[38;5;39m'          # cyan
    C_WARN=$'\033[38;5;220m'         # yellow
    C_ERROR=$'\033[38;5;196m'        # red
    C_MUTED=$'\033[38;5;245m'        # gray
    C_HIGHLIGHT=$'\033[38;5;213m'    # pink
    C_RECOMMENDED=$'\033[38;5;48m'   # green-aqua
else
    C_NC=""; C_BOLD=""; C_DIM=""
    C_PRIMARY=""; C_SUCCESS=""; C_INFO=""; C_WARN=""; C_ERROR=""
    C_MUTED=""; C_HIGHLIGHT=""; C_RECOMMENDED=""
fi

# Icons (Unicode + ASCII fallback)
if [ "$UI_COLOR" = "1" ] && locale charmap 2>/dev/null | grep -qi utf; then
    UI_OK="✓"; UI_FAIL="✗"; UI_INFO="ℹ"; UI_WARN="⚠"; UI_ARROW="❯"; UI_BULLET="•"
else
    UI_OK="[OK]"; UI_FAIL="[X]"; UI_INFO="[i]"; UI_WARN="[!]"; UI_ARROW=">"; UI_BULLET="*"
fi

ui::banner() {
    echo "${C_PRIMARY}"
    cat <<'BANNER'
   __  __ _             _____ _                  _____ __  __  _____
  |  \/  (_)           / ____| |                / ____|  \/  |/ ____|
  | \  / |_ _ __   ___| (___ | |_ ___  _ __ ___| |    | \  / | (___
  | |\/| | | '_ \ / _ \\___ \| __/ _ \| '__/ _ \ |    | |\/| |\___ \
  | |  | | | | | |  __/____) | || (_) | | |  __/ |____| |  | |____) |
  |_|  |_|_|_| |_|\___|_____/ \__\___/|_|  \___|\_____|_|  |_|_____/
BANNER
    echo "${C_NC}"
    echo "       ${C_BOLD}MineStoreCMS Docker Installer${C_NC}  v1.0"
    echo ""
}

ui::line() { echo "${C_MUTED}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"; }
ui::nl()   { echo ""; }

ui::section() { ui::line; echo "  ${C_BOLD}${C_PRIMARY}${UI_ARROW}${C_NC}  ${C_BOLD}$*${C_NC}"; ui::line; }
ui::step()    { echo "  ${C_BOLD}${C_PRIMARY}${UI_ARROW}${C_NC}  ${C_BOLD}Step $1 of $2${C_NC}  ${C_MUTED}·${C_NC}  $3"; }

ui::ok()    { echo "  ${C_SUCCESS}${UI_OK}${C_NC}  $*"; }
ui::fail()  { echo "  ${C_ERROR}${UI_FAIL}${C_NC}  $*" >&2; }
ui::info()  { echo "  ${C_INFO}${UI_INFO}${C_NC}  $*"; }
ui::warn()  { echo "  ${C_WARN}${UI_WARN}${C_NC}  $*"; }
ui::bullet() { echo "       ${C_MUTED}${UI_BULLET}${C_NC} $*"; }

# ui::input <prompt> [default]
ui::input() {
    local prompt="$1" default="${2:-}" val=""
    if [ -n "$default" ]; then
        read -r -p "     $prompt [${C_DIM}$default${C_NC}]: " val
        echo "${val:-$default}"
    else
        while [ -z "$val" ]; do
            read -r -p "     $prompt: " val
        done
        echo "$val"
    fi
}

# ui::confirm <prompt>  → returns 0 yes, 1 no
ui::confirm() {
    local ans=""
    read -r -p "     $1 (${C_BOLD}Y${C_NC}/n): " ans
    case "${ans,,}" in
        ""|y|yes) return 0 ;;
        *)        return 1 ;;
    esac
}

# ui::select <prompt> <default-idx> <opt1> <opt2> ...
# Each opt may include "(Recommended ...)" suffix.
ui::select() {
    local prompt="$1" default="$2"; shift 2
    local i=1
    echo "     $prompt"
    echo ""
    for opt in "$@"; do
        local label="$opt"
        if echo "$label" | grep -q "(Recommended"; then
            echo "       ${C_RECOMMENDED}${i})${C_NC}  ${C_BOLD}$label${C_NC}"
        else
            echo "       $i)  $label"
        fi
        i=$((i+1))
    done
    echo ""
    local choice=""
    read -r -p "     Choice [${default}]: " choice
    choice="${choice:-$default}"
    echo "$choice"
}

# ui::spinner_start <message>  ;  ui::spinner_stop <ok|fail>
_UI_SPIN_PID=""
ui::spinner_start() {
    local msg="$1"
    if [ "$UI_COLOR" != "1" ]; then echo "       $msg ..."; return; fi
    ( while :; do for f in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏; do
        printf "\r       ${C_INFO}%s${C_NC} %s" "$f" "$msg"; sleep 0.1
      done; done ) &
    _UI_SPIN_PID=$!
    disown
}
ui::spinner_stop() {
    if [ -n "${_UI_SPIN_PID:-}" ]; then
        kill "$_UI_SPIN_PID" 2>/dev/null || true
        wait "$_UI_SPIN_PID" 2>/dev/null || true
        _UI_SPIN_PID=""
        printf "\r       "
    fi
    case "${1:-ok}" in
        ok)   echo "${C_SUCCESS}${UI_OK}${C_NC} done." ;;
        fail) echo "${C_ERROR}${UI_FAIL}${C_NC} failed." ;;
    esac
}

ui::trap_ctrl_c() {
    trap 'echo ""; ui::fail "Interrupted."; ui::spinner_stop fail 2>/dev/null; exit 130' INT
}
