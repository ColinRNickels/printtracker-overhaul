from datetime import datetime, timezone

from .extensions import db

JOB_STATUS_IN_PROGRESS = "in_progress"
JOB_STATUS_FINISHED = "finished"
JOB_STATUS_FAILED = "failed"
JOB_STATUS_CANCELLED = "cancelled"

JOB_STATUS_LABELS = {
    JOB_STATUS_IN_PROGRESS: "In Progress",
    JOB_STATUS_FINISHED: "Finished",
    JOB_STATUS_FAILED: "Failed",
    JOB_STATUS_CANCELLED: "Cancelled",
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

    email_status = db.Column(db.String(32), nullable=False, default="not_attempted")
    email_error = db.Column(db.Text, nullable=True)
    email_sent_at = db.Column(db.DateTime, nullable=True)

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
