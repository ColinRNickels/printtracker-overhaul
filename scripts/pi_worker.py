#!/usr/bin/env python3
from __future__ import annotations

import json
import logging
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib import error, parse, request

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from print_tracker.models import JOB_CATEGORY_LABELS  # noqa: E402
from print_tracker.services.label_printer import create_and_print_label  # noqa: E402


log = logging.getLogger("print_tracker.pi_worker")


def _env_flag(name: str, default: bool) -> bool:
    raw_value = os.environ.get(name)
    if raw_value is None:
        return default
    return raw_value.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int, minimum: int | None = None) -> int:
    raw_value = os.environ.get(name)
    try:
        parsed = int(raw_value) if raw_value is not None else default
    except ValueError:
        parsed = default
    if minimum is not None:
        parsed = max(parsed, minimum)
    return parsed


def _normalize_url(url: str) -> str:
    return (url or "").strip().rstrip("/")


def _http_json(
    method: str,
    url: str,
    *,
    payload: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 15,
) -> dict[str, Any]:
    body = None
    request_headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    if headers:
        request_headers.update(headers)

    req = request.Request(
        url, data=body, method=method.upper(), headers=request_headers
    )
    with request.urlopen(req, timeout=timeout) as response:
        response_body = response.read().decode("utf-8")
    if not response_body:
        return {}
    return json.loads(response_body)


@dataclass(slots=True)
class WorkerConfig:
    server_base_url: str
    agent_id: str
    bootstrap_key: str
    space_slug: str
    display_name: str
    printer_queue: str
    software_version: str
    token_file: Path
    poll_interval_seconds: int
    heartbeat_interval_seconds: int
    label_output_dir: str
    label_print_mode: str
    label_stock: str
    label_dpi: int
    qr_payload_mode: str
    label_qr_size_inch: float
    label_orientation: str
    label_brand_text: str
    label_brand_logo_path: str
    label_side_art_path: str
    label_cups_media: str
    label_cups_extra_options: str
    save_label_files: bool
    cleanup_keep_days: int

    @property
    def auth_headers(self) -> dict[str, str]:
        token = self.read_agent_token()
        if not token:
            return {}
        return {
            "Authorization": f"Bearer {token}",
            "X-Agent-ID": self.agent_id,
        }

    def read_agent_token(self) -> str:
        if not self.token_file.exists():
            return ""
        return self.token_file.read_text(encoding="utf-8").strip()

    def write_agent_token(self, token: str) -> None:
        self.token_file.parent.mkdir(parents=True, exist_ok=True)
        self.token_file.write_text(token.strip() + "\n", encoding="utf-8")
        self.token_file.chmod(0o600)


@dataclass(slots=True)
class JobPayload:
    label_code: str
    print_title: str
    user_name: str
    category: str
    created_at: datetime

    @property
    def file_name(self) -> str:
        return self.print_title

    @property
    def category_label(self) -> str:
        return JOB_CATEGORY_LABELS.get(
            self.category, self.category.replace("_", " ").title()
        )


def load_worker_config() -> WorkerConfig:
    env_path = Path(os.environ.get("PI_AGENT_ENV_FILE", PROJECT_ROOT / ".env.pi-agent"))
    if env_path.exists():
        load_dotenv(env_path)

    server_base_url = _normalize_url(os.environ.get("SERVER_BASE_URL", ""))
    agent_id = (os.environ.get("AGENT_ID", "") or "").strip()
    bootstrap_key = (os.environ.get("AGENT_BOOTSTRAP_KEY", "") or "").strip()
    space_slug = (os.environ.get("AGENT_SPACE_SLUG", "") or "").strip().lower()
    display_name = (
        os.environ.get("AGENT_DISPLAY_NAME", "") or agent_id
    ).strip() or agent_id
    printer_queue = (os.environ.get("LABEL_PRINTER_QUEUE", "") or "").strip()

    if not server_base_url:
        raise RuntimeError("SERVER_BASE_URL is required.")
    if not agent_id:
        raise RuntimeError("AGENT_ID is required.")
    if (
        not bootstrap_key
        and not Path(
            os.environ.get(
                "AGENT_TOKEN_FILE", PROJECT_ROOT / ".state" / "pi-agent.token"
            )
        ).exists()
    ):
        raise RuntimeError(
            "AGENT_BOOTSTRAP_KEY is required until the agent has registered."
        )
    if not space_slug:
        raise RuntimeError("AGENT_SPACE_SLUG is required.")

    return WorkerConfig(
        server_base_url=server_base_url,
        agent_id=agent_id,
        bootstrap_key=bootstrap_key,
        space_slug=space_slug,
        display_name=display_name,
        printer_queue=printer_queue,
        software_version=(
            os.environ.get("AGENT_SOFTWARE_VERSION", "poc") or "poc"
        ).strip(),
        token_file=Path(
            os.environ.get(
                "AGENT_TOKEN_FILE", PROJECT_ROOT / ".state" / "pi-agent.token"
            )
        ),
        poll_interval_seconds=_env_int("AGENT_POLL_INTERVAL_SECONDS", 5, minimum=1),
        heartbeat_interval_seconds=_env_int(
            "AGENT_HEARTBEAT_INTERVAL_SECONDS", 30, minimum=5
        ),
        label_output_dir=os.environ.get(
            "LABEL_OUTPUT_DIR", str(PROJECT_ROOT / "labels")
        ),
        label_print_mode=os.environ.get("LABEL_PRINT_MODE", "cups"),
        label_stock=os.environ.get("LABEL_STOCK", "DK1202"),
        label_dpi=_env_int("LABEL_DPI", 300, minimum=72),
        qr_payload_mode=os.environ.get("LABEL_QR_PAYLOAD_MODE", "url"),
        label_qr_size_inch=float(os.environ.get("LABEL_QR_SIZE_INCH", "0.5")),
        label_orientation=os.environ.get("LABEL_ORIENTATION", "landscape"),
        label_brand_text=os.environ.get(
            "LABEL_BRAND_TEXT", "NC State University Libraries Makerspace"
        ),
        label_brand_logo_path=os.environ.get("LABEL_BRAND_LOGO_PATH", ""),
        label_side_art_path=os.environ.get(
            "LABEL_SIDE_ART_PATH",
            str(PROJECT_ROOT / "assets" / "noun-3d-printer-8112508.svg"),
        ),
        label_cups_media=os.environ.get("LABEL_CUPS_MEDIA", "62x100mm"),
        label_cups_extra_options=os.environ.get("LABEL_CUPS_EXTRA_OPTIONS", ""),
        save_label_files=_env_flag("LABEL_SAVE_LABEL_FILES", True),
        cleanup_keep_days=_env_int("LABEL_RETENTION_DAYS", 2, minimum=1),
    )


def register_agent(config: WorkerConfig) -> None:
    if config.read_agent_token():
        return
    payload = {
        "bootstrap_key": config.bootstrap_key,
        "agent_id": config.agent_id,
        "space_slug": config.space_slug,
        "display_name": config.display_name,
        "printer_queue": config.printer_queue,
        "software_version": config.software_version,
    }
    response = _http_json(
        "POST",
        f"{config.server_base_url}/api/agents/register",
        payload=payload,
    )
    token = (response.get("token") or "").strip()
    if not token:
        raise RuntimeError("Agent registration did not return a token.")
    config.write_agent_token(token)
    log.info("Registered agent %s for space %s", config.agent_id, config.space_slug)


def send_heartbeat(config: WorkerConfig) -> None:
    _http_json(
        "POST",
        f"{config.server_base_url}/api/agents/heartbeat",
        headers=config.auth_headers,
    )


def fetch_jobs(config: WorkerConfig) -> list[dict[str, Any]]:
    query = parse.urlencode({"limit": 5})
    response = _http_json(
        "GET",
        f"{config.server_base_url}/api/agents/jobs?{query}",
        headers=config.auth_headers,
    )
    jobs = response.get("jobs") or []
    if not isinstance(jobs, list):
        return []
    return jobs


def build_job_payload(raw_job: dict[str, Any]) -> JobPayload:
    created_at_raw = raw_job.get("created_at")
    created_at = datetime.now(timezone.utc)
    if created_at_raw:
        created_at = datetime.fromisoformat(created_at_raw.replace("Z", "+00:00"))
    return JobPayload(
        label_code=(raw_job.get("label_code") or "").strip().upper(),
        print_title=(raw_job.get("print_title") or "").strip(),
        user_name=(raw_job.get("user_name") or "").strip(),
        category=(raw_job.get("category") or "").strip(),
        created_at=created_at,
    )


def print_job(config: WorkerConfig, raw_job: dict[str, Any]) -> dict[str, Any]:
    job = build_job_payload(raw_job)
    return create_and_print_label(
        job=job,
        completion_url=(raw_job.get("completion_url") or "").strip(),
        output_dir=config.label_output_dir,
        mode=config.label_print_mode,
        queue_name=config.printer_queue,
        stock=config.label_stock,
        dpi=config.label_dpi,
        qr_payload_mode=config.qr_payload_mode,
        qr_size_inch=config.label_qr_size_inch,
        label_orientation=config.label_orientation,
        brand_text=config.label_brand_text,
        brand_logo_path=config.label_brand_logo_path,
        side_art_path=config.label_side_art_path,
        cups_media=config.label_cups_media,
        cups_extra_options=config.label_cups_extra_options,
        save_label_files=config.save_label_files,
        cleanup_keep_days=config.cleanup_keep_days,
    )


def report_printed(config: WorkerConfig, label_code: str) -> None:
    _http_json(
        "POST",
        f"{config.server_base_url}/api/agents/jobs/{label_code}/printed",
        headers=config.auth_headers,
        payload={},
    )


def report_failed(config: WorkerConfig, label_code: str, error_message: str) -> None:
    _http_json(
        "POST",
        f"{config.server_base_url}/api/agents/jobs/{label_code}/failed",
        headers=config.auth_headers,
        payload={"error": error_message},
    )


def run_worker_loop(config: WorkerConfig) -> None:
    last_heartbeat = 0.0
    while True:
        now = time.monotonic()
        if now - last_heartbeat >= config.heartbeat_interval_seconds:
            send_heartbeat(config)
            last_heartbeat = now

        jobs = fetch_jobs(config)
        if not jobs:
            time.sleep(config.poll_interval_seconds)
            continue

        for raw_job in jobs:
            label_code = (raw_job.get("label_code") or "").strip().upper()
            try:
                result = print_job(config, raw_job)
                if result.get("printed"):
                    report_printed(config, label_code)
                    log.info("Printed %s", label_code)
                else:
                    message = (
                        result.get("message")
                        or "Agent did not mark print as successful."
                    )
                    report_failed(config, label_code, message)
                    log.warning("Print failed for %s: %s", label_code, message)
            except Exception as exc:  # noqa: BLE001
                report_failed(config, label_code, str(exc))
                log.exception("Unhandled print failure for %s", label_code)


def configure_logging() -> None:
    log_level = os.environ.get("PI_AGENT_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def main() -> int:
    configure_logging()
    try:
        config = load_worker_config()
        register_agent(config)
        run_worker_loop(config)
    except KeyboardInterrupt:
        log.info("Shutting down Pi worker")
        return 0
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        log.error("HTTP error %s: %s", exc.code, body)
        return 1
    except Exception as exc:  # noqa: BLE001
        log.exception("Pi worker failed: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
