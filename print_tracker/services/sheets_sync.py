from __future__ import annotations

from datetime import datetime

from flask import current_app

from ..models import PrintJob
from .google_api import GOOGLE_SHEETS_SCOPE, build_google_service

SHEET_HEADERS = [
    "PrintID",
    "CreatedAt",
    "CompletedAt",
    "Status",
    "StatusLabel",
    "ProjectType",
    "ProjectTypeLabel",
    "FileName",
    "UserName",
    "UserEmail",
    "CourseNumber",
    "Instructor",
    "Department",
    "PI",
    "CompletedBy",
    "CompletionNotes",
    "EmailStatus",
    "EmailError",
    "EmailSentAt",
    "PrinterName",
    "Location",
]


def sync_job_to_google_sheet(job: PrintJob) -> tuple[bool, str | None]:
    if not current_app.config.get("GOOGLE_SHEETS_SYNC_ENABLED"):
        return True, None

    spreadsheet_id = current_app.config.get("GOOGLE_SHEETS_SPREADSHEET_ID", "").strip()
    if not spreadsheet_id:
        return False, "GOOGLE_SHEETS_SPREADSHEET_ID is not configured."

    worksheet = (
        current_app.config.get("GOOGLE_SHEETS_WORKSHEET", "PrintJobs").strip()
        or "PrintJobs"
    )

    try:
        service = build_google_service("sheets", "v4", scopes=[GOOGLE_SHEETS_SCOPE])
        _ensure_sheet_exists(
            service, spreadsheet_id=spreadsheet_id, worksheet=worksheet
        )
        _ensure_headers(service, spreadsheet_id=spreadsheet_id, worksheet=worksheet)
        row_number = _find_row_number_by_print_id(
            service,
            spreadsheet_id=spreadsheet_id,
            worksheet=worksheet,
            label_code=job.label_code,
        )
        row_values = [_build_row(job)]

        if row_number:
            end_col = _column_letter(len(SHEET_HEADERS))
            row_range = _sheet_range(worksheet, f"A{row_number}:{end_col}{row_number}")
            service.spreadsheets().values().update(
                spreadsheetId=spreadsheet_id,
                range=row_range,
                valueInputOption="RAW",
                body={"values": row_values},
            ).execute()
            current_app.logger.info(
                "Updated Google Sheets row for %s (row %s)", job.label_code, row_number
            )
        else:
            service.spreadsheets().values().append(
                spreadsheetId=spreadsheet_id,
                range=_sheet_range(worksheet, "A:A"),
                valueInputOption="RAW",
                insertDataOption="INSERT_ROWS",
                body={"values": row_values},
            ).execute()
            current_app.logger.info("Appended Google Sheets row for %s", job.label_code)
        return True, None
    except Exception as exc:  # noqa: BLE001
        current_app.logger.exception("Google Sheets sync failed for %s", job.label_code)
        return False, str(exc)


def _build_row(job: PrintJob) -> list[str]:
    return [
        job.label_code,
        _to_iso(job.created_at),
        _to_iso(job.completed_at),
        job.status or "",
        job.status_label or "",
        job.category or "",
        job.category_label or "",
        job.file_name or "",
        job.user_name or "",
        job.user_email or "",
        job.course_number or "",
        job.instructor or "",
        job.department or "",
        job.pi_name or "",
        job.completed_by or "",
        job.completion_notes or "",
        job.email_status or "",
        job.email_error or "",
        _to_iso(job.email_sent_at),
        job.printer_name or "",
        current_app.config.get("DEFAULT_PRINTER_NAME", ""),
    ]


def _to_iso(value: datetime | None) -> str:
    return value.isoformat() if value else ""


def _sheet_range(worksheet: str, a1_range: str) -> str:
    safe_name = worksheet.replace("'", "''")
    return f"'{safe_name}'!{a1_range}"


def _ensure_sheet_exists(service, *, spreadsheet_id: str, worksheet: str) -> None:
    metadata = (
        service.spreadsheets()
        .get(
            spreadsheetId=spreadsheet_id,
            fields="sheets(properties(title))",
        )
        .execute()
    )
    titles = {
        sheet.get("properties", {}).get("title", "")
        for sheet in metadata.get("sheets", [])
    }
    if worksheet in titles:
        return

    service.spreadsheets().batchUpdate(
        spreadsheetId=spreadsheet_id,
        body={"requests": [{"addSheet": {"properties": {"title": worksheet}}}]},
    ).execute()


def _ensure_headers(service, *, spreadsheet_id: str, worksheet: str) -> None:
    result = (
        service.spreadsheets()
        .values()
        .get(
            spreadsheetId=spreadsheet_id,
            range=_sheet_range(worksheet, "1:1"),
        )
        .execute()
    )
    existing_values = result.get("values", [])
    existing_headers = existing_values[0] if existing_values else []
    if existing_headers == SHEET_HEADERS:
        return

    service.spreadsheets().values().update(
        spreadsheetId=spreadsheet_id,
        range=_sheet_range(worksheet, "A1"),
        valueInputOption="RAW",
        body={"values": [SHEET_HEADERS]},
    ).execute()


def _find_row_number_by_print_id(
    service,
    *,
    spreadsheet_id: str,
    worksheet: str,
    label_code: str,
) -> int | None:
    result = (
        service.spreadsheets()
        .values()
        .get(
            spreadsheetId=spreadsheet_id,
            range=_sheet_range(worksheet, "A2:A"),
        )
        .execute()
    )
    rows = result.get("values", [])
    target = label_code.strip().upper()
    for index, row in enumerate(rows, start=2):
        if row and row[0].strip().upper() == target:
            return index
    return None


def _column_letter(index: int) -> str:
    if index <= 0:
        raise ValueError("Column index must be positive")
    letters = []
    current = index
    while current > 0:
        current, remainder = divmod(current - 1, 26)
        letters.append(chr(ord("A") + remainder))
    return "".join(reversed(letters))
