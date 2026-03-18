from datetime import datetime, timezone
from hashlib import sha256
from secrets import token_urlsafe

from .extensions import db

JOB_STATUS_IN_PROGRESS = "in_progress"
JOB_STATUS_FINISHED = "finished"
JOB_STATUS_FAILED = "failed"
JOB_STATUS_CANCELLED = "cancelled"

PRINT_STATUS_NOT_REQUESTED = "not_requested"
PRINT_STATUS_QUEUED = "queued"
PRINT_STATUS_DISPATCHED = "dispatched"
PRINT_STATUS_PRINTED = "printed"
PRINT_STATUS_FAILED = "failed"
PRINT_STATUS_MANUAL = "manual"

JOB_STATUS_LABELS = {
    JOB_STATUS_IN_PROGRESS: "In Progress",
    JOB_STATUS_FINISHED: "Finished",
    JOB_STATUS_FAILED: "Failed",
    JOB_STATUS_CANCELLED: "Cancelled",
}

PRINT_STATUS_LABELS = {
    PRINT_STATUS_NOT_REQUESTED: "Not Requested",
    PRINT_STATUS_QUEUED: "Queued",
    PRINT_STATUS_DISPATCHED: "Dispatched",
    PRINT_STATUS_PRINTED: "Printed",
    PRINT_STATUS_FAILED: "Print Failed",
    PRINT_STATUS_MANUAL: "Manual Handling",
}

JOB_CATEGORY_PERSONAL = "personal_project"
JOB_CATEGORY_COURSE = "course_assignment"
JOB_CATEGORY_RESEARCH = "university_research"

JOB_CATEGORIES = (
    JOB_CATEGORY_PERSONAL,
    JOB_CATEGORY_COURSE,
    JOB_CATEGORY_RESEARCH,
)

JOB_CATEGORY_LABELS = {
    JOB_CATEGORY_PERSONAL: "Personal",
    JOB_CATEGORY_COURSE: "Academic",
    JOB_CATEGORY_RESEARCH: "Research",
}


class PrintJob(db.Model):
    __tablename__ = "print_jobs"

    id = db.Column(db.Integer, primary_key=True)
    label_code = db.Column(db.String(24), unique=True, nullable=False, index=True)

    print_title = db.Column(db.String(140), nullable=False)
    user_name = db.Column(db.String(120), nullable=False)
    user_email = db.Column(db.String(255), nullable=False)
    printer_name = db.Column(db.String(80), nullable=False)
    space_slug = db.Column(db.String(64), nullable=True, index=True)
    category = db.Column(db.String(32), nullable=False, default=JOB_CATEGORY_PERSONAL)
    course_number = db.Column(db.String(64), nullable=True)
    instructor = db.Column(db.String(120), nullable=True)
    department = db.Column(db.String(120), nullable=True)
    pi_name = db.Column(db.String(120), nullable=True)
    location = db.Column(db.String(120), nullable=True)
    notes = db.Column(db.Text, nullable=True)
    estimated_minutes = db.Column(db.Integer, nullable=True)

    status = db.Column(
        db.String(32), nullable=False, default=JOB_STATUS_IN_PROGRESS, index=True
    )
    created_at = db.Column(
        db.DateTime,
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
        index=True,
    )
    completed_at = db.Column(db.DateTime, nullable=True)
    completed_by = db.Column(db.String(120), nullable=True)
    completion_notes = db.Column(db.Text, nullable=True)

    assigned_worker_id = db.Column(
        db.Integer, db.ForeignKey("worker_nodes.id"), nullable=True, index=True
    )
    print_status = db.Column(
        db.String(32), nullable=False, default=PRINT_STATUS_NOT_REQUESTED, index=True
    )
    print_dispatched_at = db.Column(db.DateTime, nullable=True)
    printed_at = db.Column(db.DateTime, nullable=True)
    print_attempts = db.Column(db.Integer, nullable=False, default=0)
    print_error = db.Column(db.Text, nullable=True)
    manual_fallback_required = db.Column(db.Boolean, nullable=False, default=False)

    email_status = db.Column(db.String(32), nullable=False, default="not_attempted")
    email_error = db.Column(db.Text, nullable=True)
    email_sent_at = db.Column(db.DateTime, nullable=True)

    assigned_worker = db.relationship("WorkerNode", back_populates="jobs")

    def mark_completed(
        self, *, outcome: str, completed_by: str, completion_notes: str | None
    ) -> None:
        if outcome == JOB_STATUS_FINISHED:
            self.status = JOB_STATUS_FINISHED
        elif outcome == JOB_STATUS_CANCELLED:
            self.status = JOB_STATUS_CANCELLED
        else:
            self.status = JOB_STATUS_FAILED
        self.completed_by = completed_by
        self.completion_notes = completion_notes or None
        self.completed_at = datetime.now(timezone.utc)

    @property
    def is_completed(self) -> bool:
        return self.status in {JOB_STATUS_FINISHED, JOB_STATUS_FAILED, JOB_STATUS_CANCELLED}

    @property
    def print_status_label(self) -> str:
        return PRINT_STATUS_LABELS.get(
            self.print_status, self.print_status.replace("_", " ").title()
        )

    def mark_print_dispatched(self, *, worker_id: int | None) -> None:
        self.assigned_worker_id = worker_id
        self.print_status = PRINT_STATUS_DISPATCHED
        self.print_dispatched_at = datetime.now(timezone.utc)
        self.print_attempts = (self.print_attempts or 0) + 1
        self.print_error = None
        self.manual_fallback_required = False

    def mark_printed(self, *, worker_id: int | None = None) -> None:
        if worker_id is not None:
            self.assigned_worker_id = worker_id
        self.print_status = PRINT_STATUS_PRINTED
        self.printed_at = datetime.now(timezone.utc)
        self.print_error = None
        self.manual_fallback_required = False

    def mark_print_failed(
        self,
        *,
        error_message: str | None,
        worker_id: int | None = None,
        manual_fallback_required: bool = True,
    ) -> None:
        if worker_id is not None:
            self.assigned_worker_id = worker_id
        self.print_status = PRINT_STATUS_FAILED
        self.print_error = error_message or None
        self.manual_fallback_required = manual_fallback_required


def _hash_agent_token(raw_token: str) -> str:
    return sha256(raw_token.encode("utf-8")).hexdigest()


class WorkerNode(db.Model):
    __tablename__ = "worker_nodes"

    id = db.Column(db.Integer, primary_key=True)
    agent_id = db.Column(db.String(64), unique=True, nullable=False, index=True)
    display_name = db.Column(db.String(120), nullable=False)
    space_slug = db.Column(db.String(64), nullable=False, index=True)
    printer_queue = db.Column(db.String(120), nullable=True)
    auth_token_hash = db.Column(db.String(64), nullable=True)
    software_version = db.Column(db.String(64), nullable=True)
    last_seen_ip = db.Column(db.String(64), nullable=True)
    status = db.Column(db.String(32), nullable=False, default="pending")
    is_active = db.Column(db.Boolean, nullable=False, default=True)
    created_at = db.Column(
        db.DateTime,
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )
    updated_at = db.Column(
        db.DateTime,
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )
    last_heartbeat_at = db.Column(db.DateTime, nullable=True)

    jobs = db.relationship("PrintJob", back_populates="assigned_worker")

    def issue_token(self) -> str:
        raw_token = token_urlsafe(32)
        self.auth_token_hash = _hash_agent_token(raw_token)
        return raw_token

    def check_token(self, raw_token: str | None) -> bool:
        if not raw_token or not self.auth_token_hash:
            return False
        return self.auth_token_hash == _hash_agent_token(raw_token)

    @property
    def file_name(self) -> str:
        return self.print_title

    @property
    def category_label(self) -> str:
        return JOB_CATEGORY_LABELS.get(self.category, "Other")

    @property
    def status_label(self) -> str:
        return JOB_STATUS_LABELS.get(self.status, self.status.replace("_", " ").title())


class AppSetting(db.Model):
    __tablename__ = "app_settings"

    key = db.Column(db.String(64), primary_key=True)
    value = db.Column(db.String(255), nullable=False)
    updated_at = db.Column(
        db.DateTime,
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )
