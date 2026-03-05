#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="print-tracker"
SERVICE_USER="${SUDO_USER:-${USER}}"
SERVICE_GROUP="$(id -gn "${SERVICE_USER}" 2>/dev/null || echo "${SERVICE_USER}")"
REPO_URL="https://github.com/ColinRNickels/printtracker.git"
DEPLOY_DIR=""
PORT="5000"
PRINT_MODE="cups"
PRINTER_QUEUE="QL800"
LABEL_MEDIA="DK-1202"
STAFF_PASSWORD="staffpw"
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
GOOGLE_SPREADSHEET_ID="1H0y3uRWZIUOXlwIJcKXujPLFAVzN3LjpZ9ACoJ2LNck"
GOOGLE_WORKSHEET="PrintJobs"
SETUP_TUNNEL=-1

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
  --staff-password PASS     Staff dashboard password (required).
  --setup-google-oauth     Run Google OAuth setup during deploy.
  --no-google-oauth        Skip Google OAuth setup during deploy.
  --google-client-secrets PATH
                           Path to OAuth client JSON from Google Cloud.
  --google-gmail-sender EMAIL
                           Sender email for Gmail API (optional).
  --google-spreadsheet-id ID
                           Spreadsheet ID for Google Sheets sync (optional).
  --google-worksheet NAME  Worksheet tab name (default: PrintJobs).
  --setup-tunnel           Set up a Cloudflare quick tunnel (free, no domain needed).
  --no-tunnel              Skip Cloudflare Tunnel setup.
  --site-id ID             Short site prefix for Print IDs (e.g. HL, PT). Avoids
                           collisions when multiple Pis sync to the same sheet.
  --location-name NAME     Human-readable location name (e.g. "Hill Library").
  --logo-source PATH       Optional local PNG path for label logo.
  --skip-apt               Skip apt package install/update.
  --skip-cups              Skip CUPS service setup and printer checks.
  --skip-service           Skip systemd service setup.
  --skip-db-init           Skip database initialization.
  -h, --help               Show this help.
EOF
}

log() {
  printf '\n[deploy] %s\n' "$*"
}

warn() {
  printf '\n[deploy] WARNING: %s\n' "$*" >&2
}

die() {
  printf '\n[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local input=""
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    printf '%s' "${default}"
    return 0
  fi
  read -r -p "${prompt} [${default}]: " input
  if [[ -n "${input}" ]]; then
    printf '%s' "${input}"
  else
    printf '%s' "${default}"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local input=""
  local hint="y/N"

  if [[ "${default}" =~ ^([Yy]|[Yy]es)$ ]]; then
    hint="Y/n"
  fi

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    [[ "${default}" =~ ^([Yy]|[Yy]es)$ ]]
    return
  fi

  while true; do
    read -r -p "${prompt} [${hint}]: " input
    if [[ -z "${input}" ]]; then
      input="${default}"
    fi
    case "${input}" in
      y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
      *)
        printf 'Please enter y or n.\n'
        ;;
    esac
  done
}

set_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  python3 - "${env_file}" "${key}" "${value}" <<'PY'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

if env_path.exists():
    lines = env_path.read_text().splitlines()
else:
    lines = []

needle = f"{key}="
updated = []
found = False
for line in lines:
    if line.startswith(needle):
        updated.append(f"{key}={value}")
        found = True
    else:
        updated.append(line)

if not found:
    updated.append(f"{key}={value}")

env_path.write_text("\n".join(updated).rstrip() + "\n")
PY
}

get_env_value() {
  local env_file="$1"
  local key="$2"
  python3 - "${env_file}" "${key}" <<'PY'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
key = sys.argv[2]
needle = f"{key}="

if not env_path.exists():
    sys.exit(0)

for line in env_path.read_text().splitlines():
    if line.startswith(needle):
        print(line[len(needle):])
        break
PY
}



run_google_oauth_setup() {
  local env_file="$1"
  local app_dir="$2"
  local venv_python="$3"
  local client_secrets="$4"
  local sender="$5"
  local spreadsheet_id="$6"
  local worksheet="$7"

  local output_file=""
  output_file="$(mktemp)"

  local -a oauth_cmd=(
    "${venv_python}"
    "${app_dir}/scripts/google_oauth_bootstrap.py"
    --client-secrets "${client_secrets}"
  )
  if [[ -n "${sender}" ]]; then
    oauth_cmd+=(--gmail-sender "${sender}")
  fi

  log "Starting Google OAuth flow (browser or console prompt)..."
  (cd "${app_dir}" && "${oauth_cmd[@]}") > >(tee "${output_file}") 2>&1

  while IFS= read -r line; do
    [[ "${line}" == *=* ]] || continue
    local key="${line%%=*}"
    local value="${line#*=}"
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
      warn "No Google Spreadsheet ID provided yet. Sheets sync remains disabled until GOOGLE_SHEETS_SPREADSHEET_ID is set."
    fi
  fi
  if [[ -n "${worksheet}" ]]; then
    set_env_value "${env_file}" "GOOGLE_SHEETS_WORKSHEET" "${worksheet}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    --service-user)
      SERVICE_USER="$2"
      shift 2
      ;;
    --service-group)
      SERVICE_GROUP="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --print-mode)
      PRINT_MODE="$2"
      shift 2
      ;;
    --repo-dir)
      DEPLOY_DIR="$2"
      shift 2
      ;;
    --printer-queue)
      PRINTER_QUEUE="$2"
      shift 2
      ;;
    --media)
      LABEL_MEDIA="$2"
      shift 2
      ;;
    --staff-password)
      STAFF_PASSWORD="$2"
      shift 2
      ;;
    --setup-google-oauth)
      SETUP_GOOGLE_OAUTH=1
      shift
      ;;
    --no-google-oauth)
      SETUP_GOOGLE_OAUTH=0
      shift
      ;;
    --google-client-secrets)
      GOOGLE_CLIENT_SECRETS="$2"
      shift 2
      ;;
    --google-gmail-sender)
      GOOGLE_GMAIL_SENDER="$2"
      shift 2
      ;;
    --google-spreadsheet-id)
      GOOGLE_SPREADSHEET_ID="$2"
      shift 2
      ;;
    --google-worksheet)
      GOOGLE_WORKSHEET="$2"
      shift 2
      ;;
    --setup-tunnel)
      SETUP_TUNNEL=1
      shift
      ;;
    --no-tunnel)
      SETUP_TUNNEL=0
      shift
      ;;
    --site-id)
      SITE_ID="$2"
      shift 2
      ;;
    --location-name)
      LOCATION_NAME="$2"
      shift 2
      ;;
    --logo-source)
      LOGO_SOURCE="$2"
      shift 2
      ;;
    --skip-apt)
      SKIP_APT=1
      shift
      ;;
    --skip-cups)
      SKIP_CUPS=1
      shift
      ;;
    --skip-service)
      SKIP_SERVICE=1
      shift
      ;;
    --skip-db-init)
      SKIP_DB_INIT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# --- Clone or update the repository -------------------------------------------
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
[[ "${PRINT_MODE}" == "cups" || "${PRINT_MODE}" == "mock" ]] || die "--print-mode must be cups or mock."

if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
  cat <<'WELCOME'

========================================================================
  Print Tracker – Interactive Setup
========================================================================

  This script will ask a series of questions to configure the app.
  Each question shows a default value in [brackets]. Press Enter to
  accept the default, or type a new value.

  Tip: If you're unsure about a question, the default is almost always
  the right choice. You can change any setting later by editing the
  .env file in the project directory.
========================================================================

WELCOME

  if [[ -z "${STAFF_PASSWORD}" ]]; then
    cat <<'PWHELP'
--- Staff Dashboard Password -------------------------------------------
This password protects the staff dashboard where you manage print jobs,
view reports, and change settings. Share it only with authorized staff.
Pick something memorable but not easily guessed.
------------------------------------------------------------------------
PWHELP
    while true; do
      read -r -s -p "Staff dashboard password (required): " STAFF_PASSWORD
      printf '\n'
      if [[ -z "${STAFF_PASSWORD}" ]]; then
        printf 'Password cannot be empty.\n'
        continue
      fi
      read -r -s -p "Confirm password: " pw_confirm
      printf '\n'
      if [[ "${STAFF_PASSWORD}" != "${pw_confirm}" ]]; then
        printf 'Passwords do not match. Try again.\n'
        STAFF_PASSWORD=""
        continue
      fi
      break
    done
  fi

  cat <<'SVCHELP'

--- Linux Service Account -----------------------------------------------
The app runs as a background service on this machine. These two settings
control *which Linux user and group* own that service.

  Service user  – almost always your login name (the default shown).
                  To check, run:  whoami
  Service group – almost always the same as the user name.

Unless you have a specific reason to change these, accept the defaults.
-------------------------------------------------------------------------
SVCHELP
  SERVICE_USER="$(prompt_default "Service user" "${SERVICE_USER}")"
  SERVICE_GROUP="$(prompt_default "Service group" "${SERVICE_GROUP}")"

  cat <<'PORTHELP'

--- Web App Port --------------------------------------------------------
The port number the web app listens on (like a channel number). The
default is 5000. You only need to change this if another program on
this machine already uses port 5000.

Access the app at:  http://<this-machine's-IP>:<port>
-------------------------------------------------------------------------
PORTHELP
  PORT="$(prompt_default "Web app port" "${PORT}")"

  cat <<'PRINTHELP'

--- Printing Setup ------------------------------------------------------
Print mode:
  cups  – Print to a real Brother QL label printer connected via USB.
          Choose this for production use.
  mock  – Don't actually print anything. Useful for testing or
          development when no printer is connected.

CUPS queue name:
  The name of the printer as registered in the CUPS printing system.
  To see available printers, run:  lpstat -e
  The default "QL800" matches a standard Brother QL-800.

CUPS media token:
  The label size code. "DK-1202" is the standard Brother shipping label
  (62 mm × 100 mm). Only change this if you use a different label stock.
-------------------------------------------------------------------------
PRINTHELP
  PRINT_MODE="$(prompt_default "Print mode (cups or mock)" "${PRINT_MODE}")"
  PRINTER_QUEUE="$(prompt_default "CUPS queue name" "${PRINTER_QUEUE}")"
  LABEL_MEDIA="$(prompt_default "CUPS media token" "${LABEL_MEDIA}")"

  cat <<'LOCHELP'

--- Location / Site Identity --------------------------------------------
If you run Print Tracker on more than one Pi (e.g. different campus
buildings), each should have a unique location name and site ID so jobs
can be told apart — especially in the shared Google Sheet.

Location name:
  A human-readable name for this printer station, e.g. "Hill Library"
  or "Hunt Library". It appears on labels and in reports.

Site ID (short code):
  A 2–4 letter prefix added to every Print ID this Pi generates.
  Examples: HL for Hill Library, HU for Hunt Library.
  This prevents ID collisions when two Pis create a job at the same
  second. Leave blank to use the default "PT".

If this is your only Pi, the defaults are fine.
-------------------------------------------------------------------------
LOCHELP
  LOCATION_NAME="$(prompt_default "Location name" "${LOCATION_NAME}")"
  SITE_ID="$(prompt_default "Site ID (short code, e.g. HL)" "${SITE_ID:-PT}")"

  if [[ "${SETUP_TUNNEL}" -lt 0 ]]; then
    cat <<'TUNHELP'

--- Cloudflare Quick Tunnel (optional) ----------------------------------
A Cloudflare tunnel gives your Pi a public HTTPS URL so that people
outside your local network (e.g. on campus Wi-Fi) can reach the kiosk.
It's free and requires no domain name or router configuration.

Say YES if the kiosk needs to be reachable from the internet.
Say NO if it will only be used on the same local network as the Pi.

You can set this up later by re-running the deploy script.
-------------------------------------------------------------------------
TUNHELP
    if prompt_yes_no "Set up a Cloudflare quick tunnel" "y"; then
      SETUP_TUNNEL=1
    else
      SETUP_TUNNEL=0
    fi
  fi

  if [[ "${SETUP_GOOGLE_OAUTH}" -lt 0 ]]; then
    cat <<'GHELP'

--- Google Integration (optional) ---------------------------------------
This connects the app to Google for two features:
  1. Email notifications – send pick-up alerts to users via Gmail.
  2. Sheets sync – log every print job to a Google Spreadsheet.

Both features require OAuth credentials from Google Cloud Console.

If you have a "client_secret*.json" file from Google Cloud, say YES.
Otherwise say NO; you can configure this later.
-------------------------------------------------------------------------
GHELP
    if prompt_yes_no "Configure Google OAuth now (Gmail + Sheets)" "y"; then
      SETUP_GOOGLE_OAUTH=1

      cat <<'CSHELP'

  Path to Google OAuth client JSON:
    This is a JSON file you download from the Google Cloud Console under
    APIs & Services → Credentials → OAuth 2.0 Client IDs → Download JSON.
    It is usually saved to your Downloads folder as "client_secret_<…>.json".
CSHELP
      GOOGLE_CLIENT_SECRETS="$(prompt_default "Path to Google OAuth client JSON" "${HOME}/Downloads/client_secret.json")"

      cat <<'GMHELP'

  Gmail sender address:
    The "From" address that appears on notification emails. This must be
    a Gmail or Google Workspace address that the OAuth account can send as.
    Leave the default unless your team uses a different shared mailbox.
GMHELP
      GOOGLE_GMAIL_SENDER="$(prompt_default "Gmail sender address" "${GOOGLE_GMAIL_SENDER}")"

      cat <<'GSHELP'

  Google Spreadsheet ID:
    Open your Google Sheet in a browser. The long string of letters and
    numbers in the URL between /d/ and /edit is the Spreadsheet ID.
    Example URL: https://docs.google.com/spreadsheets/d/ABC123xyz/edit
                                                       ^^^^^^^^^^^
    You can add this later by editing the .env file if you don't have it yet.
GSHELP
      GOOGLE_SPREADSHEET_ID="$(prompt_default "Google Spreadsheet ID (press Enter to skip for now)" "${GOOGLE_SPREADSHEET_ID}")"

      cat <<'GWHELP'

  Google worksheet tab name:
    The name of the tab (sheet) within the spreadsheet where print jobs
    are logged. The default is "PrintJobs". Only change this if your
    spreadsheet uses a different tab name.
GWHELP
      GOOGLE_WORKSHEET="$(prompt_default "Google worksheet tab" "${GOOGLE_WORKSHEET}")"
    else
      SETUP_GOOGLE_OAUTH=0
    fi
  fi
fi

[[ "${PRINT_MODE}" == "cups" || "${PRINT_MODE}" == "mock" ]] || die "Print mode must be cups or mock."
[[ "${PORT}" =~ ^[0-9]+$ ]] || die "Port must be a number."
[[ -n "${STAFF_PASSWORD}" ]] || die "Staff password is required. Use --staff-password or run in interactive mode."
if [[ "${SETUP_GOOGLE_OAUTH}" -lt 0 ]]; then
  SETUP_GOOGLE_OAUTH=0
fi
if [[ "${SETUP_GOOGLE_OAUTH}" -eq 1 ]]; then
  [[ -n "${GOOGLE_CLIENT_SECRETS}" ]] || die "Google OAuth setup requested, but --google-client-secrets path is missing."
  if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
    while [[ ! -f "${GOOGLE_CLIENT_SECRETS}" ]]; do
      warn "Google OAuth client secrets file not found: ${GOOGLE_CLIENT_SECRETS}"
      if prompt_yes_no "Try a different client secrets path" "y"; then
        GOOGLE_CLIENT_SECRETS="$(prompt_default "Path to Google OAuth client JSON" "${HOME}/Downloads/client_secret.json")"
      else
        SETUP_GOOGLE_OAUTH=0
        warn "Google OAuth setup skipped by user."
        break
      fi
    done
  fi
fi
if [[ "${SETUP_GOOGLE_OAUTH}" -eq 1 ]]; then
  if [[ ! -f "${GOOGLE_CLIENT_SECRETS}" ]]; then
    die "Google OAuth client secrets file not found: ${GOOGLE_CLIENT_SECRETS}"
  fi
fi

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
  if [[ "${SKIP_SERVICE}" -eq 0 ]]; then
    die "Use a path without spaces for systemd deploy (recommended: /opt/print-tracker)."
  fi
fi

if [[ -z "${LOGO_SOURCE}" && -f "${DEFAULT_LOGO_SOURCE}" ]]; then
  LOGO_SOURCE="${DEFAULT_LOGO_SOURCE}"
fi

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="localhost"
fi
KIOSK_BASE_URL="http://${HOST_IP}:${PORT}"

SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"

log "Project directory: ${APP_DIR}"
log "Service user/group: ${SERVICE_USER}:${SERVICE_GROUP}"
log "Kiosk URL base (for QR links): ${KIOSK_BASE_URL}"

if [[ "${SKIP_APT}" -eq 0 ]]; then
  log "Installing system packages (this can take several minutes)..."

  # Remove stale Cloudflare apt repo if present (cloudflared is installed
  # via direct .deb download below, not through their apt repo).
  if [[ -f /etc/apt/sources.list.d/cloudflared.list ]]; then
    log "Removing stale Cloudflare apt repo entry..."
    run_root rm -f /etc/apt/sources.list.d/cloudflared.list
  fi

  run_root apt-get update
  APT_PACKAGES=(
    git
    python3-venv python3-pip python3-dev build-essential
    cups cups-client cups-bsd
    printer-driver-ptouch
    avahi-daemon
    usbutils
  )
  run_root apt-get install -y "${APT_PACKAGES[@]}"

  if ! command -v cloudflared >/dev/null 2>&1; then
    log "Installing cloudflared..."
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
  else
    log "cloudflared already installed: $(cloudflared --version)"
  fi
else
  warn "Skipping apt package install (--skip-apt)."
fi

if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  log "Adding ${SERVICE_USER} to lpadmin/lp groups..."
  run_root usermod -aG lpadmin,lp "${SERVICE_USER}" || true
else
  warn "User ${SERVICE_USER} not found; skipping usermod."
fi

log "Preparing Python environment..."
VENV_OK=0
if [[ -x "${VENV_DIR}/bin/python" ]]; then
  if "${VENV_DIR}/bin/python" -c "import sys; print(sys.version_info[0])" >/dev/null 2>&1; then
    VENV_OK=1
    log "Reusing existing virtualenv at ${VENV_DIR}"
  else
    warn "Existing virtualenv is invalid/corrupted; rebuilding ${VENV_DIR}"
  fi
fi

if [[ "${VENV_OK}" -eq 0 ]]; then
  if [[ -d "${VENV_DIR}" ]]; then
    if run_root systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
      run_root systemctl stop "${SERVICE_NAME}" || true
    fi
    rm -rf "${VENV_DIR}"
  fi
  python3 -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/python" -m pip install --upgrade pip
"${VENV_DIR}/bin/python" -m pip install -r "${APP_DIR}/requirements.txt" gunicorn

log "Creating app directories..."
mkdir -p "${INSTANCE_DIR}" "${LABEL_DIR}" "${ASSETS_DIR}"

if [[ -n "${LOGO_SOURCE}" ]]; then
  if [[ -f "${LOGO_SOURCE}" ]]; then
    cp "${LOGO_SOURCE}" "${LOGO_DEST}"
    log "Copied logo to ${LOGO_DEST}"
  else
    warn "Logo source not found: ${LOGO_SOURCE}. Label logo will fall back to text."
  fi
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${APP_DIR}/.env.example" "${ENV_FILE}"
  log "Created ${ENV_FILE} from .env.example"
fi

log "Writing .env settings..."
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
if [[ -f "${LOGO_DEST}" ]]; then
  set_env_value "${ENV_FILE}" "LABEL_BRAND_LOGO_PATH" "${LOGO_DEST}"
fi
set_env_value "${ENV_FILE}" "DEFAULT_PRINTER_NAME" "${LOCATION_NAME}"
if [[ -n "${SITE_ID}" ]]; then
  set_env_value "${ENV_FILE}" "SITE_ID" "${SITE_ID}"
fi

# Preserve existing go.ncsu.edu token if already set
EXISTING_GO_TOKEN="$(get_env_value "${ENV_FILE}" "GO_NCSU_API_TOKEN")"
if [[ -z "${EXISTING_GO_TOKEN}" ]]; then
  set_env_value "${ENV_FILE}" "GO_NCSU_API_TOKEN" ""
fi
EXISTING_GO_SLUG="$(get_env_value "${ENV_FILE}" "GO_NCSU_LINK_SLUG")"
if [[ -z "${EXISTING_GO_SLUG}" ]]; then
  set_env_value "${ENV_FILE}" "GO_NCSU_LINK_SLUG" "makerspace-print-label"
fi

set_env_value "${ENV_FILE}" "STAFF_PASSWORD" "${STAFF_PASSWORD}"

GOOGLE_OAUTH_CONFIGURED=0
if [[ "${SETUP_GOOGLE_OAUTH}" -eq 1 ]]; then
  run_google_oauth_setup \
    "${ENV_FILE}" \
    "${APP_DIR}" \
    "${VENV_DIR}/bin/python" \
    "${GOOGLE_CLIENT_SECRETS}" \
    "${GOOGLE_GMAIL_SENDER}" \
    "${GOOGLE_SPREADSHEET_ID}" \
    "${GOOGLE_WORKSHEET}"
  GOOGLE_OAUTH_CONFIGURED=1
else
  warn "Skipping Google OAuth setup. You can run later with: source .venv/bin/activate && python scripts/google_oauth_bootstrap.py --client-secrets /path/to/client_secret.json"
fi

if [[ "${SKIP_DB_INIT}" -eq 0 ]]; then
  log "Initializing database..."
  (cd "${APP_DIR}" && "${VENV_DIR}/bin/flask" --app run.py init-db)
else
  warn "Skipping DB initialization (--skip-db-init)."
fi

if [[ "${SKIP_CUPS}" -eq 0 ]]; then
  log "Enabling CUPS..."
  run_root systemctl enable --now cups
  log "Detected print devices:"
  if command -v lsusb >/dev/null 2>&1; then
    lsusb | grep -i brother || warn "No Brother USB device detected yet."
  else
    warn "lsusb not found. Install usbutils or skip this check."
  fi
  if command -v lpinfo >/dev/null 2>&1; then
    lpinfo -v | grep -Ei 'usb|brother|ql' || warn "No obvious QL USB backend listed yet."
  else
    warn "lpinfo not found. CUPS client tools may not be installed."
  fi
else
  warn "Skipping CUPS setup (--skip-cups)."
fi

TUNNEL_CONFIGURED=0
if [[ "${SETUP_TUNNEL}" -lt 0 ]]; then
  SETUP_TUNNEL=0
fi
if [[ "${SETUP_TUNNEL}" -eq 1 ]]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    warn "cloudflared not installed. Tunnel setup skipped."
  else
    log "Setting up Cloudflare quick tunnel as a systemd service..."
    # Remove any previous cloudflared service to avoid conflicts
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

    # Wait a moment for the tunnel to come up and grab the URL
    sleep 5
    TUNNEL_URL="$(journalctl -u cloudflared-quick --no-pager -n 50 2>/dev/null \
      | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
    TUNNEL_CONFIGURED=1
  fi
fi

if [[ "${SKIP_SERVICE}" -eq 0 ]]; then
  log "Writing systemd service..."
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
else
  warn "Skipping systemd setup (--skip-service)."
fi

log "Verifying service status..."
if [[ "${SKIP_SERVICE}" -eq 0 ]]; then
  run_root systemctl --no-pager --full status "${SERVICE_NAME}" || true
fi

if [[ "${SKIP_CUPS}" -eq 0 ]]; then
  log "Current CUPS queues:"
  lpstat -e || true
fi

cat <<EOF

Deployment complete.

Next checks:
1) On the Pi, open http://127.0.0.1:${PORT}/kiosk/register
2) In CUPS, confirm queue "${PRINTER_QUEUE}" exists: http://localhost:631
3) Print a CUPS test page:
   lp -d ${PRINTER_QUEUE} /usr/share/cups/data/testprint
4) Submit one kiosk print and confirm label output.

Useful commands:
- Service logs: journalctl -u ${SERVICE_NAME} -f
- Restart app: sudo systemctl restart ${SERVICE_NAME}

Important post-deploy checks:
- Confirm KIOSK_BASE_URL in ${ENV_FILE} is reachable from staff devices for QR scans.

EOF

if [[ "${TUNNEL_CONFIGURED}" -eq 1 ]]; then
  cat <<EOF
Cloudflare Quick Tunnel is running:
- Service: sudo systemctl status cloudflared-quick
- Logs: sudo journalctl -u cloudflared-quick -f
EOF
  if [[ -n "${TUNNEL_URL:-}" ]]; then
    cat <<EOF
- Public URL: ${TUNNEL_URL}

Update KIOSK_BASE_URL in ${ENV_FILE} to this URL, then restart:
  sudo systemctl restart ${SERVICE_NAME}

NOTE: This URL changes every time the tunnel restarts.
For a permanent URL, add a domain to Cloudflare and use a named tunnel.
EOF
  else
    cat <<EOF

Could not detect the tunnel URL yet. Check with:
  sudo journalctl -u cloudflared-quick -n 20 | grep trycloudflare
EOF
  fi
  printf '\n'
fi

if [[ "${GOOGLE_OAUTH_CONFIGURED}" -eq 1 ]]; then
  cat <<EOF
Google OAuth is configured in ${ENV_FILE}.
- Gmail API sender is enabled through EMAIL_PROVIDER=gmail_api.
- Google Sheets sync is enabled when a spreadsheet ID is set.

EOF
else
  cat <<EOF
Google OAuth setup was skipped.
To configure Gmail + Google Sheets later:
1) Create OAuth Desktop App credentials in Google Cloud Console.
2) Run:
   source .venv/bin/activate
   python scripts/google_oauth_bootstrap.py --client-secrets /path/to/client_secret.json
3) Copy values into ${ENV_FILE}, set GOOGLE_SHEETS_SPREADSHEET_ID, then:
   sudo systemctl restart ${SERVICE_NAME}

EOF
fi
