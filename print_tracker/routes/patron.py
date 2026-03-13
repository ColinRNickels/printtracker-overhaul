import io
import re
from datetime import datetime
from pathlib import Path

from flask import (
    Blueprint,
    abort,
    current_app,
    flash,
    render_template,
    request,
    send_file,
    session,
    url_for,
)

from ..extensions import db, limiter
from ..models import (
    JOB_CATEGORIES,
    JOB_CATEGORY_COURSE,
    JOB_CATEGORY_PERSONAL,
    JOB_CATEGORY_RESEARCH,
    PrintJob,
)
from ..services.label_printer import build_qr_image, create_and_print_label
from ..services.library_hours import check_is_open
from ..services.qr_links import build_staff_completion_url
from ..services.runtime_settings import get_operational_settings
from ..services.sheets_sync import sync_job_to_google_sheet

bp = Blueprint("patron", __name__, url_prefix="/patron")
NCSU_EMAIL_DOMAIN = "ncsu.edu"
CATEGORY_OPTIONS = [
    (JOB_CATEGORY_PERSONAL, "Personal"),
    (JOB_CATEGORY_COURSE, "Academic"),
    (JOB_CATEGORY_RESEARCH, "Research"),
]
UNITY_ID_PATTERN = re.compile(r"^[a-z0-9._+-]+$")


def build_label_kwargs(job) -> dict:
    """Build the keyword arguments for create_and_print_label.

    Shared between patron registration and staff reprint to avoid
    duplicating ~15 config/settings lookups.
    """
    operational_settings = get_operational_settings()
    completion_url = build_staff_completion_url(job.label_code)
    return dict(
        job=job,
        completion_url=completion_url,
        output_dir=current_app.config["LABEL_OUTPUT_DIR"],
        mode=current_app.config["LABEL_PRINT_MODE"],
        queue_name=current_app.config["LABEL_PRINTER_QUEUE"],
        stock=current_app.config["LABEL_STOCK"],
        dpi=current_app.config["LABEL_DPI"],
        qr_payload_mode=operational_settings["qr_payload_mode"],
        qr_size_inch=current_app.config["LABEL_QR_SIZE_INCH"],
        label_orientation=current_app.config["LABEL_ORIENTATION"],
        brand_text=current_app.config["LABEL_BRAND_TEXT"],
        brand_logo_path=current_app.config["LABEL_BRAND_LOGO_PATH"],
        cups_media=current_app.config["LABEL_CUPS_MEDIA"],
        cups_extra_options=current_app.config["LABEL_CUPS_EXTRA_OPTIONS"],
        save_label_files=operational_settings["save_label_files"],
        cleanup_keep_days=operational_settings["label_retention_days"],
    )


def _generate_label_code() -> str:
    # Format: <PREFIX>-MM-DD-YY-XXX
    # PREFIX defaults to "PT" but can be overridden via SITE_ID to avoid
    # collisions when multiple Pis sync to the same Google Sheet.
    # XXX is the sequential print number for that day.
    site_id = current_app.config.get("SITE_ID", "").strip().upper()
    prefix = site_id if site_id else "PT"
    date_part = datetime.now().strftime("%m-%d-%y")
    code_prefix = f"{prefix}-{date_part}-"
    existing = (
        PrintJob.query
        .filter(PrintJob.label_code.like(f"{code_prefix}%"))
        .all()
    )
    used_numbers = set()
    for job in existing:
        suffix = job.label_code[len(code_prefix):]
        try:
            used_numbers.add(int(suffix))
        except ValueError:
            continue
    sequence = 1
    while sequence in used_numbers:
        sequence += 1
    if sequence > 999:
        raise RuntimeError("Could not generate unique label code")
    return f"{code_prefix}{sequence:03d}"


def _normalize_ncsu_email(raw_value: str) -> str:
    value = raw_value.strip().lower()
    if not value:
        raise ValueError("Email is required.")
    if any(character.isspace() for character in value):
        raise ValueError("Enter a valid NCSU unity ID or email address.")

    # Accept full ncsu.edu addresses and strip the domain
    if "@" in value:
        local, domain = value.rsplit("@", 1)
        if domain != NCSU_EMAIL_DOMAIN:
            raise ValueError(f"Only @{NCSU_EMAIL_DOMAIN} addresses are accepted.")
        value = local
    if not value:
        raise ValueError("Email is required.")
    if not UNITY_ID_PATTERN.fullmatch(value):
        raise ValueError("Enter a valid NCSU unity ID or email address.")
    return f"{value}@{NCSU_EMAIL_DOMAIN}"


def _normalize_person_name(raw_value: str) -> str:
    return " ".join(raw_value.strip().split())


def _normalize_single_line(raw_value: str) -> str:
    return " ".join(raw_value.strip().split())


@bp.route("/register", methods=["GET", "POST"])
@limiter.limit("20/minute")
def register():
    form = {
        "file_name": "",
        "first_name": "",
        "last_name": "",
        "user_email_local": "",
        "category": "",
        "course_number": "",
        "instructor": "",
        "department": "",
        "pi_name": "",
    }

    # --- Library hours check ---
    # Staff who are already logged in may bypass the hours restriction so
    # they can assist patrons or register test prints outside open hours.
    staff_override = session.get("staff_authenticated", False)
    makerspace_is_open = True
    closed_message = ""
    if current_app.config.get("LIBRARY_HOURS_ENFORCE", True) and not staff_override:
        makerspace_is_open, closed_message = check_is_open(
            library_short_name=current_app.config["LIBRARY_HOURS_LIBRARY_SHORT_NAME"],
            service_short_name=current_app.config["LIBRARY_HOURS_SERVICE_SHORT_NAME"],
            post_close_buffer_minutes=current_app.config[
                "LIBRARY_HOURS_POST_CLOSE_BUFFER_MINUTES"
            ],
        )

    if request.method == "POST":
        if not makerspace_is_open:
            flash(closed_message or "The Makerspace is currently closed.", "error")
            return render_template(
                "patron_register.html",
                form=form,
                category_options=CATEGORY_OPTIONS,
                ncsu_domain=NCSU_EMAIL_DOMAIN,
                makerspace_is_open=makerspace_is_open,
                closed_message=closed_message,
            )

        form.update({key: request.form.get(key, "").strip() for key in form})
        form["file_name"] = _normalize_single_line(form["file_name"])
        if form["file_name"] and not form["file_name"].lower().endswith(".stl"):
            form["file_name"] += ".stl"
        form["first_name"] = _normalize_person_name(form["first_name"])
        form["last_name"] = _normalize_person_name(form["last_name"])
        form["course_number"] = _normalize_single_line(form["course_number"])
        form["instructor"] = _normalize_person_name(form["instructor"])
        form["department"] = _normalize_single_line(form["department"])
        form["pi_name"] = _normalize_person_name(form["pi_name"])

        if form["category"] != JOB_CATEGORY_COURSE:
            form["course_number"] = ""
            form["instructor"] = ""
        if form["category"] != JOB_CATEGORY_RESEARCH:
            form["department"] = ""
            form["pi_name"] = ""

        errors = []

        if not form["file_name"]:
            errors.append("File name is required.")
        if not form["first_name"]:
            errors.append("First name is required.")
        if not form["last_name"]:
            errors.append("Last name is required.")
        if form["category"] not in JOB_CATEGORIES:
            errors.append("Choose a valid category.")
        if form["category"] == JOB_CATEGORY_COURSE:
            if not form["course_number"]:
                errors.append("Course # is required for Academic prints.")
            if not form["instructor"]:
                errors.append("Instructor is required for Academic prints.")
        if form["category"] == JOB_CATEGORY_RESEARCH:
            if not form["department"]:
                errors.append("Department is required for Research prints.")
            if not form["pi_name"]:
                errors.append("PI is required for Research prints.")

        user_email = ""
        try:
            user_email = _normalize_ncsu_email(form["user_email_local"])
        except ValueError as exc:
            errors.append(str(exc))

        if errors:
            for error in errors:
                flash(error, "error")
            return render_template(
                "patron_register.html",
                form=form,
                category_options=CATEGORY_OPTIONS,
                ncsu_domain=NCSU_EMAIL_DOMAIN,
                makerspace_is_open=makerspace_is_open,
                closed_message=closed_message,
            )

        full_name = f"{form['first_name']} {form['last_name']}".strip()

        job = PrintJob(
            label_code=_generate_label_code(),
            print_title=form["file_name"],
            user_name=full_name,
            user_email=user_email,
            printer_name=current_app.config["DEFAULT_PRINTER_NAME"],
            category=form["category"],
            course_number=form["course_number"] or None,
            instructor=form["instructor"] or None,
            department=form["department"] or None,
            pi_name=form["pi_name"] or None,
            location=current_app.config["DEFAULT_PRINTER_NAME"],
            notes=None,
        )
        db.session.add(job)
        db.session.commit()

        sync_ok, sync_error = sync_job_to_google_sheet(job)
        if not sync_ok:
            current_app.logger.warning(
                "Google Sheets sync failed for %s at registration: %s",
                job.label_code,
                sync_error,
            )

        label_result = create_and_print_label(**build_label_kwargs(job))

        return render_template(
            "patron_success.html",
            job=job,
            label_result=label_result,
            sync_error=sync_error if not sync_ok else None,
        )

    return render_template(
        "patron_register.html",
        form=form,
        category_options=CATEGORY_OPTIONS,
        ncsu_domain=NCSU_EMAIL_DOMAIN,
        makerspace_is_open=makerspace_is_open,
        closed_message=closed_message,
    )


@bp.route("/qr/<label_code>.png")
def qr_code_image(label_code: str):
    job = PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()
    operational_settings = get_operational_settings()
    completion_url = build_staff_completion_url(job.label_code)
    payload = (
        completion_url
        if operational_settings["qr_payload_mode"] == "url"
        else job.label_code
    )
    image = build_qr_image(payload, size=320)
    image_bytes = io.BytesIO()
    image.save(image_bytes, format="PNG")
    image_bytes.seek(0)
    return send_file(image_bytes, mimetype="image/png")


@bp.route("/label-preview/<label_code>.png")
def label_preview(label_code: str):
    PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()
    output_dir = Path(current_app.config["LABEL_OUTPUT_DIR"]).resolve()
    label_path = (output_dir / f"{label_code.upper()}.png").resolve()
    if not label_path.is_relative_to(output_dir) or not label_path.exists():
        abort(404)
    return send_file(label_path, mimetype="image/png")
