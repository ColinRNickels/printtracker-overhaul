import os
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_DB_PATH = BASE_DIR / "instance" / "print_tracker.db"
DEFAULT_LABEL_DIR = BASE_DIR / "labels"


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "change-me")
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{DEFAULT_DB_PATH}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    STAFF_PASSWORD = os.environ.get("STAFF_PASSWORD", "staffpw")

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
    LABEL_QR_SIZE_INCH = float(os.environ.get("LABEL_QR_SIZE_INCH", "0.5"))
    LABEL_BRAND_TEXT = os.environ.get(
        "LABEL_BRAND_TEXT",
        "NC State University Libraries Makerspace",
    )
    LABEL_BRAND_LOGO_PATH = os.environ.get("LABEL_BRAND_LOGO_PATH", "")
    LABEL_CUPS_MEDIA = os.environ.get("LABEL_CUPS_MEDIA", "DK-1202")
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
    GOOGLE_SHEETS_SPREADSHEET_ID = os.environ.get(
        "GOOGLE_SHEETS_SPREADSHEET_ID",
        "1H0y3uRWZIUOXlwIJcKXujPLFAVzN3LjpZ9ACoJ2LNck",
    ).strip()
    GOOGLE_SHEETS_WORKSHEET = os.environ.get(
        "GOOGLE_SHEETS_WORKSHEET", "PrintJobs"
    ).strip()

    DEFAULT_PRINTER_NAME = os.environ.get("DEFAULT_PRINTER_NAME", "Makerspace")
    SITE_ID = os.environ.get("SITE_ID", "").strip().upper()

    # go.ncsu.edu short-link settings (updated on tunnel restart)
    GO_NCSU_API_TOKEN = os.environ.get("GO_NCSU_API_TOKEN", "").strip()
    GO_NCSU_LINK_SLUG = os.environ.get(
        "GO_NCSU_LINK_SLUG", "makerspace-print-label"
    ).strip()
