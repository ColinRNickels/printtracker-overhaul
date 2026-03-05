# Print Tracker (Makerspace Kiosk)

Print Tracker is a Flask app for a shared 3D-print makerspace workflow:

- Patron starts a print and creates a label at a kiosk.
- Label includes a unique Print ID (`PT-YYYYMMDD-HHMMSS-##`) and QR code.
- Staff scans QR/ID to mark `Finished` or `Failed`.
- Patron can receive completion/failure email.
- Monthly reports, charts, CSV export, and optional Google Sheets sync.

The data model is intentionally flat (spreadsheet-friendly) so you can move data between SQLite, CSV, and Google Sheets with minimal friction.

## 1) What’s Implemented

### Kiosk

- `/kiosk/register` form collects:
  - first name
  - last name
  - NCSU email local part (`@ncsu.edu` appended)
  - file name
  - project type (`Personal`, `Academic`, `Research`)
  - `Academic` adds required `Course #` + `Instructor`
  - `Research` adds required `Department` + `PI`
- Kiosk UI uses large-touch sizing for readability.
- Submit button is labeled **Print Label**.
- Success page says: **“Label is printing, please see staff if it doesn't print.”**
- Success page auto-returns to kiosk start in 10 seconds.

### Labels

- Brother DK-1202 oriented landscape by default.
- Human-readable layout prioritized:
  - “PRINT IN PROGRESS”
  - name as `Last, First`
  - file name + project type + optional course/instructor/department/pi
  - small QR at bottom-right (default `0.5in`).
- Optional logo rendering from `LABEL_BRAND_LOGO_PATH`.
- Label files can be saved for reprint, with daily retention cleanup.

### Staff

- `/staff` is password protected (`STAFF_PASSWORD`).
- Staff dashboard includes:
  - scan/open by QR or Print ID
  - mark finished/failed
  - failure notes required for failed jobs
  - reprint buttons (in-progress + recent completed)
  - runtime toggles for email, label save, retention days, QR payload mode
- Staff login auto-returns to kiosk after 15s **except** when login was opened from QR completion links (`/staff/s/...` or `/staff/complete/...`).
- Kiosk header hides Reports nav to reduce accidental navigation.

### Notifications + Cloud

- Email providers:
  - SMTP (`EMAIL_PROVIDER=smtp`)
  - Gmail API (`EMAIL_PROVIDER=gmail_api`)
  - auto-fallback (`EMAIL_PROVIDER=auto`)
- Google Sheets sync on register + completion when enabled.
- OAuth helper script available (`scripts/google_oauth_bootstrap.py`).

### Reports

- `/reports/monthly` supports month picker and CSV export.
- Charts included:
  - prints per month trend (12 months)
  - project type pie chart
  - research department chart
  - status pie chart
- CSV includes flat fields for course/research details.

## 2) Quick Local Start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
flask --app run.py init-db
python run.py
```

Open:

- Kiosk: `http://localhost:5000/kiosk/register`
- Staff: `http://localhost:5000/staff/`
- Reports: `http://localhost:5000/reports/monthly`

If port 5000 is busy:

```bash
PORT=5050 python run.py
```

## 3) Raspberry Pi Deploy (Fresh Image)

### 3.1 One-time setup

Use Raspberry Pi OS Desktop.

```bash
sudo apt update
sudo apt install -y git

sudo mkdir -p /opt/print-tracker
sudo chown -R "$USER:$USER" /opt/print-tracker
cd /opt/print-tracker

git clone <YOUR_REPO_URL> .
chmod +x scripts/deploy_rpi.sh
./scripts/deploy_rpi.sh
```

### 3.2 What deploy script does

`scripts/deploy_rpi.sh` automates:

- apt packages (`cups`, `printer-driver-ptouch`, `network-manager`, browser package, etc.)
- virtualenv + dependencies
- `.env` creation/update
- DB init (`flask --app run.py init-db`)
- systemd service (`print-tracker`)
- optional AP setup (default ON)
- optional Chromium kiosk autostart (default ON)
- optional Google OAuth setup prompt (default ON)

Browser package is auto-detected (`chromium` first, then `chromium-browser`).

### 3.3 Script prompts (interactive)

You will be asked for:

1. service user/group
2. port
3. print mode (`cups` or `mock`)
4. queue name
5. CUPS media token
6. AP options (`printerkiosk` defaults)
7. Chromium kiosk autostart
8. Google OAuth setup inputs

### 3.4 Brother QL-800 setup (CUPS)

Printer queue still needs manual CUPS add:

1. Plug in QL-800 via USB.
2. Open `http://localhost:631`.
3. `Administration` -> `Add Printer`.
4. Select Brother device and driver.
5. Use queue name matching `.env` (default `QL800`).

Verify:

```bash
lpstat -e
lpstat -p -d
lpoptions -p QL800 -l | grep -Ei 'media|PageSize'
lp -d QL800 /usr/share/cups/data/testprint
```

### 3.5 AP setup for staff phone/iPad scanning

If AP setup is enabled (default):

- SSID default: `printerkiosk`
- Password default: `printerkiosk`
- Pi AP IP: `192.168.4.1`

Staff flow:

1. Join Wi-Fi `printerkiosk`.
2. Open `http://192.168.4.1:5000/staff/`.
3. Log in once.
4. Scan label QR from phone/tablet.

When ready to hide SSID later:

```bash
./scripts/deploy_rpi.sh --ap-hidden
```

### 3.6 Kiosk browser autostart on reboot

When enabled (default), deploy creates autostart files so Chromium launches:

- fullscreen kiosk mode
- incognito
- URL: `http://127.0.0.1:<PORT>/kiosk/register`

Requires desktop autologin (script attempts `raspi-config nonint do_boot_behaviour B4`).

### 3.7 Deploy script examples

```bash
./scripts/deploy_rpi.sh --non-interactive
./scripts/deploy_rpi.sh --print-mode mock
./scripts/deploy_rpi.sh --no-ap --no-kiosk-autostart
./scripts/deploy_rpi.sh --ap-ssid printerkiosk --ap-password 'change-this-password'
./scripts/deploy_rpi.sh --setup-google-oauth --google-client-secrets ~/Downloads/client_secret.json --google-gmail-sender makerspace@example.com --google-spreadsheet-id <SHEET_ID>
./scripts/deploy_rpi.sh --no-google-oauth
```

## 4) Google OAuth (Gmail + Sheets)

The deploy script can run OAuth setup directly.

If skipped, run manually:

1. In Google Cloud Console:
   - create/select project
   - enable **Gmail API** and **Google Sheets API**
   - configure OAuth consent screen
   - create OAuth Client ID (`Desktop app`) and download client JSON
2. On Pi:

```bash
cd /opt/print-tracker
source .venv/bin/activate
python scripts/google_oauth_bootstrap.py \
  --client-secrets /path/to/client_secret.json \
  --gmail-sender makerspace@example.com
```

3. Copy printed values into `.env`.
4. Set `GOOGLE_SHEETS_SPREADSHEET_ID`.
5. Set `GOOGLE_SHEETS_SYNC_ENABLED=true` once sheet ID is set.
6. Restart:

```bash
sudo systemctl restart print-tracker
```

## 5) Key URLs

- `/kiosk/register`: kiosk print registration
- `/staff/`: staff dashboard (password)
- `/staff/s/<LABEL_CODE>`: QR-friendly staff shortcut
- `/staff/complete/<LABEL_CODE>`: completion form
- `/reports/monthly`: report + charts
- `/reports/monthly.csv`: CSV export

## 6) Configuration Reference (`.env`)

Core:

- `DATABASE_URL`
- `STAFF_PASSWORD`
- `DEFAULT_PRINTER_NAME`

Label + printing:

- `LABEL_PRINT_MODE` (`mock`/`cups`)
- `LABEL_PRINTER_QUEUE`
- `LABEL_OUTPUT_DIR`
- `LABEL_STOCK` (`DK1202`)
- `LABEL_DPI` (`300`)
- `LABEL_ORIENTATION` (`landscape`/`portrait`)
- `LABEL_QR_PAYLOAD_MODE` (`url`/`id`)
- `LABEL_QR_SIZE_INCH` (default `0.5`)
- `LABEL_CUPS_MEDIA`
- `LABEL_CUPS_EXTRA_OPTIONS`
- `LABEL_SAVE_LABEL_FILES` (base default)
- `LABEL_BRAND_TEXT`
- `LABEL_BRAND_LOGO_PATH`
- `KIOSK_BASE_URL` (important for mobile QR links)

Email:

- `EMAIL_PROVIDER` (`smtp`, `gmail_api`, `auto`)
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_USE_TLS`, `SMTP_FROM_ADDRESS`

Google OAuth + Sheets:

- `GOOGLE_OAUTH_CLIENT_ID`
- `GOOGLE_OAUTH_CLIENT_SECRET`
- `GOOGLE_OAUTH_REFRESH_TOKEN`
- `GOOGLE_OAUTH_TOKEN_URI`
- `GOOGLE_GMAIL_SENDER`
- `GOOGLE_SHEETS_SYNC_ENABLED`
- `GOOGLE_SHEETS_SPREADSHEET_ID`
- `GOOGLE_SHEETS_WORKSHEET`

## 7) Staff Runtime Settings

Staff dashboard settings apply immediately and are stored in DB (`app_settings`):

- completion email enabled/disabled
- save label files enabled/disabled
- label retention days (1-30)
- QR payload mode (`url` for camera scanning, `id` for USB scanner wedge)

With retention set to `1`, cleanup removes labels from yesterday and older.

## 8) Reports and Exports

Monthly CSV fields:

- `PrintID`
- `CreatedAt`
- `CompletedAt`
- `Status`
- `ProjectType`
- `FileName`
- `UserName`
- `UserEmail`
- `CourseNumber`
- `Instructor`
- `Department`
- `PI`
- `CompletedBy`

Google Sheets sync writes an expanded row (status labels, email fields, printer name, notes).

## 9) Troubleshooting

### `chromium-browser has no installation candidate`

Deploy script now auto-detects package names. Pull latest code and rerun deploy.

### `Text file busy` or weird `.venv/bin/python` errors

Corrupted or in-use virtualenv. Script now validates venv and rebuilds automatically.

Manual fix:

```bash
sudo systemctl stop print-tracker || true
rm -rf .venv
./scripts/deploy_rpi.sh
```

### `sqlite3.OperationalError: unable to open database file`

- Use absolute `DATABASE_URL`.
- Ensure service user can write to DB directory.

### Label preview 404

If label saving is disabled in staff settings, preview file is intentionally unavailable.

### Mobile QR scan opens wrong/unreachable URL

- Ensure `KIOSK_BASE_URL` is reachable from staff phone/tablet network.
- Use QR mode `url` on staff settings.

### First staff login after QR scan did not return correctly

Fixed in current code by safer `next` URL handling + login timeout bypass for QR completion routes.

### Google Sheets sync fails

- Confirm spreadsheet ID and worksheet name.
- Confirm OAuth account has edit access.
- Check logs: `journalctl -u print-tracker -f`

## 10) Useful Ops Commands

```bash
sudo systemctl status print-tracker --no-pager
sudo systemctl restart print-tracker
journalctl -u print-tracker -f
```

