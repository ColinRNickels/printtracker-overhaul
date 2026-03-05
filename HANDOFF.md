# Print Tracker Handoff

## Snapshot

- Date: 2025-07-25
- Repo: `/Users/crnickel/Dev/Print Tracker`
- Branch: current working branch with uncommitted local changes
- Python: 3.12+ with venv at `.venv/`

## Product Summary

Flask-based 3D-print tracking system for NC State University Libraries
makerspaces (Makerspace and Maker Studio). Phone-first design — patrons
register prints on their own phones via a QR code poster, and staff
complete jobs by scanning the label QR from their phones.

Data lives in SQLite (fast local operations, WAL mode) with Google Sheets
as the durable external record. Email notifications go through the Gmail
API. A Cloudflare Tunnel provides public HTTPS so students on campus Wi-Fi
can reach the Pi without IT involvement.

## Architecture

### MVP: Pi-only with Cloudflare Tunnel

```
Student phone (campus Wi-Fi)
        │  HTTPS
        ▼
┌──────────────────────────────┐
│  Cloudflare Tunnel (free)    │
│  stable public URL           │
└──────────┬───────────────────┘
           │  localhost:5000
           ▼
┌──────────────────────────┐
│  Raspberry Pi            │
│  Flask + gunicorn        │
│  SQLite (WAL mode)       │
│  CUPS → Brother QL-800   │
│  Gmail API + Sheets sync │
└──────────────────────────┘
```

Each makerspace location runs its own Pi + tunnel. The campus network has
client isolation enabled, so direct Pi-to-phone routing is not possible
without the tunnel.

### Future: server + Pi print relays

Flask app moves to a university server. Each Pi becomes a lightweight
print agent that polls the server for pending labels. A `location` field
is added to the model and a location picker to the registration form. One
instance, one URL, one Google Sheet for all locations.

## App Structure

### Startup

- `run.py` → `create_app()` in `print_tracker/__init__.py`
- Loads `.env`, normalizes paths, creates DB + schema upgrades
- SQLite WAL mode enabled on every connection via `engine.connect()` event

### Data model (`print_tracker/models.py`)

- `PrintJob` — label code, patron info, file name, category, status,
  completion metadata, email tracking, `location` column
- `AppSetting` — runtime key/value toggles (email, label saving, etc.)
- All datetime columns use timezone-aware UTC (`datetime.now(timezone.utc)`)

### Routes

| Blueprint | Prefix | File | Purpose |
|-----------|--------|------|---------|
| `kiosk` | `/kiosk` | `routes/kiosk.py` | Registration form, QR images, label preview |
| `staff` | `/staff` | `routes/staff.py` | Login, dashboard, scan, completion, reprint, settings |
| `reports` | `/reports` | `routes/reports.py` | Monthly report page + CSV export |

### Services

| Module | Purpose |
|--------|---------|
| `label_printer.py` | PIL label rendering + CUPS print submission |
| `runtime_settings.py` | Read/write `AppSetting` toggles |
| `notifier.py` | Email via Gmail API / SMTP / auto-fallback |
| `google_api.py` | OAuth refresh-token Google API client builder |
| `sheets_sync.py` | Append/update rows in Google Sheets (includes Location column) |
| `reports.py` | Report summaries + Chart.js datasets |
| `qr_links.py` | Build staff completion URLs for QR codes |

### Templates

| File | Surface |
|------|---------|
| `base.html` | Shared layout — nav hidden on kiosk routes on phone |
| `kiosk_register.html` | Patron registration form (phone portrait) |
| `kiosk_success.html` | Post-registration success + label preview |
| `staff_login.html` | Password gate |
| `staff_dashboard.html` | In-progress + completed tables, settings |
| `staff_complete.html` | Mark job Finished / Failed |
| `reports_monthly.html` | Charts + tables with CSV export |
| `email_success.txt` / `email_failure.txt` | Notification templates |

### CSS (`print_tracker/static/app.css`)

Mobile-first responsive design:
- Base styles = phone portrait (single-column, 48px+ touch targets)
- `@media (min-width: 768px)` = laptop (two-column grids, three-column
  type cards, 12-column chart grid)

## Config (`print_tracker/config.py`)

All configuration is via environment variables loaded from `.env`. Key
additions:

| Variable | Default | Notes |
|----------|---------|-------|
| `DEFAULT_PRINTER_NAME` | `Makerspace` | Also used as the Location value in Sheets |
| `KIOSK_BASE_URL` | `http://localhost:5000` | Set to tunnel URL for QR codes |
| `LABEL_PRINT_MODE` | `mock` | `mock` or `cups` |

Full reference in `README.md` §7.

## Google Sheets Sync

- Sync on both registration and completion
- Headers (21 columns): PrintID, CreatedAt, CompletedAt, Status,
  StatusLabel, ProjectType, ProjectTypeLabel, FileName, UserName,
  UserEmail, CourseNumber, Instructor, Department, PI, CompletedBy,
  CompletionNotes, EmailStatus, EmailError, EmailSentAt, PrinterName,
  **Location**
- Location value comes from `DEFAULT_PRINTER_NAME` config
- Sheet and headers are created automatically on first sync

## Deploy

### Pi deploy

```bash
./scripts/deploy_rpi.sh
```

See `README.md` §3 for full instructions.

### Cloudflare Tunnel

```bash
# Quick test (temporary URL):
cloudflared tunnel --url http://localhost:5000

# Permanent (free account):
cloudflared tunnel login
cloudflared tunnel create print-tracker
# → configure ~/.cloudflared/config.yml
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

See `README.md` §4 for the complete walkthrough.

### Google OAuth bootstrap

Run on a machine with a browser (laptop recommended):

```bash
python scripts/google_oauth_bootstrap.py \
  --client-secrets ~/Downloads/client_secret.json \
  --gmail-sender makerspace@ncsu.edu
```

Copy the printed env values into the Pi's `.env`.

## Recently Implemented Changes

1. **Phone-first architecture**
   - Cloudflare Tunnel for public HTTPS access from campus Wi-Fi
   - Responsive mobile-first CSS (phone portrait + laptop landscape)
   - Viewport meta with `viewport-fit=cover` for notched phones
   - Nav hidden on kiosk routes in phone view
   - Tables wrapped in `.table-wrap` for horizontal scroll on phones

2. **Multi-location support**
   - `DEFAULT_PRINTER_NAME` config doubles as the location name
   - `Location` column in Google Sheets headers and row data
   - `location` column on `PrintJob` model (populated from config)
   - MVP: separate Pi per location; future: location picker

3. **SQLite WAL mode**
   - Enabled on every connection via SQLAlchemy event listener
   - Better concurrent read performance for staff + patron access

4. **Timezone-aware datetimes**
   - All `datetime.utcnow()` replaced with `datetime.now(timezone.utc)`
   - Column defaults, `mark_completed()`, email timestamps

5. **DRY label printing**
   - `build_label_kwargs(job)` helper extracts config + runtime settings
   - Shared between kiosk registration and staff reprint (was ~15
     duplicated keyword arguments)

6. **README rewrite**
   - Full deployment docs: Pi setup, Cloudflare Tunnel, Google OAuth
   - Architecture diagram and roadmap
   - Configuration reference tables
   - Troubleshooting guide

## Known Risks / Follow-up Ideas

- **No migration framework**: Schema upgrades are manual `ALTER TABLE` in
  `_apply_schema_upgrades()`. Consider Flask-Migrate when schema changes
  become frequent.
- **`STAFF_PASSWORD` plain text**: Acceptable for MVP. Move to hashed
  auth or SSO for hardening.
- **Credentials in shell history**: AP and OAuth values passed via CLI
  flags may end up in shell history.
- **Deploy script still has AP/kiosk options**: These work but are not
  needed for the phone-first workflow. Pass `--no-ap --no-kiosk-autostart`
  to skip.
- **Single-Pi reliability**: No redundancy. If the Pi dies, prints are
  tracked only in Google Sheets until a replacement is set up. Keep an
  SD card image backup.
- **OAuth token expiry**: Google refresh tokens can expire if unused for
  6 months or if the OAuth app is in "testing" mode (7-day expiry).
  Publish the app or use a Workspace account for long-lived tokens.

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
