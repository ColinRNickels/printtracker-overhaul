#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

SERVICE_NAME="print-tracker"
SERVICE_USER="${SUDO_USER:-${USER}}"
SERVICE_GROUP="$(id -gn "${SERVICE_USER}" 2>/dev/null || echo "${SERVICE_USER}")"
PORT="5000"
PRINT_MODE="cups"
PRINTER_QUEUE="QL800"
LABEL_MEDIA="DK-1202"
SETUP_AP=1
AP_SSID="printerkiosk"
AP_PSK="printerkiosk"
AP_HIDDEN=0
AP_IP="192.168.4.1"
KIOSK_AUTOSTART=1
LOGO_SOURCE=""
NON_INTERACTIVE=0
SKIP_APT=0
SKIP_SERVICE=0
SKIP_CUPS=0
SKIP_DB_INIT=0
SETUP_GOOGLE_OAUTH=-1
GOOGLE_CLIENT_SECRETS=""
GOOGLE_GMAIL_SENDER=""
GOOGLE_SPREADSHEET_ID=""
GOOGLE_WORKSHEET="PrintJobs"

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
  --printer-queue NAME     CUPS queue name (default: QL800).
  --media NAME             CUPS media token (default: DK-1202).
  --ap-ssid SSID           Wi-Fi AP SSID for staff mobile scanning (default: printerkiosk).
  --ap-password PASS       Wi-Fi AP passphrase (default: printerkiosk).
  --ap-hidden              Hide AP SSID broadcast.
  --no-ap                  Skip AP setup.
  --no-kiosk-autostart     Skip Chromium kiosk autostart setup.
  --setup-google-oauth     Run Google OAuth setup during deploy.
  --no-google-oauth        Skip Google OAuth setup during deploy.
  --google-client-secrets PATH
                           Path to OAuth client JSON from Google Cloud.
  --google-gmail-sender EMAIL
                           Sender email for Gmail API (optional).
  --google-spreadsheet-id ID
                           Spreadsheet ID for Google Sheets sync (optional).
  --google-worksheet NAME  Worksheet tab name (default: PrintJobs).
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

detect_wifi_interface() {
  local iface=""
  if command -v iw >/dev/null 2>&1; then
    iface="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')"
  fi
  if [[ -z "${iface}" ]]; then
    iface="wlan0"
  fi
  printf '%s' "${iface}"
}

detect_chromium_package() {
  local pkg=""
  for pkg in chromium chromium-browser; do
    if apt-cache show "${pkg}" >/dev/null 2>&1; then
      printf '%s' "${pkg}"
      return 0
    fi
  done
  return 1
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
  (cd "${app_dir}" && "${oauth_cmd[@]}") | tee "${output_file}"

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

setup_access_point() {
  local iface="$1"
  local hidden_flag="no"
  if [[ "${AP_HIDDEN}" -eq 1 ]]; then
    hidden_flag="yes"
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli not found. AP setup skipped."
    return 1
  fi

  log "Configuring Wi-Fi access point '${AP_SSID}' on ${iface}..."
  run_root systemctl enable --now NetworkManager || true
  run_root nmcli radio wifi on || true

  if run_root nmcli connection show print-tracker-ap >/dev/null 2>&1; then
    run_root nmcli connection modify print-tracker-ap \
      connection.autoconnect yes \
      connection.interface-name "${iface}" \
      802-11-wireless.mode ap \
      802-11-wireless.band bg \
      802-11-wireless.ssid "${AP_SSID}" \
      802-11-wireless.hidden "${hidden_flag}" \
      802-11-wireless-security.key-mgmt wpa-psk \
      802-11-wireless-security.psk "${AP_PSK}" \
      ipv4.method shared \
      ipv4.addresses "${AP_IP}/24" \
      ipv6.method ignore
  else
    run_root nmcli connection add type wifi ifname "${iface}" con-name print-tracker-ap autoconnect yes ssid "${AP_SSID}"
    run_root nmcli connection modify print-tracker-ap \
      connection.autoconnect yes \
      connection.interface-name "${iface}" \
      802-11-wireless.mode ap \
      802-11-wireless.band bg \
      802-11-wireless.ssid "${AP_SSID}" \
      802-11-wireless.hidden "${hidden_flag}" \
      802-11-wireless-security.key-mgmt wpa-psk \
      802-11-wireless-security.psk "${AP_PSK}" \
      ipv4.method shared \
      ipv4.addresses "${AP_IP}/24" \
      ipv6.method ignore
  fi

  run_root nmcli connection up print-tracker-ap || warn "Could not bring up print-tracker-ap immediately."
  return 0
}

setup_kiosk_browser_autostart() {
  local service_user="$1"
  local kiosk_url="$2"
  local service_home=""
  service_home="$(getent passwd "${service_user}" | cut -d: -f6 || true)"
  if [[ -z "${service_home}" ]]; then
    warn "Could not resolve home directory for ${service_user}; kiosk browser autostart skipped."
    return 1
  fi

  local launcher_dir="${service_home}/.local/bin"
  local launcher_script="${launcher_dir}/print-tracker-kiosk-browser.sh"
  local autostart_dir="${service_home}/.config/autostart"
  local autostart_file="${autostart_dir}/print-tracker-kiosk.desktop"

  run_root mkdir -p "${launcher_dir}" "${autostart_dir}"
  run_root tee "${launcher_script}" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

KIOSK_URL="\${1:-${kiosk_url}}"
sleep 8

BROWSER=""
for candidate in chromium-browser chromium; do
  if command -v "\${candidate}" >/dev/null 2>&1; then
    BROWSER="\${candidate}"
    break
  fi
done

if [[ -z "\${BROWSER}" ]]; then
  exit 1
fi

exec "\${BROWSER}" \
  --incognito \
  --kiosk \
  --no-first-run \
  --disable-restore-session-state \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --overscroll-history-navigation=0 \
  "\${KIOSK_URL}"
EOF
  run_root chmod +x "${launcher_script}"

  run_root tee "${autostart_file}" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Print Tracker Kiosk
Comment=Launch Print Tracker kiosk in Chromium
Exec=${launcher_script} ${kiosk_url}
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF

  run_root chown -R "${service_user}:${SERVICE_GROUP}" "${service_home}/.local" "${service_home}/.config/autostart"

  if command -v raspi-config >/dev/null 2>&1; then
    run_root raspi-config nonint do_boot_behaviour B4 || warn "Could not set desktop autologin via raspi-config."
  fi

  return 0
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
    --printer-queue)
      PRINTER_QUEUE="$2"
      shift 2
      ;;
    --media)
      LABEL_MEDIA="$2"
      shift 2
      ;;
    --ap-ssid)
      AP_SSID="$2"
      shift 2
      ;;
    --ap-password)
      AP_PSK="$2"
      shift 2
      ;;
    --ap-hidden)
      AP_HIDDEN=1
      shift
      ;;
    --no-ap)
      SETUP_AP=0
      shift
      ;;
    --no-kiosk-autostart)
      KIOSK_AUTOSTART=0
      shift
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

[[ -f "${PROJECT_DIR}/requirements.txt" ]] || die "Run this script from inside the project repository."
[[ "${PRINT_MODE}" == "cups" || "${PRINT_MODE}" == "mock" ]] || die "--print-mode must be cups or mock."

if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
  log "Interactive setup. Press Enter to accept defaults."
  SERVICE_USER="$(prompt_default "Service user" "${SERVICE_USER}")"
  SERVICE_GROUP="$(prompt_default "Service group" "${SERVICE_GROUP}")"
  PORT="$(prompt_default "Web app port" "${PORT}")"
  PRINT_MODE="$(prompt_default "Print mode (cups or mock)" "${PRINT_MODE}")"
  PRINTER_QUEUE="$(prompt_default "CUPS queue name" "${PRINTER_QUEUE}")"
  LABEL_MEDIA="$(prompt_default "CUPS media token" "${LABEL_MEDIA}")"
  if prompt_yes_no "Set up a staff-only Wi-Fi access point for QR scanning" "y"; then
    SETUP_AP=1
    AP_SSID="$(prompt_default "AP SSID" "${AP_SSID}")"
    AP_PSK="$(prompt_default "AP password (8+ characters)" "${AP_PSK}")"
    if prompt_yes_no "Hide AP SSID broadcast now" "n"; then
      AP_HIDDEN=1
    else
      AP_HIDDEN=0
    fi
  else
    SETUP_AP=0
  fi
  if prompt_yes_no "Auto-launch Chromium in fullscreen kiosk mode on reboot" "y"; then
    KIOSK_AUTOSTART=1
  else
    KIOSK_AUTOSTART=0
  fi
  if [[ "${SETUP_GOOGLE_OAUTH}" -lt 0 ]]; then
    if prompt_yes_no "Configure Google OAuth now (Gmail + Sheets)" "y"; then
      SETUP_GOOGLE_OAUTH=1
      GOOGLE_CLIENT_SECRETS="$(prompt_default "Path to Google OAuth client JSON" "${HOME}/Downloads/client_secret.json")"
      GOOGLE_GMAIL_SENDER="$(prompt_default "Gmail sender address (optional)" "${GOOGLE_GMAIL_SENDER}")"
      GOOGLE_SPREADSHEET_ID="$(prompt_default "Google Spreadsheet ID (optional now)" "${GOOGLE_SPREADSHEET_ID}")"
      GOOGLE_WORKSHEET="$(prompt_default "Google worksheet tab" "${GOOGLE_WORKSHEET}")"
    else
      SETUP_GOOGLE_OAUTH=0
    fi
  fi
fi

[[ "${PRINT_MODE}" == "cups" || "${PRINT_MODE}" == "mock" ]] || die "Print mode must be cups or mock."
[[ "${PORT}" =~ ^[0-9]+$ ]] || die "Port must be a number."
if [[ "${SETUP_AP}" -eq 1 ]]; then
  [[ -n "${AP_SSID}" ]] || die "AP SSID cannot be empty."
  (( ${#AP_PSK} >= 8 )) || die "AP password must be at least 8 characters."
fi
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
if [[ "${SETUP_AP}" -eq 1 ]]; then
  KIOSK_BASE_URL="http://${AP_IP}:${PORT}"
else
  KIOSK_BASE_URL="http://${HOST_IP}:${PORT}"
fi
LOCAL_KIOSK_URL="http://127.0.0.1:${PORT}/kiosk/register"

SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"

log "Project directory: ${APP_DIR}"
log "Service user/group: ${SERVICE_USER}:${SERVICE_GROUP}"
log "Kiosk URL base (for QR links): ${KIOSK_BASE_URL}"
log "Local kiosk launch URL (Chromium autostart): ${LOCAL_KIOSK_URL}"

if [[ "${SKIP_APT}" -eq 0 ]]; then
  log "Installing system packages (this can take several minutes)..."
  run_root apt-get update
  APT_PACKAGES=(
    git
    python3-venv python3-pip python3-dev build-essential
    cups cups-client cups-bsd
    printer-driver-ptouch
    network-manager
    iw
    avahi-daemon
    usbutils
  )
  CHROMIUM_PKG="$(detect_chromium_package || true)"
  if [[ -n "${CHROMIUM_PKG}" ]]; then
    log "Using browser package: ${CHROMIUM_PKG}"
    APT_PACKAGES+=("${CHROMIUM_PKG}")
  else
    warn "No Chromium package candidate found (tried: chromium, chromium-browser). Install a Chromium browser package manually."
  fi
  run_root apt-get install -y "${APT_PACKAGES[@]}"
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
set_env_value "${ENV_FILE}" "DEFAULT_PRINTER_NAME" "Makerspace"

EXISTING_STAFF_PASSWORD="$(get_env_value "${ENV_FILE}" "STAFF_PASSWORD")"
if [[ -z "${EXISTING_STAFF_PASSWORD}" ]]; then
  set_env_value "${ENV_FILE}" "STAFF_PASSWORD" "staffpw"
fi

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

AP_CONFIGURED=0
WIFI_IFACE=""
if [[ "${SETUP_AP}" -eq 1 ]]; then
  WIFI_IFACE="$(detect_wifi_interface)"
  if setup_access_point "${WIFI_IFACE}"; then
    AP_CONFIGURED=1
  else
    warn "AP setup failed. You can rerun script after fixing NetworkManager."
  fi
else
  warn "Skipping AP setup (--no-ap)."
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

KIOSK_AUTOSTART_CONFIGURED=0
if [[ "${KIOSK_AUTOSTART}" -eq 1 ]]; then
  if setup_kiosk_browser_autostart "${SERVICE_USER}" "${LOCAL_KIOSK_URL}"; then
    KIOSK_AUTOSTART_CONFIGURED=1
  else
    warn "Chromium kiosk autostart setup failed."
  fi
else
  warn "Skipping Chromium kiosk autostart (--no-kiosk-autostart)."
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
- Change STAFF_PASSWORD in ${ENV_FILE} from default "staffpw", then restart the service.
- Confirm KIOSK_BASE_URL in ${ENV_FILE} is reachable from staff devices for QR scans.

EOF

if [[ "${AP_CONFIGURED}" -eq 1 ]]; then
  cat <<EOF
Staff access-point network is ready:
- SSID: ${AP_SSID}
- Password: ${AP_PSK}
- Broadcast: $( [[ "${AP_HIDDEN}" -eq 1 ]] && printf 'hidden' || printf 'visible' )
- Pi AP IP: ${AP_IP}
- Staff URL after joining Wi-Fi: http://${AP_IP}:${PORT}/staff/

How staff should connect:
1) On iPad/iPhone, open Wi-Fi settings.
2) Join "${AP_SSID}" using the password above.
3) Open Safari and visit http://${AP_IP}:${PORT}/staff/
4) Log in once with staff password, then scan label QR codes.

EOF
fi

if [[ "${KIOSK_AUTOSTART_CONFIGURED}" -eq 1 ]]; then
  cat <<EOF
Browser kiosk autostart is enabled:
- On reboot + desktop auto-login, Chromium launches fullscreen incognito to:
  ${LOCAL_KIOSK_URL}

EOF
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
