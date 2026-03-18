import os
from datetime import timedelta
from pathlib import Path

from werkzeug.security import generate_password_hash


BASE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_DB_PATH = BASE_DIR / "instance" / "print_tracker.db"
DEFAULT_LABEL_DIR = BASE_DIR / "labels"


def _env_flag(name: str, *, default: bool) -> bool:
    raw_value = os.environ.get(name)
    if raw_value is None:
        return default
    return raw_value.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(
    name: str,
    *,
    default: int,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    raw_value = os.environ.get(name)
    try:
        parsed = int(raw_value) if raw_value is not None else default
    except ValueError:
        parsed = default

    if minimum is not None:
        parsed = max(minimum, parsed)
    if maximum is not None:
        parsed = min(maximum, parsed)
    return parsed


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "change-me")
    HAS_EXPLICIT_SECRET_KEY = "SECRET_KEY" in os.environ
    RATELIMIT_STORAGE_URI = os.environ.get("RATELIMIT_STORAGE_URI", "memory://")
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{DEFAULT_DB_PATH}"
    )
    SQLALCHEMY_ENGINE_OPTIONS = {"pool_pre_ping": True}
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    STAFF_PASSWORD_HASH = generate_password_hash(
        os.environ.get("STAFF_PASSWORD", "staffpw")
    )
    HAS_EXPLICIT_STAFF_PASSWORD = "STAFF_PASSWORD" in os.environ

    # Label printing
    LABEL_PRINT_MODE = os.environ.get("LABEL_PRINT_MODE", "mock")  # mock | cups
    LABEL_PRINTER_QUEUE = os.environ.get("LABEL_PRINTER_QUEUE", "")
    LABEL_OUTPUT_DIR = os.environ.get("LABEL_OUTPUT_DIR", str(DEFAULT_LABEL_DIR))
    KIOSK_BASE_URL = os.environ.get("KIOSK_BASE_URL", "http://localhost:5000")
    LABEL_STOCK = os.environ.get("LABEL_STOCK", "DK1202")
    LABEL_DPI = int(os.environ.get("LABEL_DPI", "300"))
    LABEL_ORIENTATION = os.environ.get(
        "LABEL_ORIENTATION", "landscape"
    )  # landscape | portrait
    LABEL_QR_PAYLOAD_MODE = os.environ.get("LABEL_QR_PAYLOAD_MODE", "url")  # id | url
    LABEL_QR_SIZE_INCH = float(os.environ.get("LABEL_QR_SIZE_INCH", "1.0"))
    LABEL_BRAND_TEXT = os.environ.get(
        "LABEL_BRAND_TEXT",
        "NC State University Libraries Makerspace",
    )
    LABEL_BRAND_LOGO_PATH = os.environ.get("LABEL_BRAND_LOGO_PATH", "")
    LABEL_SIDE_ART_PATH = os.environ.get(
        "LABEL_SIDE_ART_PATH",
        str(BASE_DIR / "assets" / "noun-3d-printer-8112508.svg"),
    )
    LABEL_CUPS_MEDIA = os.environ.get("LABEL_CUPS_MEDIA", "62x100mm")
    LABEL_CUPS_EXTRA_OPTIONS = os.environ.get("LABEL_CUPS_EXTRA_OPTIONS", "")
    LABEL_SAVE_LABEL_FILES = os.environ.get(
        "LABEL_SAVE_LABEL_FILES", "true"
    ).lower() in {
        "1",
        "true",
        "yes",
    }

    # SMTP settings for completion notifications
    SMTP_HOST = os.environ.get("SMTP_HOST", "")
    SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
    SMTP_USERNAME = os.environ.get("SMTP_USERNAME", "")
    SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD", "")
    SMTP_USE_TLS = os.environ.get("SMTP_USE_TLS", "true").lower() in {
        "1",
        "true",
        "yes",
    }
    SMTP_FROM_ADDRESS = os.environ.get("SMTP_FROM_ADDRESS", "makerspace@example.com")
    EMAIL_PROVIDER = os.environ.get("EMAIL_PROVIDER", "smtp").strip().lower()

    # Google OAuth settings (shared by Gmail API + Google Sheets API)
    GOOGLE_OAUTH_CLIENT_ID = os.environ.get("GOOGLE_OAUTH_CLIENT_ID", "").strip()
    GOOGLE_OAUTH_CLIENT_SECRET = os.environ.get(
        "GOOGLE_OAUTH_CLIENT_SECRET", ""
    ).strip()
    GOOGLE_OAUTH_REFRESH_TOKEN = os.environ.get(
        "GOOGLE_OAUTH_REFRESH_TOKEN", ""
    ).strip()
    GOOGLE_OAUTH_TOKEN_URI = os.environ.get(
        "GOOGLE_OAUTH_TOKEN_URI",
        "https://oauth2.googleapis.com/token",
    ).strip()
    GOOGLE_GMAIL_SENDER = os.environ.get("GOOGLE_GMAIL_SENDER", "").strip()

    # Google Sheets sync settings
    GOOGLE_SHEETS_SYNC_ENABLED = os.environ.get(
        "GOOGLE_SHEETS_SYNC_ENABLED", "false"
    ).lower() in {
        "1",
        "true",
        "yes",
    }
    _raw_spreadsheet_id = os.environ.get(
        "GOOGLE_SHEETS_SPREADSHEET_ID",
        "",
    ).strip()
    # Accept a full Google Sheets URL and extract just the ID.
    if "/spreadsheets/d/" in _raw_spreadsheet_id:
        import re as _re

        _match = _re.search(r"/spreadsheets/d/([^/]+)", _raw_spreadsheet_id)
        GOOGLE_SHEETS_SPREADSHEET_ID = (
            _match.group(1) if _match else _raw_spreadsheet_id
        )
    else:
        GOOGLE_SHEETS_SPREADSHEET_ID = _raw_spreadsheet_id
    GOOGLE_SHEETS_WORKSHEET = os.environ.get(
        "GOOGLE_SHEETS_WORKSHEET", "PrintJobs"
    ).strip()

    DEFAULT_PRINTER_NAME = os.environ.get("DEFAULT_PRINTER_NAME", "Makerspace")
    SITE_ID = os.environ.get("SITE_ID", "").strip().upper()
    PRINT_TRACKER_SPACES = os.environ.get(
        "PRINT_TRACKER_SPACES",
        "makerspace|Makerspace|MK|Makerspace,maker-studio|Maker Studio|MS|Maker Studio",
    ).strip()
    WORKER_DISPATCH_ENABLED = _env_flag("WORKER_DISPATCH_ENABLED", default=False)
    AGENT_BOOTSTRAP_KEY = os.environ.get("AGENT_BOOTSTRAP_KEY", "").strip()
    AGENT_POLL_BATCH_SIZE = _env_int(
        "AGENT_POLL_BATCH_SIZE", default=5, minimum=1, maximum=25
    )
    WORKER_HEARTBEAT_STALE_SECONDS = _env_int(
        "WORKER_HEARTBEAT_STALE_SECONDS", default=90, minimum=15, maximum=3600
    )

    # Library hours enforcement
    # When True, patrons cannot submit jobs outside open hours (+ buffer).
    # Set to False to disable the check entirely (e.g. for local testing).
    LIBRARY_HOURS_ENFORCE = _env_flag("LIBRARY_HOURS_ENFORCE", default=True)
    # Match the API's library_short_name field (e.g. "hill" or "hunt").
    LIBRARY_HOURS_LIBRARY_SHORT_NAME = os.environ.get(
        "LIBRARY_HOURS_LIBRARY_SHORT_NAME", "hill"
    ).strip()
    # Match the API's service_short_name field (e.g. "makerspace" or "maker-studio").
    LIBRARY_HOURS_SERVICE_SHORT_NAME = os.environ.get(
        "LIBRARY_HOURS_SERVICE_SHORT_NAME", "makerspace"
    ).strip()
    # Minutes after closing time during which job submission is still allowed.
    LIBRARY_HOURS_POST_CLOSE_BUFFER_MINUTES = _env_int(
        "LIBRARY_HOURS_POST_CLOSE_BUFFER_MINUTES", default=10, minimum=0
    )

    # go.ncsu.edu short-link settings (updated on tunnel restart)
    GO_NCSU_API_TOKEN = os.environ.get("GO_NCSU_API_TOKEN", "").strip()
    GO_NCSU_LINK_SLUG = os.environ.get(
        "GO_NCSU_LINK_SLUG", "makerspace-print-label"
    ).strip()

    # Session cookie hardening
    SESSION_COOKIE_NAME = "print_tracker_session"
    SESSION_COOKIE_SECURE = _env_flag(
        "SESSION_COOKIE_SECURE",
        default=KIOSK_BASE_URL.startswith("https://"),
    )
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    PERMANENT_SESSION_LIFETIME = timedelta(
        hours=_env_int("STAFF_SESSION_HOURS", default=12, minimum=1, maximum=168)
    )
