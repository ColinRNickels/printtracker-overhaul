from collections import Counter
from datetime import date

from ..models import (
    JOB_CATEGORIES,
    JOB_CATEGORY_RESEARCH,
    JOB_STATUS_CANCELLED,
    JOB_STATUS_FAILED,
    JOB_STATUS_FINISHED,
    JOB_STATUS_IN_PROGRESS,
)


def build_monthly_summary(jobs: list) -> dict:
    category_counts = Counter()
    status_counts = Counter()
    turnaround_hours = []

    for job in jobs:
        if job.category in JOB_CATEGORIES:
            category_counts[job.category] += 1
        status_counts[job.status] += 1

        if job.completed_at and job.created_at:
            duration = job.completed_at - job.created_at
            turnaround_hours.append(duration.total_seconds() / 3600)

    avg_hours = sum(turnaround_hours) / len(turnaround_hours) if turnaround_hours else 0

    return {
        "total_jobs": len(jobs),
        "category_counts": {category: category_counts.get(category, 0) for category in JOB_CATEGORIES},
        "status_counts": {
            JOB_STATUS_IN_PROGRESS: status_counts.get(JOB_STATUS_IN_PROGRESS, 0),
            JOB_STATUS_FINISHED: status_counts.get(JOB_STATUS_FINISHED, 0),
            JOB_STATUS_FAILED: status_counts.get(JOB_STATUS_FAILED, 0),
            JOB_STATUS_CANCELLED: status_counts.get(JOB_STATUS_CANCELLED, 0),
        },
        "average_turnaround_hours": avg_hours,
    }


def shift_month(month_start: date, delta: int) -> date:
    month_index = (month_start.year * 12 + (month_start.month - 1)) + delta
    year = month_index // 12
    month = (month_index % 12) + 1
    return date(year, month, 1)


def build_prints_over_time_chart(*, jobs: list, end_month_start: date, months: int = 12) -> dict:
    month_starts = [shift_month(end_month_start, -offset) for offset in range(months - 1, -1, -1)]
    keys = [month.strftime("%Y-%m") for month in month_starts]
    counts = {key: 0 for key in keys}

    for job in jobs:
        if not job.created_at:
            continue
        key = job.created_at.strftime("%Y-%m")
        if key in counts:
            counts[key] += 1

    return {
        "labels": [month.strftime("%b %Y") for month in month_starts],
        "values": [counts[key] for key in keys],
    }


def build_department_chart(jobs: list) -> dict:
    department_counts = Counter()
    for job in jobs:
        if job.category != JOB_CATEGORY_RESEARCH:
            continue
        if job.department:
            department_counts[job.department] += 1

    ordered = department_counts.most_common(12)
    return {
        "labels": [item[0] for item in ordered],
        "values": [item[1] for item in ordered],
    }
