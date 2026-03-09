#!/usr/bin/env bash
set -Eeuo pipefail

# ===========================================================================
#  Print Tracker — Raspberry Pi Deploy Script (TUI Wizard)
# ===========================================================================

SERVICE_NAME="print-tracker"
SERVICE_USER="${SUDO_USER:-${USER}}"
SERVICE_GROUP="$(id -gn "${SERVICE_USER}" 2>/dev/null || echo "${SERVICE_USER}")"
REPO_URL="https://github.com/ColinRNickels/printtracker.git"
DEPLOY_DIR=""
PORT="5000"
PRINT_MODE="cups"
PRINTER_QUEUE="QL800"
LABEL_MEDIA="DK-1202"
STAFF_PASSWORD=""
SITE_ID=""
LOCATION_NAME="Makerspace"
LOGO_SOURCE=""
NON_INTERACTIVE=0
SKIP_APT=0
SKIP_SERVICE=0
SKIP_CUPS=0
SKIP_DB_INIT=0
SETUP_GOOGLE_OAUTH=-1
GOOGLE_CLIENT_SECRETS=""
GOOGLE_GMAIL_SENDER="library_makerspace@ncsu.edu"
GOOGLE_SPREADSHEET_ID=""
GOOGLE_WORKSHEET="PrintJobs"
SETUP_TUNNEL=-1
SETUP_GOLINK=-1
GO_NCSU_API_TOKEN=""
GO_NCSU_LINK_SLUG=""

# ── Colours & symbols ─────────────────────────────────────────────────────
# Gracefully degrade to plain text if terminal doesn't support colours.
if [[ -t 1 ]] && tput colors &>/dev/null && [[ "$(tput colors)" -ge 8 ]]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_RED="\033[1;31m"
  C_GREEN="\033[1;32m"
  C_YELLOW="\033[1;33m"
  C_CYAN="\033[1;36m"
  C_WHITE="\033[1;37m"
  SYM_CHECK="✔"
  SYM_CROSS="✘"
  SYM_ARROW="▸"
  SYM_BULLET="•"
  SYM_WARN="⚠"
  SYM_GEAR="⚙"
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
  C_WHITE=""
  SYM_CHECK="[OK]" SYM_CROSS="[X]" SYM_ARROW=">" SYM_BULLET="*"
  SYM_WARN="[!]" SYM_GEAR="[*]"
fi

TOTAL_STEPS=8   # may be adjusted when Google / Tunnel are decided
CURRENT_STEP=0

# ── TUI drawing helpers ───────────────────────────────────────────────────

tui_cols() {
  tput cols 2>/dev/null || echo 72
}

tui_rule() {
  local char="${1:-─}"
  printf '%b' "${C_DIM}"
  printf '%*s' "$(tui_cols)" "" | tr ' ' "${char}"
  printf '%b\n' "${C_RESET}"
}

tui_banner() {
  local text="$1"
  printf '\n'
  tui_rule '═'
  printf '%b  %s%b\n' "${C_BOLD}${C_CYAN}" "${text}" "${C_RESET}"
  tui_rule '═'
}

tui_step_header() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local title="$1"
  printf '\n'
  tui_rule '─'
  printf '  %b Step %d of %d %b │ %b%s%b\n' \
    "${C_BOLD}${C_CYAN}" "${CURRENT_STEP}" "${TOTAL_STEPS}" \
    "${C_DIM}" "${C_BOLD}${C_WHITE}" "${title}" "${C_RESET}"
  tui_rule '─'
}

tui_explain() {
  # Print grey explanation text, preserving indentation.
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '  %b%s%b\n' "${C_DIM}" "${line}" "${C_RESET}"
  done <<< "$1"
}

tui_hint() {
  printf '  %b%s %s%b\n' "${C_YELLOW}" "${SYM_BULLET}" "$1" "${C_RESET}"
}

tui_success() {
  printf '  %b%s %s%b\n' "${C_GREEN}" "${SYM_CHECK}" "$1" "${C_RESET}"
}

tui_fail() {
  printf '  %b%s %s%b\n' "${C_RED}" "${SYM_CROSS}" "$1" "${C_RESET}"
}

tui_warn() {
  printf '  %b%s %s%b\n' "${C_YELLOW}" "${SYM_WARN}" "$1" "${C_RESET}"
}

tui_progress() {
  printf '  %b%s %s ...%b\n' "${C_CYAN}" "${SYM_GEAR}" "$1" "${C_RESET}"
}

tui_field() {
  local label="$1" value="$2"
  printf '  %b%-24s%b %s\n' "${C_DIM}" "${label}:" "${C_RESET}" "${value}"
}

tui_prompt() {
  local label="$1" default="$2"
  if [[ -n "${default}" ]]; then
    printf '\n  %b%s%b %b[%s]%b: ' \
      "${C_BOLD}" "${label}" "${C_RESET}" "${C_CYAN}" "${default}" "${C_RESET}" >/dev/tty
  else
    printf '\n  %b%s%b: ' \
      "${C_BOLD}" "${label}" "${C_RESET}" >/dev/tty
  fi
}

# ── Core helpers ──────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy_rpi.sh [options]

Automates Raspberry Pi deployment for Print Tracker.
Run from the project root after cloning the repository.

Options:
  --non-interactive        Use defaults and skip prompts.
  --service-user USER      Linux user that runs the app service.
  --service-group GROUP    Linux group that runs the app service.
  --port PORT              App port (default: 5000).
  --print-mode MODE        "cups" or "mock" (default: cups).
  --repo-dir PATH          Where to clone/update the repo (default: ~/PrintTracker).
  --printer-queue NAME     CUPS queue name (default: QL800).
  --media NAME             CUPS media token (default: DK-1202).
  --staff-password PASS    Staff dashboard password (required).
  --setup-google-oauth     Run Google OAuth setup during deploy.
  --no-google-oauth        Skip Google OAuth setup during deploy.
  --google-client-secrets PATH
                           Path to OAuth client JSON from Google Cloud.
  --google-gmail-sender EMAIL
                           Sender email for Gmail API (optional).
  --google-spreadsheet-id ID|URL
                           Spreadsheet ID or full Google Sheets URL (optional).
  --google-worksheet NAME  Worksheet tab name (default: PrintJobs).
  --setup-tunnel           Set up a Cloudflare quick tunnel (free, no domain needed).
  --no-tunnel              Skip Cloudflare Tunnel setup.
  --setup-golink           Create a go.ncsu.edu short link during deploy.
  --no-golink              Skip go.ncsu.edu short link setup.
  --go-ncsu-api-token TOKEN
                           API token for go.ncsu.edu.
  --go-ncsu-link-slug SLUG Short-link slug (e.g. makerspace-print).
  --site-id ID             Short site prefix for Print IDs (e.g. HL, PT).
  --location-name NAME     Human-readable location name (e.g. "Hill Library").
  --logo-source PATH       Optional local PNG path for label logo.
  --skip-apt               Skip apt package install/update.
  --skip-cups              Skip CUPS service setup and printer checks.
  --skip-service           Skip systemd service setup.
  --skip-db-init           Skip database initialization.
  -h, --help               Show this help.
EOF
}

log()  { printf '\n%b[deploy]%b %s\n' "${C_DIM}" "${C_RESET}" "$*"; }
warn() { printf '\n%b[deploy] WARNING:%b %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()  { printf '\n%b[deploy] ERROR:%b %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

prompt_default() {
  local prompt="$1" default="$2" input=""
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    printf '%s' "${default}"
    return 0
  fi
  tui_prompt "${prompt}" "${default}"
  read -r input </dev/tty
  printf '%s' "${input:-${default}}"
}

prompt_choice() {
  # Display a numbered menu and return the chosen value.
  # Usage: result="$(prompt_choice "label" default_value option1 option2 ...)"
  local label="$1" default="$2"; shift 2
  local options=("$@")
  local default_num=1
  local i

  for i in "${!options[@]}"; do
    if [[ "${options[$i]}" == "${default}" ]]; then
      default_num=$((i + 1))
      break
    fi
  done

  for i in "${!options[@]}"; do
    local marker="  "
    [[ $((i + 1)) -eq ${default_num} ]] && marker="${C_CYAN}>${C_RESET} "
    printf '    %b%b%d)%b  %s\n' "${marker}" "${C_BOLD}" "$((i + 1))" "${C_RESET}" "${options[$i]}" >/dev/tty
  done

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    printf '%s' "${default}"
    return 0
  fi

  local input
  while true; do
    printf '\n  %b%s%b %b[%d]%b: ' \
      "${C_BOLD}" "${label}" "${C_RESET}" "${C_CYAN}" "${default_num}" "${C_RESET}" >/dev/tty
    read -r input </dev/tty
    [[ -z "${input}" ]] && input="${default_num}"
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#options[@]} )); then
      printf '%s' "${options[$((input - 1))]}"
      return 0
    fi
    printf '  %b%s Please enter a number between 1 and %d.%b\n' \
      "${C_YELLOW}" "${SYM_WARN}" "${#options[@]}" "${C_RESET}" >/dev/tty
  done
}

prompt_yes_no() {
  local prompt="$1" default="${2:-y}" input="" hint="y/N"
  [[ "${default}" =~ ^([Yy]|[Yy]es)$ ]] && hint="Y/n"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    [[ "${default}" =~ ^([Yy]|[Yy]es)$ ]]; return
  fi
  while true; do
    tui_prompt "${prompt}" "${hint}"
    read -r input
    [[ -z "${input}" ]] && input="${default}"
    case "${input}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
      *) tui_warn "Please enter y or n." ;;
    esac
  done
}

prompt_password() {
  local pw="" pw2=""
  while true; do
    printf '\n  %b%s%b: ' "${C_BOLD}" "Choose a password" "${C_RESET}"
    read -r -s pw; printf '\n'
    if [[ -z "${pw}" ]]; then
      tui_warn "Password cannot be empty."
      continue
    fi
    printf '  %b%s%b: ' "${C_BOLD}" "Confirm password " "${C_RESET}"
    read -r -s pw2; printf '\n'
    if [[ "${pw}" != "${pw2}" ]]; then
      tui_warn "Passwords do not match. Let's try again."
      continue
    fi
    STAFF_PASSWORD="${pw}"
    tui_success "Password set."
    return
  done
}

set_env_value() {
  local env_file="$1" key="$2" value="$3"
  python3 - "${env_file}" "${key}" "${value}" <<'PY'
from pathlib import Path; import sys
env_path, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = env_path.read_text().splitlines() if env_path.exists() else []
needle = f"{key}="
updated, found = [], False
for line in lines:
    if line.startswith(needle):
        updated.append(f"{key}={value}"); found = True
    else:
        updated.append(line)
if not found:
    updated.append(f"{key}={value}")
env_path.write_text("\n".join(updated).rstrip() + "\n")
PY
}

get_env_value() {
  local env_file="$1" key="$2"
  python3 - "${env_file}" "${key}" <<'PY'
from pathlib import Path; import sys
env_path, key = Path(sys.argv[1]), sys.argv[2]
needle = f"{key}="
if not env_path.exists(): sys.exit(0)
for line in env_path.read_text().splitlines():
    if line.startswith(needle): print(line[len(needle):]); break
PY
}

run_google_oauth_setup() {
  local env_file="$1" app_dir="$2" venv_python="$3" client_secrets="$4"
  local sender="$5" spreadsheet_id="$6" worksheet="$7"
  local output_file=""
  output_file="$(mktemp)"

  local -a oauth_cmd=(
    "${venv_python}"
    "${app_dir}/scripts/google_oauth_bootstrap.py"
    --client-secrets "${client_secrets}"
  )
  [[ -n "${sender}" ]] && oauth_cmd+=(--gmail-sender "${sender}")

  tui_progress "Starting Google OAuth flow (a browser window may open)"
  (cd "${app_dir}" && "${oauth_cmd[@]}") > >(tee "${output_file}") 2>&1

  while IFS= read -r line; do
    [[ "${line}" == *=* ]] || continue
    local key="${line%%=*}" value="${line#*=}"
    [[ "${key}" =~ ^[A-Z0-9_]+$ ]] || continue
    [[ "${value}" == *"<your-spreadsheet-id>"* ]] && continue
    set_env_value "${env_file}" "${key}" "${value}"
  done < "${output_file}"
  rm -f "${output_file}"

  set_env_value "${env_file}" "EMAIL_PROVIDER" "gmail_api"
  if [[ -n "${spreadsheet_id}" ]]; then
    set_env_value "${env_file}" "GOOGLE_SHEETS_SPREADSHEET_ID" "${spreadsheet_id}"
    set_env_value "${env_file}" "GOOGLE_SHEETS_SYNC_ENABLED" "true"
  else
    local existing_sheet_id=""
    existing_sheet_id="$(get_env_value "${env_file}" "GOOGLE_SHEETS_SPREADSHEET_ID")"
    if [[ -n "${existing_sheet_id}" ]]; then
      set_env_value "${env_file}" "GOOGLE_SHEETS_SYNC_ENABLED" "true"
    else
      set_env_value "${env_file}" "GOOGLE_SHEETS_SYNC_ENABLED" "false"
      tui_warn "No Spreadsheet ID yet — Sheets sync stays disabled until you set one."
    fi
  fi
  [[ -n "${worksheet}" ]] && set_env_value "${env_file}" "GOOGLE_SHEETS_WORKSHEET" "${worksheet}"
}

# ── CLI flag parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)       NON_INTERACTIVE=1;               shift ;;
    --service-user)          SERVICE_USER="$2";               shift 2 ;;
    --service-group)         SERVICE_GROUP="$2";              shift 2 ;;
    --port)                  PORT="$2";                       shift 2 ;;
    --print-mode)            PRINT_MODE="$2";                 shift 2 ;;
    --repo-dir)              DEPLOY_DIR="$2";                 shift 2 ;;
    --printer-queue)         PRINTER_QUEUE="$2";              shift 2 ;;
    --media)                 LABEL_MEDIA="$2";                shift 2 ;;
    --staff-password)        STAFF_PASSWORD="$2";             shift 2 ;;
    --setup-google-oauth)    SETUP_GOOGLE_OAUTH=1;            shift ;;
    --no-google-oauth)       SETUP_GOOGLE_OAUTH=0;            shift ;;
    --google-client-secrets) GOOGLE_CLIENT_SECRETS="$2";      shift 2 ;;
    --google-gmail-sender)   GOOGLE_GMAIL_SENDER="$2";        shift 2 ;;
    --google-spreadsheet-id) GOOGLE_SPREADSHEET_ID="$2";      shift 2 ;;
    --google-worksheet)      GOOGLE_WORKSHEET="$2";           shift 2 ;;
    --setup-tunnel)          SETUP_TUNNEL=1;                  shift ;;
    --no-tunnel)             SETUP_TUNNEL=0;                  shift ;;
    --setup-golink)          SETUP_GOLINK=1;                  shift ;;
    --no-golink)             SETUP_GOLINK=0;                  shift ;;
    --go-ncsu-api-token)     GO_NCSU_API_TOKEN="$2";          shift 2 ;;
    --go-ncsu-link-slug)     GO_NCSU_LINK_SLUG="$2";          shift 2 ;;
    --site-id)               SITE_ID="$2";                    shift 2 ;;
    --location-name)         LOCATION_NAME="$2";              shift 2 ;;
    --logo-source)           LOGO_SOURCE="$2";                shift 2 ;;
    --skip-apt)              SKIP_APT=1;                      shift ;;
    --skip-cups)             SKIP_CUPS=1;                     shift ;;
    --skip-service)          SKIP_SERVICE=1;                  shift ;;
    --skip-db-init)          SKIP_DB_INIT=1;                  shift ;;
    -h|--help)               usage; exit 0 ;;
    *)                       die "Unknown option: $1" ;;
  esac
done

# Extract spreadsheet ID from a full URL if one was passed via CLI flag.
if [[ "${GOOGLE_SPREADSHEET_ID}" == *"docs.google.com/spreadsheets"* ]]; then
  GOOGLE_SPREADSHEET_ID="$(printf '%s' "${GOOGLE_SPREADSHEET_ID}" | sed -n 's|.*spreadsheets/d/\([^/]*\).*|\1|p')"
fi

# ── Clone or update the repository ────────────────────────────────────────
if [[ -z "${DEPLOY_DIR}" ]]; then
  SERVICE_HOME="$(getent passwd "${SERVICE_USER}" 2>/dev/null | cut -d: -f6 || echo "${HOME}")"
  DEPLOY_DIR="${SERVICE_HOME}/PrintTracker"
fi

if [[ -d "${DEPLOY_DIR}/.git" ]]; then
  log "Updating existing repo at ${DEPLOY_DIR}..."
  git -C "${DEPLOY_DIR}" fetch --all
  git -C "${DEPLOY_DIR}" reset --hard origin/main
else
  log "Cloning ${REPO_URL} into ${DEPLOY_DIR}..."
  git clone "${REPO_URL}" "${DEPLOY_DIR}"
fi

PROJECT_DIR="${DEPLOY_DIR}"
[[ -f "${PROJECT_DIR}/requirements.txt" ]] || die "Repository clone failed or requirements.txt is missing."
# Validate print-mode early when running non-interactively (the wizard
# guarantees a valid value via numbered menu when interactive).
if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
  [[ "${PRINT_MODE}" == "cups" || "${PRINT_MODE}" == "mock" ]] || die "Print mode must be 'cups' or 'mock'."
fi

# ╔═══════════════════════════════════════════════════════════════════════╗
# ║                       INTERACTIVE WIZARD                              ║
# ╚═══════════════════════════════════════════════════════════════════════╝

if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
  clear 2>/dev/null || true
  printf '\n'
  printf '%b' "${C_RED}"
  cat <<'LOGO'
   ____       _       _     _____               _
  |  _ \ _ __(_)_ __ | |_  |_   _| __ __ _  ___| | _____ _ __
  | |_) | '__| | '_ \| __|   | || '__/ _` |/ __| |/ / _ \ '__|
  |  __/| |  | | | | | |_    | || | | (_| | (__|   <  __/ |
  |_|   |_|  |_|_| |_|\__|   |_||_|  \__,_|\___|_|\_\___|_|
LOGO
  printf '%b\n' "${C_RESET}"
  printf '  %bRaspberry Pi Deployment Wizard%b\n' "${C_BOLD}" "${C_RESET}"
  printf '\n'
  tui_explain "This wizard will walk you through every setting, one step at a time."
  tui_explain "Each prompt shows a default in [brackets] — just press Enter to keep it."
  tui_explain "You can change any setting later by editing the .env file."
  printf '\n'
  tui_rule '─'
  printf '\n  Press %bEnter%b to begin...' "${C_BOLD}" "${C_RESET}"
  read -r

  # ╭───────────────────────────────────────────────────────────────────────╮
  # │  Step 1 — Staff Password                                             │
  # ╰───────────────────────────────────────────────────────────────────────╯
  tui_step_header "Staff Dashboard Password"

  tui_explain "The staff dashboard is a protected area where authorised staff can:"
  printf '\n'
  tui_hint "View and manage all print jobs"
  tui_hint "Mark jobs as complete or failed (triggers email to user)"
  tui_hint "Access usage reports and change app settings"
  printf '\n'
  tui_explain "Choose a password that your team can remember."
  tui_explain "Don't use something trivially guessable like 'password' or '1234'."

  if [[ -z "${STAFF_PASSWORD}" ]]; then
    prompt_password
  else
    tui_success "Password was provided via command-line flag."
  fi

  # ╭───────────────────────────────────────────────────────────────────────╮
  # │  Step 2 — Linux Service & Network                                     │
  # ╰───────────────────────────────────────────────────────────────────────╯
  tui_step_header "Linux Service & Network"

  tui_explain "The app runs as a background 'service' on this Raspberry Pi — it starts"
  tui_explain "automatically on boot and restarts if it crashes."
  printf '\n'
  tui_explain "These three settings control the service. If you're not sure what to"
  tui_explain "put, just press Enter for each one — the defaults work for almost"
  tui_explain "every Raspberry Pi setup."

  printf '\n'
  tui_hint "Service user — which Linux account runs the app."
  tui_hint "Tip: to confirm your username, run:  whoami"
  SERVICE_USER="$(prompt_default "Service user" "${SERVICE_USER}")"
  printf '\n'

  tui_hint "Service group — usually the same as the username."
  SERVICE_GROUP="$(prompt_default "Service group" "${SERVICE_GROUP}")"
  printf '\n'

  tui_hint "Port — the number in the URL after the colon, like :5000"
  tui_hint "Only change this if port 5000 is already in use."
  PORT="$(prompt_default "Web app port" "${PORT}")"
  printf '\n'

  tui_success "Service will run as ${SERVICE_USER}:${SERVICE_GROUP} on port ${PORT}"

  # ╭───────────────────────────────────────────────────────────────────────╮
  # │  Step 3 — Label Printer                                               │
  # ╰───────────────────────────────────────────────────────────────────────╯
  tui_step_header "Label Printer"

  tui_explain "Print Tracker prints an adhesive label for every submitted job."
  tui_explain "The label includes a QR code that staff scan to mark the job complete."

  printf '\n'
  tui_hint "Print mode — how labels are handled:"
  printf '\n'
  tui_explain "    cups — Send labels to a real Brother QL printer via USB."
  tui_explain "           Choose this for a production station."
  printf '\n'
  tui_explain "    mock — Don't print anything. Labels are saved as images in"
  tui_explain "           the labels/ folder. Good for testing without a printer."
  printf '\n'
  PRINT_MODE="$(prompt_choice "Print mode" "${PRINT_MODE}" "cups" "mock")"
  printf '\n'

  if [[ "${PRINT_MODE}" == "cups" ]]; then
    tui_hint "CUPS queue name — the name of your printer in the Linux print system."
    tui_explain "  If you've already set up the printer, you can see its name by running:"
    tui_explain "    lpstat -e"
    tui_explain "  The default 'QL800' matches a standard Brother QL-800."
    PRINTER_QUEUE="$(prompt_default "CUPS queue name" "${PRINTER_QUEUE}")"
    printf '\n'

    tui_hint "Media token — tells the printer what size labels are loaded."
    tui_explain "  DK-1202 = standard 62 mm × 100 mm Brother address labels."
    tui_explain "  Only change this if you're using a different label stock."
    LABEL_MEDIA="$(prompt_default "CUPS media token" "${LABEL_MEDIA}")"
    printf '\n'
  fi

  tui_success "Print mode: ${PRINT_MODE}"

  # ╭───────────────────────────────────────────────────────────────────────╮
  # │  Step 4 — Location & Site Identity                                    │
  # ╰───────────────────────────────────────────────────────────────────────╯
  tui_step_header "Location & Site Identity"

  tui_explain "If you have multiple Raspberry Pis running Print Tracker at different"
  tui_explain "locations, each one should have a unique name so you can tell jobs"
  tui_explain "apart in the shared Google Sheet and on printed labels."
  printf '\n'
  tui_explain "If this is your only Pi, the defaults are fine."

  printf '\n'
  tui_hint "Location name — a friendly name for this printer station."
  tui_hint "Examples: \"Hill Library\", \"Hunt Library\", \"Makerspace\""
  LOCATION_NAME="$(prompt_default "Location name" "${LOCATION_NAME}")"
  printf '\n'

  tui_hint "Site ID — a short 2–4 letter code added to every Print ID."
  tui_explain "  This ensures IDs are unique across locations. Examples:"
  tui_explain "    HL = Hill Library   →  IDs look like HL-20260305-120000-00"
  tui_explain "    HU = Hunt Library   →  IDs look like HU-20260305-120000-00"
  tui_explain "    PT = default        →  IDs look like PT-20260305-120000-00"
  SITE_ID="$(prompt_default "Site ID" "${SITE_ID:-PT}")"
  printf '\n'

  tui_success "Location: ${LOCATION_NAME}  |  Print IDs will start with ${SITE_ID}-"

  # ╭───────────────────────────────────────────────────────────────────────╮
  # │  Step 5 — Cloudflare Tunnel                                          │
  # ╰───────────────────────────────────────────────────────────────────────╯
  tui_step_header "Internet Access (Cloudflare Tunnel)"

  tui_explain "Right now the app is reachable only on the local network at:"
  tui_explain "  http://<this Pi's IP address>:${PORT}"
  printf '\n'
  tui_explain "A Cloudflare tunnel makes it accessible from the public internet"
  tui_explain "using a URL like https://random-words.trycloudflare.com"
  printf '\n'
  tui_explain "How it works:"
  tui_hint "Free — no Cloudflare account or domain name required."
  tui_hint "No router or firewall changes needed."
  tui_hint "The URL changes when the tunnel restarts, but the app can update it."
  printf '\n'
  tui_explain "When to say YES:  staff or users need to access the app from"
  tui_explain "                  campus Wi-Fi, remotely, or outside your LAN."
  tui_explain "When to say NO:   the Pi and all users are on the same network."
  printf '\n'
  tui_hint "You can set this up later by re-running the deploy script."

  if [[ "${SETUP_TUNNEL}" -lt 0 ]]; then
    if prompt_yes_no "Set up a Cloudflare quick tunnel" "y"; then
      SETUP_TUNNEL=1
      printf '\n'
      tui_success "Tunnel will be configured during installation."
    else
      SETUP_TUNNEL=0
      printf '\n'
      tui_success "Skipping tunnel — local network access only."
    fi
  fi

  # ╭───────────────────────────────────────────────────────────────────────╮
  # │  Step 6 — go.ncsu.edu Short Link                                     │
  # ╰───────────────────────────────────────────────────────────────────────╯
  tui_step_header "go.ncsu.edu Short Link"

  tui_explain "Print Tracker can create a permanent short link at go.ncsu.edu"
  tui_explain "that redirects to your app. For example:"
  printf '\n'
  tui_explain "    go.ncsu.edu/makerspace-print  →  https://<your-tunnel-url>"
  printf '\n'
  tui_explain "This is useful for printed signs, label QR codes, or sharing"
  tui_explain "with users. The link stays the same even if the tunnel URL changes."
  printf '\n'
  tui_explain "You need a go.ncsu.edu API token to do this."
  printf '\n'
  tui_hint "How to get a token:"
  tui_explain "  1. Go to https://go.ncsu.edu/api/help"
  tui_explain "  2. Enter a token name (e.g. 'print-tracker')"
  tui_explain "  3. Click 'Create Token'"
  tui_explain "  4. Copy the token ID — you only see it once!"
  tui_explain "  5. Paste it here when prompted"
  printf '\n'
  tui_hint "If you don't have a token yet, say NO — you can set this up later."

  if [[ "${SETUP_GOLINK}" -lt 0 ]]; then
    if prompt_yes_no "Create a go.ncsu.edu short link" "y"; then
      SETUP_GOLINK=1
      printf '\n'

      # -- API token --
      tui_rule '·'
      if [[ -z "${GO_NCSU_API_TOKEN}" ]]; then
        tui_explain "  Paste your go.ncsu.edu API token."
        tui_explain "  (Get one at https://go.ncsu.edu/api/help)"
        GO_NCSU_API_TOKEN="$(prompt_default "go.ncsu.edu API token" "")"
        printf '\n'
      else
        tui_success "API token was provided via command-line flag."
      fi

      if [[ -z "${GO_NCSU_API_TOKEN}" ]]; then
        tui_warn "No token provided — skipping golink setup."
        SETUP_GOLINK=0
      else
        # -- Link slug --
        tui_rule '·'
        tui_explain "  Choose a short-link slug. This is the part after go.ncsu.edu/"
        tui_explain "  For example, entering 'makerspace-print' would create:"
        tui_explain "    go.ncsu.edu/makerspace-print"
        printf '\n'
        tui_explain "  Use lowercase letters, numbers, and hyphens."
        tui_explain "  If the name is already taken, you'll be able to try another."
        if [[ -z "${GO_NCSU_LINK_SLUG}" ]]; then
          GO_NCSU_LINK_SLUG="$(prompt_default "Short link slug" "makerspace-print-label")"
        else
          tui_success "Link slug provided via command-line flag: ${GO_NCSU_LINK_SLUG}"
        fi
        printf '\n'
        tui_success "GoLink will be created during installation."
      fi
    else
      SETUP_GOLINK=0
      printf '\n'
      tui_success "Skipping go.ncsu.edu short link."
    fi
  fi

  # ╭───────────────────────────────────────────────────────────────────────╮
  # │  Step 7 — Google Integration                                          │
  # ╰───────────────────────────────────────────────────────────────────────╯
  tui_step_header "Google Integration (Gmail & Sheets)"

  tui_explain "Print Tracker can connect to Google for two features:"
  printf '\n'
  tui_hint "Email notifications (Gmail API)"
  tui_explain "  When a print job is marked complete, the app emails the user to say"
  tui_explain "  their item is ready for pickup. Uses Gmail instead of a local mail"
  tui_explain "  server, so it works reliably from a Raspberry Pi."
  printf '\n'
  tui_hint "Google Sheets sync"
  tui_explain "  Every print job is automatically logged to a Google Spreadsheet."
  tui_explain "  Useful for shared record-keeping when multiple stations are running."
  printf '\n'
  tui_explain "Both features require an OAuth credential file from Google Cloud."
  tui_explain "Someone on your team should have set up a Google Cloud project and"
  tui_explain "downloaded a file called something like 'client_secret_XXXXX.json'."
  tui_explain "  → https://console.cloud.google.com/apis/credentials"
  printf '\n'
  tui_hint "If you have that file, say YES."
  tui_hint "If you don't have it yet, say NO — you can configure this later."

  if [[ "${SETUP_GOOGLE_OAUTH}" -lt 0 ]]; then
    if prompt_yes_no "Configure Google integration now" "y"; then
      SETUP_GOOGLE_OAUTH=1
      printf '\n'

      # -- Client secrets path --
      tui_rule '·'
      tui_explain "  Where is the OAuth client JSON file?"
      printf '\n'
      tui_explain "  How to find it:"
      tui_explain "    1. Go to https://console.cloud.google.com/apis/credentials"
      tui_explain "    2. Under 'OAuth 2.0 Client IDs', click the download icon"
      tui_explain "    3. Save the file (it's usually called 'client_secret_XXXXX.json')"
      printf '\n'
      tui_explain "  Enter the full path to the file, or press Enter if it's in"
      tui_explain "  the default location shown."
      GOOGLE_CLIENT_SECRETS="$(prompt_default "Path to client JSON" "${HOME}/Downloads/client_secret.json")"
      printf '\n'

      # -- Gmail sender --
      tui_rule '·'
      tui_explain "  Gmail sender address"
      printf '\n'
      tui_explain "  This is the 'From' address on notification emails. It must be a"
      tui_explain "  Gmail or Google Workspace address that the OAuth account has"
      tui_explain "  permission to send mail as."
      GOOGLE_GMAIL_SENDER="$(prompt_default "Gmail sender address" "${GOOGLE_GMAIL_SENDER}")"
      printf '\n'

      # -- Spreadsheet ID --
      tui_rule '·'
      tui_explain "  Google Spreadsheet"
      printf '\n'
      tui_explain "  You can paste either the full URL or just the ID."
      tui_explain "  To find it, open your Google Sheet and copy the URL from the"
      tui_explain "  browser address bar. It looks like this:"
      printf '\n'
      tui_explain "    https://docs.google.com/spreadsheets/d/AbC123xYz_long_id/edit"
      printf '\n'
      tui_explain "  If you don't have the spreadsheet yet, just press Enter."
      tui_explain "  You can add it later in the .env file."
      GOOGLE_SPREADSHEET_ID="$(prompt_default "Spreadsheet URL or ID" "${GOOGLE_SPREADSHEET_ID}")"
      # Extract the ID if a full URL was pasted
      if [[ "${GOOGLE_SPREADSHEET_ID}" == *"docs.google.com/spreadsheets"* ]]; then
        GOOGLE_SPREADSHEET_ID="$(printf '%s' "${GOOGLE_SPREADSHEET_ID}" | sed -n 's|.*spreadsheets/d/\([^/]*\).*|\1|p')"
        if [[ -n "${GOOGLE_SPREADSHEET_ID}" ]]; then
          tui_success "Extracted spreadsheet ID: ${GOOGLE_SPREADSHEET_ID}"
        else
          tui_warn "Could not parse a spreadsheet ID from that URL."
        fi
      fi
      printf '\n'

      # -- Worksheet tab --
      tui_rule '·'
      tui_explain "  Worksheet tab name"
      printf '\n'
      tui_explain "  The name of the tab (sheet) within the spreadsheet where jobs"
      tui_explain "  are logged. The default 'PrintJobs' is almost always correct."
      GOOGLE_WORKSHEET="$(prompt_default "Worksheet tab name" "${GOOGLE_WORKSHEET}")"
      printf '\n'

      tui_success "Google integration will be configured during installation."
    else
      SETUP_GOOGLE_OAUTH=0
      printf '\n'
      tui_success "Skipping Google integration for now."
    fi
  fi

  # ╭───────────────────────────────────────────────────────────────────────╮
  # │  Step 8 — Review                                                      │
  # ╰───────────────────────────────────────────────────────────────────────╯
  tui_step_header "Review Your Settings"

  tui_explain "Here's everything you chose. Take a moment to review."
  tui_explain "If something looks wrong, press Ctrl+C to cancel and start over."
  printf '\n'

  tui_field "Staff password" "******** (hidden)"
  tui_field "Service user" "${SERVICE_USER}"
  tui_field "Service group" "${SERVICE_GROUP}"
  tui_field "Web app port" "${PORT}"
  tui_field "Print mode" "${PRINT_MODE}"
  if [[ "${PRINT_MODE}" == "cups" ]]; then
    tui_field "CUPS queue" "${PRINTER_QUEUE}"
    tui_field "Label media" "${LABEL_MEDIA}"
  fi
  tui_field "Location name" "${LOCATION_NAME}"
  tui_field "Site ID prefix" "${SITE_ID}"
  if [[ "${SETUP_TUNNEL}" -eq 1 ]]; then
    tui_field "Cloudflare tunnel" "Yes"
  else
    tui_field "Cloudflare tunnel" "No"
  fi
  if [[ "${SETUP_GOLINK}" -eq 1 ]]; then
    tui_field "go.ncsu.edu link" "go.ncsu.edu/${GO_NCSU_LINK_SLUG}"
  else
    tui_field "go.ncsu.edu link" "No (can configure later)"
  fi
  if [[ "${SETUP_GOOGLE_OAUTH}" -eq 1 ]]; then
    tui_field "Google integration" "Yes"
    tui_field "  Gmail sender" "${GOOGLE_GMAIL_SENDER}"
    tui_field "  Spreadsheet ID" "${GOOGLE_SPREADSHEET_ID:-(not set yet)}"
    tui_field "  Worksheet tab" "${GOOGLE_WORKSHEET}"
  else
    tui_field "Google integration" "No (can configure later)"
  fi

  printf '\n'
  tui_rule '─'

  if ! prompt_yes_no "Everything look good? Begin installation" "y"; then
    printf '\n'
    die "Aborted by user. No changes were made to the system."
  fi
fi  # end interactive wizard

# ╔═══════════════════════════════════════════════════════════════════════╗
# ║                          VALIDATION                                   ║
# ╚═══════════════════════════════════════════════════════════════════════╝

[[ "${PRINT_MODE}" == "cups" || "${PRINT_MODE}" == "mock" ]] || die "Print mode must be 'cups' or 'mock'."
[[ "${PORT}" =~ ^[0-9]+$ ]] || die "Port must be a number."
[[ -n "${STAFF_PASSWORD}" ]] || die "Staff password is required. Use --staff-password or run in interactive mode."
[[ "${SETUP_GOOGLE_OAUTH}" -lt 0 ]] && SETUP_GOOGLE_OAUTH=0
if [[ "${SETUP_GOOGLE_OAUTH}" -eq 1 ]]; then
  [[ -n "${GOOGLE_CLIENT_SECRETS}" ]] || die "Google OAuth setup requested but --google-client-secrets path is missing."
  if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
    while [[ ! -f "${GOOGLE_CLIENT_SECRETS}" ]]; do
      tui_warn "File not found: ${GOOGLE_CLIENT_SECRETS}"
      if prompt_yes_no "Try a different path" "y"; then
        GOOGLE_CLIENT_SECRETS="$(prompt_default "Path to client JSON" "${HOME}/Downloads/client_secret.json")"
      else
        SETUP_GOOGLE_OAUTH=0
        tui_warn "Google integration skipped."
        break
      fi
    done
  fi
fi
if [[ "${SETUP_GOOGLE_OAUTH}" -eq 1 && ! -f "${GOOGLE_CLIENT_SECRETS}" ]]; then
  die "Google OAuth client secrets file not found: ${GOOGLE_CLIENT_SECRETS}"
fi

# ╔═══════════════════════════════════════════════════════════════════════╗
# ║                         INSTALLATION                                  ║
# ╚═══════════════════════════════════════════════════════════════════════╝

APP_DIR="${PROJECT_DIR}"
INSTANCE_DIR="${APP_DIR}/instance"
LABEL_DIR="${APP_DIR}/labels"
ASSETS_DIR="${APP_DIR}/assets"
LOGO_DEST="${ASSETS_DIR}/makerspace-logo.png"
ENV_FILE="${APP_DIR}/.env"
VENV_DIR="${APP_DIR}/.venv"
DEFAULT_LOGO_SOURCE="${APP_DIR}/print_tracker/static/ncsu-makerspace-logo-long-v2.png"

if [[ "${APP_DIR}" == *" "* ]]; then
  warn "Project directory contains spaces: ${APP_DIR}"
  [[ "${SKIP_SERVICE}" -eq 0 ]] && die "Use a path without spaces for systemd deploy."
fi

[[ -z "${LOGO_SOURCE}" && -f "${DEFAULT_LOGO_SOURCE}" ]] && LOGO_SOURCE="${DEFAULT_LOGO_SOURCE}"

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${HOST_IP}" ]] && HOST_IP="localhost"
KIOSK_BASE_URL="http://${HOST_IP}:${PORT}"

SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"

tui_banner "Installing Print Tracker"

# ── 1. System packages ────────────────────────────────────────────────────
if [[ "${SKIP_APT}" -eq 0 ]]; then
  tui_progress "Installing system packages (this can take a few minutes)"

  [[ -f /etc/apt/sources.list.d/cloudflared.list ]] && run_root rm -f /etc/apt/sources.list.d/cloudflared.list

  run_root apt-get update -qq
  APT_PACKAGES=(
    git
    python3-venv python3-pip python3-dev build-essential
    cups cups-client cups-bsd
    printer-driver-ptouch
    avahi-daemon
    usbutils
  )
  run_root apt-get install -y -qq "${APT_PACKAGES[@]}"
  tui_success "System packages installed."

  if ! command -v cloudflared >/dev/null 2>&1; then
    tui_progress "Installing cloudflared"
    cfd_deb="/tmp/cloudflared.deb"
    cfd_arch="amd64"
    case "$(dpkg --print-architecture)" in
      arm64|aarch64) cfd_arch="arm64" ;;
      armhf|armv7l)  cfd_arch="arm"   ;;
    esac
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfd_arch}.deb" \
      -o "${cfd_deb}"
    run_root dpkg -i "${cfd_deb}"
    rm -f "${cfd_deb}"
    tui_success "cloudflared installed."
  else
    tui_success "cloudflared already present: $(cloudflared --version 2>&1 | head -1)"
  fi
else
  tui_warn "Skipping apt packages (--skip-apt)."
fi

# ── 2. Linux user groups ──────────────────────────────────────────────────
if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  run_root usermod -aG lpadmin,lp "${SERVICE_USER}" || true
  tui_success "Added ${SERVICE_USER} to printer groups (lpadmin, lp)."
else
  tui_warn "User ${SERVICE_USER} not found; skipping group setup."
fi

# ── 3. Python virtual environment ─────────────────────────────────────────
tui_progress "Setting up Python environment"
VENV_OK=0
if [[ -x "${VENV_DIR}/bin/python" ]]; then
  if "${VENV_DIR}/bin/python" -c "import sys; print(sys.version_info[0])" >/dev/null 2>&1; then
    VENV_OK=1
  else
    tui_warn "Existing virtualenv looks broken — rebuilding."
  fi
fi

if [[ "${VENV_OK}" -eq 0 ]]; then
  if [[ -d "${VENV_DIR}" ]]; then
    if run_root systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
      run_root systemctl stop "${SERVICE_NAME}" || true
    fi
    rm -rf "${VENV_DIR}"
  fi
  python3 -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/python" -m pip install --upgrade pip -q
"${VENV_DIR}/bin/python" -m pip install -r "${APP_DIR}/requirements.txt" gunicorn -q
tui_success "Python packages installed."

# ── 4. App directories & logo ─────────────────────────────────────────────
mkdir -p "${INSTANCE_DIR}" "${LABEL_DIR}" "${ASSETS_DIR}"
if [[ -n "${LOGO_SOURCE}" && -f "${LOGO_SOURCE}" ]]; then
  cp "${LOGO_SOURCE}" "${LOGO_DEST}"
  tui_success "Logo copied to ${LOGO_DEST}"
fi

# ── 5. Write .env ─────────────────────────────────────────────────────────
tui_progress "Writing configuration (.env)"
if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${APP_DIR}/.env.example" "${ENV_FILE}" 2>/dev/null || touch "${ENV_FILE}"
fi

EXISTING_SECRET_KEY="$(get_env_value "${ENV_FILE}" "SECRET_KEY")"
if [[ -z "${EXISTING_SECRET_KEY}" || "${EXISTING_SECRET_KEY}" == "change-this" || "${EXISTING_SECRET_KEY}" == "change-me" ]]; then
  set_env_value "${ENV_FILE}" "SECRET_KEY" "${SECRET_KEY}"
fi
set_env_value "${ENV_FILE}" "DATABASE_URL" "sqlite:////${INSTANCE_DIR#/}/print_tracker.db"
set_env_value "${ENV_FILE}" "LABEL_PRINT_MODE" "${PRINT_MODE}"
set_env_value "${ENV_FILE}" "LABEL_PRINTER_QUEUE" "${PRINTER_QUEUE}"
set_env_value "${ENV_FILE}" "LABEL_OUTPUT_DIR" "${LABEL_DIR}"
set_env_value "${ENV_FILE}" "KIOSK_BASE_URL" "${KIOSK_BASE_URL}"
set_env_value "${ENV_FILE}" "LABEL_STOCK" "DK1202"
set_env_value "${ENV_FILE}" "LABEL_DPI" "300"
set_env_value "${ENV_FILE}" "LABEL_ORIENTATION" "landscape"
set_env_value "${ENV_FILE}" "LABEL_QR_PAYLOAD_MODE" "url"
set_env_value "${ENV_FILE}" "LABEL_QR_SIZE_INCH" "0.5"
set_env_value "${ENV_FILE}" "LABEL_CUPS_MEDIA" "${LABEL_MEDIA}"
set_env_value "${ENV_FILE}" "LABEL_SAVE_LABEL_FILES" "true"
set_env_value "${ENV_FILE}" "LABEL_BRAND_TEXT" "NC State University Libraries Makerspace"
[[ -f "${LOGO_DEST}" ]] && set_env_value "${ENV_FILE}" "LABEL_BRAND_LOGO_PATH" "${LOGO_DEST}"
set_env_value "${ENV_FILE}" "DEFAULT_PRINTER_NAME" "${LOCATION_NAME}"
[[ -n "${SITE_ID}" ]] && set_env_value "${ENV_FILE}" "SITE_ID" "${SITE_ID}"

EXISTING_GO_TOKEN="$(get_env_value "${ENV_FILE}" "GO_NCSU_API_TOKEN")"
if [[ -n "${GO_NCSU_API_TOKEN}" ]]; then
  set_env_value "${ENV_FILE}" "GO_NCSU_API_TOKEN" "${GO_NCSU_API_TOKEN}"
elif [[ -z "${EXISTING_GO_TOKEN}" ]]; then
  set_env_value "${ENV_FILE}" "GO_NCSU_API_TOKEN" ""
fi
if [[ -n "${GO_NCSU_LINK_SLUG}" ]]; then
  set_env_value "${ENV_FILE}" "GO_NCSU_LINK_SLUG" "${GO_NCSU_LINK_SLUG}"
else
  EXISTING_GO_SLUG="$(get_env_value "${ENV_FILE}" "GO_NCSU_LINK_SLUG")"
  [[ -z "${EXISTING_GO_SLUG}" ]] && set_env_value "${ENV_FILE}" "GO_NCSU_LINK_SLUG" ""
fi

set_env_value "${ENV_FILE}" "STAFF_PASSWORD" "${STAFF_PASSWORD}"
tui_success "Configuration written to ${ENV_FILE}"

# ── 6. Google OAuth ───────────────────────────────────────────────────────
GOOGLE_OAUTH_CONFIGURED=0
if [[ "${SETUP_GOOGLE_OAUTH}" -eq 1 ]]; then
  tui_progress "Configuring Google OAuth"
  run_google_oauth_setup \
    "${ENV_FILE}" "${APP_DIR}" "${VENV_DIR}/bin/python" \
    "${GOOGLE_CLIENT_SECRETS}" "${GOOGLE_GMAIL_SENDER}" \
    "${GOOGLE_SPREADSHEET_ID}" "${GOOGLE_WORKSHEET}"
  GOOGLE_OAUTH_CONFIGURED=1
  tui_success "Google integration configured."
else
  tui_warn "Google integration skipped."
fi

# ── 7. Database ───────────────────────────────────────────────────────────
if [[ "${SKIP_DB_INIT}" -eq 0 ]]; then
  tui_progress "Initializing database"
  (cd "${APP_DIR}" && "${VENV_DIR}/bin/flask" --app run.py init-db)
  tui_success "Database ready."
else
  tui_warn "Skipping DB init (--skip-db-init)."
fi

# ── 8. CUPS ───────────────────────────────────────────────────────────────
if [[ "${SKIP_CUPS}" -eq 0 ]]; then
  tui_progress "Enabling CUPS printing service"
  run_root systemctl enable --now cups
  tui_success "CUPS enabled."

  tui_progress "Checking for connected printers"
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb | grep -iq brother; then
      tui_success "Brother USB device detected."
    else
      tui_warn "No Brother USB device found — is the printer plugged in and powered on?"
    fi
  fi
  if command -v lpinfo >/dev/null 2>&1; then
    if lpinfo -v 2>/dev/null | grep -Eiq 'usb.*brother|usb.*ql'; then
      tui_success "CUPS sees a compatible USB print backend."
    else
      tui_warn "No QL USB backend listed yet — the printer may need manual CUPS setup."
    fi
  fi
else
  tui_warn "Skipping CUPS setup (--skip-cups)."
fi

# ── 9. Cloudflare tunnel ─────────────────────────────────────────────────
TUNNEL_CONFIGURED=0
[[ "${SETUP_TUNNEL}" -lt 0 ]] && SETUP_TUNNEL=0
if [[ "${SETUP_TUNNEL}" -eq 1 ]]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    tui_warn "cloudflared not installed — tunnel setup skipped."
  else
    tui_progress "Setting up Cloudflare quick tunnel"
    run_root systemctl stop cloudflared 2>/dev/null || true
    run_root systemctl disable cloudflared 2>/dev/null || true
    run_root cloudflared service uninstall 2>/dev/null || true
    run_root systemctl stop cloudflared-quick 2>/dev/null || true

    TUNNEL_SCRIPT="${APP_DIR}/scripts/start_tunnel.sh"
    chmod +x "${TUNNEL_SCRIPT}"

    run_root tee /etc/systemd/system/cloudflared-quick.service >/dev/null <<CFDEOF
[Unit]
Description=Cloudflare Quick Tunnel for Print Tracker
After=network-online.target ${SERVICE_NAME}.service
Wants=network-online.target

[Service]
Environment=APP_PORT=${PORT}
Environment=ENV_FILE=${ENV_FILE}
Environment=SERVICE_NAME=${SERVICE_NAME}
ExecStart=${TUNNEL_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CFDEOF
    run_root systemctl daemon-reload
    run_root systemctl enable --now cloudflared-quick

    sleep 5
    TUNNEL_URL="$(journalctl -u cloudflared-quick --no-pager -n 50 2>/dev/null \
      | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
    TUNNEL_CONFIGURED=1
    tui_success "Cloudflare tunnel service started."
  fi
fi

# ── 10. go.ncsu.edu short link ───────────────────────────────────────────
GOLINK_CONFIGURED=0
[[ "${SETUP_GOLINK}" -lt 0 ]] && SETUP_GOLINK=0
if [[ "${SETUP_GOLINK}" -eq 1 && -n "${GO_NCSU_API_TOKEN}" && -n "${GO_NCSU_LINK_SLUG}" ]]; then
  # Determine the target URL for the golink
  GOLINK_TARGET=""
  if [[ "${TUNNEL_CONFIGURED}" -eq 1 && -n "${TUNNEL_URL:-}" ]]; then
    GOLINK_TARGET="${TUNNEL_URL}"
  else
    GOLINK_TARGET="${KIOSK_BASE_URL}"
  fi

  tui_progress "Creating go.ncsu.edu/${GO_NCSU_LINK_SLUG}"

  # Loop to allow retries if the slug is taken
  while true; do
    GO_API_URL="https://go.ncsu.edu/api/v2/links"
    GOLINK_RESP_FILE="$(mktemp /tmp/golink-create-XXXX.json)"
    GOLINK_HTTP_CODE="$(curl --silent --location \
      --output "${GOLINK_RESP_FILE}" --write-out '%{http_code}' \
      --request POST "${GO_API_URL}" \
      --header "Authorization: Bearer ${GO_NCSU_API_TOKEN}" \
      --header "Content-Type: application/json" \
      --header "Accept: application/json" \
      --data "{
        \"slug\": \"${GO_NCSU_LINK_SLUG}\",
        \"target_url\": \"${GOLINK_TARGET}\",
        \"enabled\": true,
        \"exclude_from_status_check\": true
      }")" || true
    GOLINK_RESP_BODY="$(cat "${GOLINK_RESP_FILE}" 2>/dev/null)"
    rm -f "${GOLINK_RESP_FILE}"

    if [[ "${GOLINK_HTTP_CODE}" =~ ^2[0-9][0-9]$ ]]; then
      set_env_value "${ENV_FILE}" "GO_NCSU_LINK_SLUG" "${GO_NCSU_LINK_SLUG}"
      GOLINK_CONFIGURED=1
      tui_success "Created go.ncsu.edu/${GO_NCSU_LINK_SLUG} → ${GOLINK_TARGET}"
      break
    elif [[ "${GOLINK_HTTP_CODE}" == "409" || "${GOLINK_RESP_BODY}" == *"already"* || "${GOLINK_RESP_BODY}" == *"taken"* || "${GOLINK_RESP_BODY}" == *"exists"* || "${GOLINK_RESP_BODY}" == *"conflict"* ]]; then
      tui_warn "The slug '${GO_NCSU_LINK_SLUG}' is already taken on go.ncsu.edu."
      if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
        tui_warn "Non-interactive mode — cannot retry. Skipping golink creation."
        break
      fi
      if prompt_yes_no "Try a different slug name" "y"; then
        GO_NCSU_LINK_SLUG="$(prompt_default "Short link slug" "")"
        printf '\n'
        if [[ -z "${GO_NCSU_LINK_SLUG}" ]]; then
          tui_warn "No slug provided — skipping golink creation."
          break
        fi
        tui_progress "Trying go.ncsu.edu/${GO_NCSU_LINK_SLUG}"
      else
        tui_warn "Skipping golink creation."
        break
      fi
    else
      tui_fail "Failed to create golink (HTTP ${GOLINK_HTTP_CODE})."
      if [[ -n "${GOLINK_RESP_BODY}" ]]; then
        tui_explain "  API response: ${GOLINK_RESP_BODY}"
      fi
      tui_warn "You can create the link manually later or re-run the deploy script."
      break
    fi
  done
elif [[ "${SETUP_GOLINK}" -eq 1 ]]; then
  tui_warn "GoLink setup requested but token or slug is missing — skipping."
fi

# ── 11. systemd service ──────────────────────────────────────────────────
if [[ "${SKIP_SERVICE}" -eq 0 ]]; then
  tui_progress "Creating systemd service (${SERVICE_NAME})"
  run_root tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=Print Tracker
After=network.target cups.service

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PORT=${PORT}
ExecStart=${VENV_DIR}/bin/gunicorn --workers 2 --threads 2 --bind 0.0.0.0:${PORT} run:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  run_root systemctl daemon-reload
  run_root systemctl enable --now "${SERVICE_NAME}"
  tui_success "Service ${SERVICE_NAME} is running."
else
  tui_warn "Skipping systemd setup (--skip-service)."
fi

# ╔═══════════════════════════════════════════════════════════════════════╗
# ║                        ALL DONE!                                      ║
# ╚═══════════════════════════════════════════════════════════════════════╝

printf '\n'
tui_banner "Deployment Complete!"
printf '\n'

# ── Live URL ──────────────────────────────────────────────────────────────
printf '  %b%s Your app is live!%b\n\n' "${C_GREEN}" "${SYM_CHECK}" "${C_RESET}"
printf '     Local URL:   %bhttp://%s:%s/patron/register%b\n' "${C_BOLD}" "${HOST_IP}" "${PORT}" "${C_RESET}"
if [[ "${TUNNEL_CONFIGURED}" -eq 1 && -n "${TUNNEL_URL:-}" ]]; then
  printf '     Public URL:  %b%s%b\n' "${C_BOLD}" "${TUNNEL_URL}" "${C_RESET}"
fi
if [[ "${GOLINK_CONFIGURED}" -eq 1 ]]; then
  printf '     Short link:  %bgo.ncsu.edu/%s%b\n' "${C_BOLD}" "${GO_NCSU_LINK_SLUG}" "${C_RESET}"
fi
printf '\n'

# ── Next Steps ────────────────────────────────────────────────────────────
tui_rule '─'
printf '\n  %bWhat to do next:%b\n\n' "${C_BOLD}" "${C_RESET}"

printf '  %b 1 %b  Open the app in a browser and submit a test print:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
printf '       http://%s:%s/patron/register\n\n' "${HOST_IP}" "${PORT}"

if [[ "${PRINT_MODE}" == "cups" ]]; then
  printf '  %b 2 %b  Verify the printer is set up in CUPS:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  printf '       Open http://localhost:631 and check that "%s" appears.\n\n' "${PRINTER_QUEUE}"

  printf '  %b 3 %b  Print a CUPS test page:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  printf '       lp -d %s /usr/share/cups/data/testprint\n\n' "${PRINTER_QUEUE}"

  printf '  %b 4 %b  Submit a test print and confirm the label comes out.\n\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
else
  printf '  %b 2 %b  Submit a test print — labels are saved as images in:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  printf '       %s/\n\n' "${LABEL_DIR}"
fi

# ── Tunnel extra info ─────────────────────────────────────────────────────
if [[ "${TUNNEL_CONFIGURED}" -eq 1 ]]; then
  tui_rule '─'
  printf '\n  %bCloudflare Tunnel%b\n\n' "${C_BOLD}" "${C_RESET}"
  if [[ -n "${TUNNEL_URL:-}" ]]; then
    printf '  Public URL: %b%s%b\n\n' "${C_BOLD}" "${TUNNEL_URL}" "${C_RESET}"
    tui_explain "  NOTE: This URL changes every time the tunnel restarts."
    tui_explain "  If you configure go.ncsu.edu, the app updates the short link automatically."
  else
    tui_warn "Tunnel is running but URL hasn't appeared yet. Check with:"
    tui_explain "    sudo journalctl -u cloudflared-quick -n 20 | grep trycloudflare"
  fi
  printf '\n'
fi

# ── Google info ───────────────────────────────────────────────────────────
if [[ "${GOOGLE_OAUTH_CONFIGURED}" -eq 0 && "${SETUP_GOOGLE_OAUTH}" -ne 1 ]]; then
  tui_rule '─'
  printf '\n  %bGoogle Integration (not set up yet)%b\n\n' "${C_BOLD}" "${C_RESET}"
  tui_explain "  To enable Gmail notifications and Google Sheets sync later:"
  printf '\n'
  printf '  %b 1 %b  Get OAuth credentials from Google Cloud Console:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  printf '       https://console.cloud.google.com/apis/credentials\n'
  tui_explain "       Under 'OAuth 2.0 Client IDs' → click the download icon"
  printf '\n'
  printf '  %b 2 %b  Run the bootstrap script:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  printf '       cd %s\n' "${APP_DIR}"
  printf '       source .venv/bin/activate\n'
  printf '       python scripts/google_oauth_bootstrap.py --client-secrets /path/to/client_secret.json\n\n'
  printf '  %b 3 %b  Restart the service:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  printf '       sudo systemctl restart %s\n\n' "${SERVICE_NAME}"
elif [[ "${GOOGLE_OAUTH_CONFIGURED}" -eq 1 ]]; then
  tui_rule '─'
  printf '\n'
  tui_success "Google OAuth is configured (Gmail + Sheets)."
  printf '\n'
fi

# ── GoLink info ───────────────────────────────────────────────────────────
if [[ "${GOLINK_CONFIGURED}" -eq 1 ]]; then
  tui_rule '─'
  printf '\n  %bgo.ncsu.edu Short Link%b\n\n' "${C_BOLD}" "${C_RESET}"
  printf '  Short URL: %bgo.ncsu.edu/%s%b\n\n' "${C_BOLD}" "${GO_NCSU_LINK_SLUG}" "${C_RESET}"
  tui_explain "  The tunnel URL changes when the tunnel restarts, but the go.ncsu.edu"
  tui_explain "  short link is updated automatically by the tunnel startup script."
  printf '\n'
elif [[ "${SETUP_GOLINK}" -ne 1 ]]; then
  tui_rule '─'
  printf '\n  %bgo.ncsu.edu Short Link (not set up yet)%b\n\n' "${C_BOLD}" "${C_RESET}"
  tui_explain "  To create a permanent short link later:"
  printf '\n'
  printf '  %b 1 %b  Get an API token at https://go.ncsu.edu/api/help\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  tui_explain "       Enter a token name, click Create Token, and copy the ID."
  tui_explain "       You only see the token once!"
  printf '\n'
  printf '  %b 2 %b  Add to .env:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  printf '       GO_NCSU_API_TOKEN=<your-token>\n'
  printf '       GO_NCSU_LINK_SLUG=<your-link-name>\n\n'
  printf '  %b 3 %b  Run the update script:\n' "${C_BG_CYAN}${C_WHITE}" "${C_RESET}"
  printf '       %s/scripts/update_golink.sh\n\n' "${APP_DIR}"
fi

# ── Cheat sheet ───────────────────────────────────────────────────────────
tui_rule '─'
printf '\n  %bHandy Commands Cheat Sheet:%b\n\n' "${C_BOLD}" "${C_RESET}"
printf '  %b%-35s%b %s\n' "${C_DIM}" "View live app logs" "${C_RESET}" "journalctl -u ${SERVICE_NAME} -f"
printf '  %b%-35s%b %s\n' "${C_DIM}" "Restart the app" "${C_RESET}" "sudo systemctl restart ${SERVICE_NAME}"
printf '  %b%-35s%b %s\n' "${C_DIM}" "Stop the app" "${C_RESET}" "sudo systemctl stop ${SERVICE_NAME}"
printf '  %b%-35s%b %s\n' "${C_DIM}" "Check app status" "${C_RESET}" "sudo systemctl status ${SERVICE_NAME}"
printf '  %b%-35s%b %s\n' "${C_DIM}" "Edit configuration" "${C_RESET}" "nano ${ENV_FILE}"
if [[ "${TUNNEL_CONFIGURED}" -eq 1 ]]; then
  printf '  %b%-35s%b %s\n' "${C_DIM}" "View tunnel logs" "${C_RESET}" "sudo journalctl -u cloudflared-quick -f"
  printf '  %b%-35s%b %s\n' "${C_DIM}" "Restart tunnel" "${C_RESET}" "sudo systemctl restart cloudflared-quick"
fi
if [[ "${GOLINK_CONFIGURED}" -eq 1 ]]; then
  printf '  %b%-35s%b %s\n' "${C_DIM}" "Update golink URL" "${C_RESET}" "${APP_DIR}/scripts/update_golink.sh"
fi
printf '  %b%-35s%b %s\n' "${C_DIM}" "List CUPS printers" "${C_RESET}" "lpstat -e"
printf '  %b%-35s%b %s\n' "${C_DIM}" "CUPS web admin" "${C_RESET}" "http://localhost:631"
printf '\n'

tui_rule '═'
printf '\n  %bDone! Happy printing.%b 🖨️\n\n' "${C_BOLD}" "${C_RESET}"
