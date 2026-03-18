import os
import unittest

os.environ["DATABASE_URL"] = "sqlite:///:memory:"
os.environ["SECRET_KEY"] = "test-secret"
os.environ["STAFF_PASSWORD"] = "staffpw"
os.environ["WORKER_DISPATCH_ENABLED"] = "true"
os.environ["AGENT_BOOTSTRAP_KEY"] = "test-bootstrap"

from print_tracker import create_app
from print_tracker.extensions import db
from print_tracker.models import (
    JOB_STATUS_IN_PROGRESS,
    PRINT_STATUS_MANUAL,
    PRINT_STATUS_QUEUED,
    PrintJob,
    WorkerNode,
)


class StaffOrphanedQueueAlertsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = create_app()
        cls.app.config.update(TESTING=True, WTF_CSRF_ENABLED=False)

    def setUp(self):
        self.ctx = self.app.app_context()
        self.ctx.push()
        db.drop_all()
        db.create_all()
        self.client = self.app.test_client()
        with self.client.session_transaction() as session:
            session["staff_authenticated"] = True

    def tearDown(self):
        db.session.remove()
        db.drop_all()
        self.ctx.pop()

    def _create_job(self, *, label_code: str, space_slug: str) -> PrintJob:
        job = PrintJob(
            label_code=label_code,
            print_title="part.stl",
            user_name="Test User",
            user_email="test@ncsu.edu",
            printer_name="Maker Studio",
            space_slug=space_slug,
            status=JOB_STATUS_IN_PROGRESS,
            print_status=PRINT_STATUS_QUEUED,
        )
        db.session.add(job)
        db.session.commit()
        return job

    def _create_worker(self, *, space_slug: str, is_active: bool = True) -> WorkerNode:
        worker = WorkerNode(
            agent_id=f"pi-test-{space_slug}",
            display_name="Test Worker",
            space_slug=space_slug,
            printer_queue="QL-800",
            status="online",
            is_active=is_active,
        )
        db.session.add(worker)
        db.session.commit()
        return worker

    def test_dashboard_shows_orphaned_queue_alert_with_print_id(self):
        job = self._create_job(label_code="PT-03-18-26-011", space_slug="maker-studio")

        response = self.client.get("/staff/")
        html = response.get_data(as_text=True)

        self.assertEqual(response.status_code, 200)
        self.assertIn("Action Needed: Jobs Waiting With No Worker", html)
        self.assertIn(f"Print ID: {job.label_code}", html)
        self.assertIn(f"/staff/manual-slip/{job.label_code}", html)

    def test_dashboard_does_not_show_orphaned_alert_when_worker_exists(self):
        self._create_worker(space_slug="maker-studio", is_active=True)
        self._create_job(label_code="PT-03-18-26-012", space_slug="maker-studio")

        response = self.client.get("/staff/")
        html = response.get_data(as_text=True)

        self.assertEqual(response.status_code, 200)
        self.assertNotIn("Action Needed: Jobs Waiting With No Worker", html)

    def test_mark_manual_slip_updates_job_state(self):
        job = self._create_job(label_code="PT-03-18-26-013", space_slug="maker-studio")

        response = self.client.post(
            f"/staff/manual-slip/{job.label_code}",
            follow_redirects=True,
        )

        self.assertEqual(response.status_code, 200)
        updated = db.session.get(PrintJob, job.id)
        self.assertIsNotNone(updated)
        self.assertEqual(updated.print_status, PRINT_STATUS_MANUAL)
        self.assertFalse(updated.manual_fallback_required)
        self.assertIsNotNone(updated.printed_at)


if __name__ == "__main__":
    unittest.main()
