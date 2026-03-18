import os
import unittest
from datetime import datetime, timedelta, timezone

os.environ["DATABASE_URL"] = "sqlite:///:memory:"
os.environ["SECRET_KEY"] = "test-secret"
os.environ["STAFF_PASSWORD"] = "staffpw"
os.environ["WORKER_DISPATCH_ENABLED"] = "true"
os.environ["AGENT_BOOTSTRAP_KEY"] = "test-bootstrap"

from print_tracker import create_app
from print_tracker.extensions import db
from print_tracker.models import AppSetting, PrintJob, WorkerNode
from print_tracker.services.runtime_settings import KEY_QR_PAYLOAD_MODE


class AdminWorkerRegistryTests(unittest.TestCase):
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

    def _create_worker(self, agent_id: str = "pi-test-1") -> WorkerNode:
        worker = WorkerNode(
            agent_id=agent_id,
            display_name="Test Worker",
            space_slug="maker-studio",
            printer_queue="QL-800",
            status="online",
            is_active=True,
        )
        db.session.add(worker)
        db.session.commit()
        return worker

    def _create_worker_with_heartbeat(
        self,
        *,
        agent_id: str,
        space_slug: str,
        is_active: bool,
        heartbeat_seconds_ago: int | None,
    ) -> WorkerNode:
        heartbeat = None
        if heartbeat_seconds_ago is not None:
            heartbeat = datetime.now(timezone.utc) - timedelta(
                seconds=heartbeat_seconds_ago
            )
        worker = WorkerNode(
            agent_id=agent_id,
            display_name=f"Worker {agent_id}",
            space_slug=space_slug,
            printer_queue="QL-800",
            status="online" if is_active else "inactive",
            is_active=is_active,
            last_heartbeat_at=heartbeat,
        )
        db.session.add(worker)
        db.session.commit()
        return worker

    def _create_job(self, worker_id: int | None) -> PrintJob:
        job = PrintJob(
            label_code="MS-03-18-26-001",
            print_title="part.stl",
            user_name="Test User",
            user_email="test@ncsu.edu",
            printer_name="Maker Studio",
            space_slug="maker-studio",
            assigned_worker_id=worker_id,
        )
        db.session.add(job)
        db.session.commit()
        return job

    def test_registry_row_shows_remove_action(self):
        worker = self._create_worker("pi-test-remove")

        response = self.client.get("/admin/")
        html = response.get_data(as_text=True)

        self.assertEqual(response.status_code, 200)
        self.assertIn("Remove", html)
        self.assertIn(f"/admin/workers/{worker.id}/delete", html)

    def test_delete_worker_removes_registry_and_unassigns_jobs(self):
        worker = self._create_worker("pi-test-delete")
        job = self._create_job(worker.id)

        response = self.client.post(
            f"/admin/workers/{worker.id}/delete", follow_redirects=True
        )

        self.assertEqual(response.status_code, 200)
        self.assertIsNone(db.session.get(WorkerNode, worker.id))

        updated_job = db.session.get(PrintJob, job.id)
        self.assertIsNotNone(updated_job)
        self.assertIsNone(updated_job.assigned_worker_id)

    def test_worker_state_actions(self):
        worker = self._create_worker("pi-test-state")

        deactivate = self.client.post(
            f"/admin/workers/{worker.id}/state",
            data={"action": "deactivate"},
            follow_redirects=True,
        )
        self.assertEqual(deactivate.status_code, 200)
        self.assertFalse(db.session.get(WorkerNode, worker.id).is_active)

        reactivate = self.client.post(
            f"/admin/workers/{worker.id}/state",
            data={"action": "activate"},
            follow_redirects=True,
        )
        self.assertEqual(reactivate.status_code, 200)
        self.assertTrue(db.session.get(WorkerNode, worker.id).is_active)

    def test_settings_force_qr_mode_to_url(self):
        response = self.client.post(
            "/admin/settings",
            data={
                "completion_email_enabled": "on",
                "save_label_files": "on",
                "label_retention_days": "5",
            },
            follow_redirects=True,
        )

        self.assertEqual(response.status_code, 200)
        qr_mode_setting = db.session.get(AppSetting, KEY_QR_PAYLOAD_MODE)
        self.assertIsNotNone(qr_mode_setting)
        self.assertEqual(qr_mode_setting.value, "url")

    def test_registry_filters_by_health_space_and_query(self):
        online = self._create_worker_with_heartbeat(
            agent_id="pi-online",
            space_slug="maker-studio",
            is_active=True,
            heartbeat_seconds_ago=5,
        )
        stale = self._create_worker_with_heartbeat(
            agent_id="pi-stale",
            space_slug="makerspace",
            is_active=True,
            heartbeat_seconds_ago=500,
        )
        inactive = self._create_worker_with_heartbeat(
            agent_id="pi-inactive",
            space_slug="maker-studio",
            is_active=False,
            heartbeat_seconds_ago=None,
        )

        response = self.client.get("/admin/?health=stale&space=makerspace&q=pi-stale")
        html = response.get_data(as_text=True)

        self.assertEqual(response.status_code, 200)
        self.assertIn(f"/admin/workers/{stale.id}/state", html)
        self.assertNotIn(f"/admin/workers/{online.id}/state", html)
        self.assertNotIn(f"/admin/workers/{inactive.id}/state", html)

    def test_bulk_deactivate_stale_offline(self):
        stale = self._create_worker_with_heartbeat(
            agent_id="pi-stale-target",
            space_slug="maker-studio",
            is_active=True,
            heartbeat_seconds_ago=600,
        )
        online = self._create_worker_with_heartbeat(
            agent_id="pi-online-keep",
            space_slug="maker-studio",
            is_active=True,
            heartbeat_seconds_ago=5,
        )

        response = self.client.post(
            "/admin/workers/bulk",
            data={"action": "deactivate_stale_offline"},
            follow_redirects=True,
        )

        self.assertEqual(response.status_code, 200)
        self.assertFalse(db.session.get(WorkerNode, stale.id).is_active)
        self.assertTrue(db.session.get(WorkerNode, online.id).is_active)

    def test_bulk_remove_inactive_unassigns_jobs(self):
        inactive = self._create_worker_with_heartbeat(
            agent_id="pi-inactive-remove",
            space_slug="maker-studio",
            is_active=False,
            heartbeat_seconds_ago=None,
        )
        active = self._create_worker_with_heartbeat(
            agent_id="pi-active-keep",
            space_slug="maker-studio",
            is_active=True,
            heartbeat_seconds_ago=5,
        )
        job = self._create_job(inactive.id)

        response = self.client.post(
            "/admin/workers/bulk",
            data={"action": "remove_inactive"},
            follow_redirects=True,
        )

        self.assertEqual(response.status_code, 200)
        self.assertIsNone(db.session.get(WorkerNode, inactive.id))
        self.assertIsNotNone(db.session.get(WorkerNode, active.id))
        self.assertIsNone(db.session.get(PrintJob, job.id).assigned_worker_id)


if __name__ == "__main__":
    unittest.main()
