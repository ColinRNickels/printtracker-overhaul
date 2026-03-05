# Print Tracker Handoff

## Snapshot

- Date: 2026-03-04
- Repo: `/Users/crnickel/Dev/Print Tracker`
- Branch: current working branch with uncommitted local changes
- Current dirty files (expected):
  - `README.md`
  - `print_tracker/routes/staff.py`
  - `print_tracker/static/app.css`
  - `print_tracker/templates/base.html`
  - `print_tracker/templates/staff_login.html`
  - `scripts/deploy_rpi.sh`

## Product Summary

Flask-based makerspace print tracker with three major surfaces:

1. **Kiosk** (`/kiosk/register`): patrons create print jobs and print labels.
2. **Staff** (`/staff/`): password-protected completion workflow + settings + reprint.
3. **Reports** (`/reports/monthly`): monthly metrics, charts, CSV export.

Data is SQLite via SQLAlchemy, intentionally flat for CSV and Google Sheets friendliness.

## Architecture Map

### App setup

- `run.py` bootstraps Flask app.
- `print_tracker/__init__.py`:
  - loads `.env`
  - normalizes SQLite and path settings
  - `db.create_all()` on startup
  - applies lightweight schema upgrades for added columns (`department`, `pi_name`)

### Data model

- `print_tracker/models.py`
  - `PrintJob` table (label code, patron/file/type data, status, completion metadata, email metadata)
  - `AppSetting` table for runtime toggles

### Routes

- `print_tracker/routes/kiosk.py`
  - register job
  - generate timestamp-sequence IDs (`PT-YYYYMMDD-HHMMSS-##`)
  - print label
  - show success page
- `print_tracker/routes/staff.py`
  - password gate via session
  - scan shortcut, completion page, reprint
  - runtime setting updates
  - QR login redirect safety handling
- `print_tracker/routes/reports.py`
  - monthly report page
  - monthly CSV export

### Services

- `print_tracker/services/label_printer.py`
  - label rendering (human-priority layout)
  - CUPS submit
  - optional saved label files + retention cleanup
- `print_tracker/services/runtime_settings.py`
  - runtime staff settings from `AppSetting`
- `print_tracker/services/notifier.py`
  - SMTP / Gmail API completion email
- `print_tracker/services/google_api.py`
  - OAuth refresh-token based Google API client construction
- `print_tracker/services/sheets_sync.py`
  - append/update job rows in Google Sheets
- `print_tracker/services/reports.py`
  - report summaries + chart datasets

## Deploy and Operations

### Primary deploy script

- `scripts/deploy_rpi.sh`
- Handles:
  - apt package install (auto-detects `chromium` vs `chromium-browser`)
  - virtualenv setup (now validates and rebuilds corrupted `.venv`)
  - `.env` writes
  - DB init
  - systemd service creation
  - AP configuration via NetworkManager (`printerkiosk` default)
  - Chromium kiosk autostart desktop entry
  - optional Google OAuth setup prompt

### Google OAuth helper

- `scripts/google_oauth_bootstrap.py`
- Gets refresh token for Gmail + Sheets and prints `.env` snippet.

## Recently Implemented Changes (Important)

1. **Kiosk readability increased**
   - Large font sizes and larger controls on `/kiosk/register`.
   - Portrait kiosk layout no longer locked to keyboard-focused reflow constraints.
   - File: `print_tracker/static/app.css`

2. **Staff QR first-login redirect hardening**
   - Added sanitization for `next` URL on login.
   - Login timeout auto-return disabled for QR-driven completion paths (`/staff/s/...`, `/staff/complete/...`).
   - Files:
     - `print_tracker/routes/staff.py`
     - `print_tracker/templates/staff_login.html`

3. **Kiosk nav simplification**
   - Reports link hidden when on kiosk routes.
   - File: `print_tracker/templates/base.html`

4. **Deploy script hardening and UX updates**
   - Chromium package detection fix.
   - Google OAuth setup prompt + env write integration.
   - Corrupted `.venv` detection and rebuild logic.
   - File: `scripts/deploy_rpi.sh`

5. **Docs refresh**
   - README rewritten to match current implementation.
   - File: `README.md`

## Known Risks / Follow-up Ideas

- **Credentials in shell history**: AP and OAuth values can end up in shell history if passed via CLI flags.
- **No migration framework**: schema upgrades are manual in app startup (`_apply_schema_upgrades`).
- **`STAFF_PASSWORD` plain text**: fine for MVP, but should move to hashed auth for production hardening.
- **AP mode assumptions**: script assumes NetworkManager AP flow works on target Pi image.

## Quick Validation Checklist

After pulling latest code:

1. `bash -n scripts/deploy_rpi.sh`
2. `source .venv/bin/activate && python -m compileall -q print_tracker`
3. Start app, verify:
   - kiosk form load
   - large text appearance
   - label print path
   - QR scan on phone -> login -> correct print completion page
   - staff settings save
   - reports charts render

## Suggested Next Agent First Steps

1. Run end-to-end test on real Pi hardware:
   - AP join from iPhone/iPad
   - QR scan/login/complete flow
   - physical Brother label print
2. Validate Google OAuth + Sheets write on Pi (real account).
3. Decide whether to commit current local changes as one deployment/UI/docs batch.
