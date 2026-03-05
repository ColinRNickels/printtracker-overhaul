#!/usr/bin/env bash
# ----------------------------------------------------------------
# update_golink.sh — Update the go.ncsu.edu short link.
#
# Usage:
#   ./scripts/update_golink.sh              # uses current tunnel URL
#   ./scripts/update_golink.sh <URL>        # uses the provided URL
#
# If no argument is given, detects the current tunnel URL and
# prompts the user to confirm or enter a different one.
# ----------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"

# ----- Helper: read a key from .env ----- #
get_env_value() {
  local env_file="$1" key="$2"
  python3 - "${env_file}" "${key}" <<'PY'
from pathlib import Path
import sys
env_path = Path(sys.argv[1])
key = sys.argv[2]
if not env_path.exists():
    sys.exit(0)
for line in env_path.read_text().splitlines():
    if line.startswith(f"{key}="):
        print(line.split("=", 1)[1])
        break
PY
}

# ----- Load settings from .env ----- #
GO_NCSU_API_TOKEN="${GO_NCSU_API_TOKEN:-}"
GO_NCSU_LINK_SLUG="${GO_NCSU_LINK_SLUG:-}"

if [[ -z "${GO_NCSU_API_TOKEN}" && -f "${ENV_FILE}" ]]; then
  GO_NCSU_API_TOKEN="$(get_env_value "${ENV_FILE}" "GO_NCSU_API_TOKEN")"
fi
if [[ -z "${GO_NCSU_LINK_SLUG}" && -f "${ENV_FILE}" ]]; then
  GO_NCSU_LINK_SLUG="$(get_env_value "${ENV_FILE}" "GO_NCSU_LINK_SLUG")"
fi
GO_NCSU_LINK_SLUG="${GO_NCSU_LINK_SLUG:-makerspace-print-label}"

if [[ -z "${GO_NCSU_API_TOKEN}" ]]; then
  echo "ERROR: GO_NCSU_API_TOKEN is not set in ${ENV_FILE} or the environment." >&2
  exit 1
fi

# ----- Determine target URL ----- #
TARGET_URL="${1:-}"

if [[ -z "${TARGET_URL}" ]]; then
  # Try to auto-detect the current tunnel URL
  DETECTED_URL=""
  if [[ -x "${SCRIPT_DIR}/get_tunnel_url.sh" ]]; then
    DETECTED_URL="$("${SCRIPT_DIR}/get_tunnel_url.sh" 2>/dev/null || true)"
  fi

  if [[ -n "${DETECTED_URL}" ]]; then
    echo "Current tunnel URL: ${DETECTED_URL}"
    read -r -p "Press Enter to use this URL, or type a different one: " USER_INPUT
    if [[ -n "${USER_INPUT}" ]]; then
      TARGET_URL="${USER_INPUT}"
    else
      TARGET_URL="${DETECTED_URL}"
    fi
  else
    read -r -p "Could not detect tunnel URL. Enter the target URL: " TARGET_URL
    if [[ -z "${TARGET_URL}" ]]; then
      echo "No URL provided. Aborting." >&2
      exit 1
    fi
  fi
fi

# ----- PATCH the go.ncsu.edu link ----- #
GO_API_URL="https://go.ncsu.edu/api/v2/links/${GO_NCSU_LINK_SLUG}"

echo "Updating go.ncsu.edu/${GO_NCSU_LINK_SLUG} → ${TARGET_URL} ..."

HTTP_RESPONSE="$(curl --silent --write-out '\n%{http_code}' \
  --request PATCH \
  "${GO_API_URL}" \
  --header "Authorization: Bearer ${GO_NCSU_API_TOKEN}" \
  --header "Content-Type: application/json" \
  --header "Accept: application/json" \
  --data "{
    \"target_url\": \"${TARGET_URL}\",
    \"enabled\": true,
    \"exclude_from_status_check\": true
  }" 2>&1)"

HTTP_BODY="$(echo "${HTTP_RESPONSE}" | head -n -1)"
HTTP_CODE="$(echo "${HTTP_RESPONSE}" | tail -1)"

if [[ "${HTTP_CODE}" =~ ^2[0-9][0-9]$ ]]; then
  echo "Success (HTTP ${HTTP_CODE})."
else
  echo "Failed (HTTP ${HTTP_CODE})." >&2
  echo "${HTTP_BODY}" >&2
  exit 1
fi
