#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="print-tracker-agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${PROJECT_DIR}/.env.pi-agent"
VENV_DIR="${PROJECT_DIR}/.venv"
SERVICE_USER="${SUDO_USER:-${USER}}"

SERVER_URL=""
SPACE_SLUG=""
AGENT_ID=""
BOOTSTRAP_KEY=""
PRINTER_QUEUE=""
DISPLAY_NAME=""
NON_INTERACTIVE=0

usage() {
  cat <<'EOF'
Usage: ./scripts/install_pi_agent.sh [options]

Options:
  --server-url URL         Server base URL, e.g. http://192.168.1.50:5000
  --space SPACE            Space slug, e.g. makerspace
  --agent-id ID            Unique agent ID for this Pi
  --bootstrap-key KEY      Bootstrap key from the server
  --printer-queue NAME     Local CUPS queue name
  --display-name NAME      Human-readable agent name
  --non-interactive        Fail instead of prompting for missing values
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url) SERVER_URL="$2"; shift 2 ;;
    --space) SPACE_SLUG="$2"; shift 2 ;;
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --bootstrap-key) BOOTSTRAP_KEY="$2"; shift 2 ;;
    --printer-queue) PRINTER_QUEUE="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

prompt_if_missing() {
  local var_name="$1"
  local prompt_text="$2"
  local current_value="${!var_name}"
  if [[ -n "${current_value}" ]]; then
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "Missing required value: ${var_name}" >&2
    exit 1
  fi
  read -r -p "${prompt_text}: " current_value
  if [[ -z "${current_value}" ]]; then
    echo "${var_name} cannot be empty" >&2
    exit 1
  fi
  printf -v "${var_name}" '%s' "${current_value}"
}

prompt_if_missing SERVER_URL "Server base URL"
prompt_if_missing SPACE_SLUG "Space slug"
prompt_if_missing AGENT_ID "Agent ID"
prompt_if_missing BOOTSTRAP_KEY "Agent bootstrap key"
prompt_if_missing PRINTER_QUEUE "CUPS printer queue"

if [[ -z "${DISPLAY_NAME}" ]]; then
  DISPLAY_NAME="${AGENT_ID}"
fi

python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install -r "${PROJECT_DIR}/requirements.txt"

cp -n "${PROJECT_DIR}/.env.pi-agent.example" "${ENV_FILE}" || true

python3 - "${ENV_FILE}" \
  SERVER_BASE_URL "${SERVER_URL}" \
  AGENT_SPACE_SLUG "${SPACE_SLUG}" \
  AGENT_ID "${AGENT_ID}" \
  AGENT_BOOTSTRAP_KEY "${BOOTSTRAP_KEY}" \
  AGENT_DISPLAY_NAME "${DISPLAY_NAME}" \
  LABEL_PRINTER_QUEUE "${PRINTER_QUEUE}" <<'PY'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
pairs = list(zip(sys.argv[2::2], sys.argv[3::2]))
lines = env_path.read_text().splitlines() if env_path.exists() else []
for key, value in pairs:
    needle = f"{key}="
    replaced = False
    for idx, line in enumerate(lines):
        if line.startswith(needle):
            lines[idx] = f"{key}={value}"
            replaced = True
            break
    if not replaced:
        lines.append(f"{key}={value}")
env_path.write_text("\n".join(lines).rstrip() + "\n")
PY

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
sudo tee "${SERVICE_FILE}" >/dev/null <<EOF
[Unit]
Description=Print Tracker Pi Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${PROJECT_DIR}
Environment=PI_AGENT_ENV_FILE=${ENV_FILE}
ExecStart=${VENV_DIR}/bin/python ${PROJECT_DIR}/scripts/pi_worker.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

echo "Pi agent installed."
echo "Environment: ${ENV_FILE}"
echo "Service: ${SERVICE_NAME}"