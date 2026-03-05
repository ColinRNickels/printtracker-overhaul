from pathlib import Path

from dotenv import load_dotenv
from flask import Flask, redirect, url_for
from sqlalchemy import event, inspect, text
from sqlalchemy.engine import Engine, make_url

from .extensions import db


@event.listens_for(Engine, "connect")
def _set_sqlite_wal(dbapi_connection, connection_record):
    """Enable WAL mode for SQLite for better concurrent read performance."""
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.close()


def _apply_schema_upgrades() -> None:
    inspector = inspect(db.engine)
    if "print_jobs" not in inspector.get_table_names():
        return

    existing_columns = {
        column["name"] for column in inspector.get_columns("print_jobs")
    }
    upgrade_statements = []

    if "department" not in existing_columns:
        upgrade_statements.append(
            "ALTER TABLE print_jobs ADD COLUMN department VARCHAR(120)"
        )
    if "pi_name" not in existing_columns:
        upgrade_statements.append(
            "ALTER TABLE print_jobs ADD COLUMN pi_name VARCHAR(120)"
        )
    if "location" not in existing_columns:
        upgrade_statements.append(
            "ALTER TABLE print_jobs ADD COLUMN location VARCHAR(120)"
        )

    if not upgrade_statements:
        return

    with db.engine.begin() as connection:
        for statement in upgrade_statements:
            connection.execute(text(statement))


def _normalize_sqlite_database_uri(*, base_dir: Path, uri: str) -> str:
    url = make_url(uri)
    if not url.drivername.startswith("sqlite"):
        return uri

    database = url.database
    if not database or database == ":memory:":
        return uri
    if database.startswith("file:"):
        return uri

    db_path = Path(database)
    if db_path.is_absolute():
        resolved_path = db_path
    else:
        resolved_path = (base_dir / db_path).resolve()

    resolved_path.parent.mkdir(parents=True, exist_ok=True)
    return url.set(database=str(resolved_path)).render_as_string(hide_password=False)


def _normalize_path_setting(*, base_dir: Path, value: str) -> str:
    path_value = (value or "").strip()
    if not path_value:
        return ""

    candidate = Path(path_value).expanduser()
    if not candidate.is_absolute():
        candidate = base_dir / candidate
    return str(candidate.resolve())


def create_app() -> Flask:
    # Load project .env regardless of how Flask is started (run.py or flask CLI).
    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
    from .config import Config

    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(Config)
    app.config["SQLALCHEMY_DATABASE_URI"] = _normalize_sqlite_database_uri(
        base_dir=Path(__file__).resolve().parent.parent,
        uri=app.config["SQLALCHEMY_DATABASE_URI"],
    )
    app.config["LABEL_OUTPUT_DIR"] = _normalize_path_setting(
        base_dir=Path(__file__).resolve().parent.parent,
        value=app.config["LABEL_OUTPUT_DIR"],
    )
    app.config["LABEL_BRAND_LOGO_PATH"] = _normalize_path_setting(
        base_dir=Path(__file__).resolve().parent.parent,
        value=app.config["LABEL_BRAND_LOGO_PATH"],
    )

    Path(app.instance_path).mkdir(parents=True, exist_ok=True)
    Path(app.config["LABEL_OUTPUT_DIR"]).mkdir(parents=True, exist_ok=True)

    db.init_app(app)

    from . import models  # noqa: F401
    from .routes.kiosk import bp as kiosk_bp
    from .routes.reports import bp as reports_bp
    from .routes.staff import bp as staff_bp

    # Ensure first-run kiosk instances don't fail on missing tables.
    with app.app_context():
        db.create_all()
        _apply_schema_upgrades()

    app.register_blueprint(kiosk_bp)
    app.register_blueprint(staff_bp)
    app.register_blueprint(reports_bp)

    @app.route("/")
    def index():
        return redirect(url_for("kiosk.register"))

    @app.cli.command("init-db")
    def init_db_command():
        db.create_all()
        _apply_schema_upgrades()
        print("Database initialized.")

    return app
