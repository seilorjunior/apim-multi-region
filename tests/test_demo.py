import importlib.util
import json
import os
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
from uuid import UUID
from urllib.error import HTTPError
from urllib.request import Request, urlopen


SOURCE = Path(__file__).resolve().parents[1] / "src" / "demo" / "server.py"
SPEC = importlib.util.spec_from_file_location("demo", SOURCE)
DEMO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEMO)


class DemoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = patch.dict(os.environ, {"REGION": "brazilsouth"})
        cls.environment.start()
        cls.server = DEMO.ThreadingHTTPServer(("127.0.0.1", 0), DEMO.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.environment.stop()

    def test_region_response(self):
        with urlopen(self.base_url + "/?request=123", timeout=5) as response:
            body = json.load(response)
            self.assertEqual(response.status, 200)
            self.assertEqual(body["service"], "regional-demo")
            self.assertEqual(body["region"], "brazilsouth")
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertEqual(response.headers["Content-Type"], "application/json")

    def test_health_endpoints(self):
        for path in ("/health/live", "/health/ready"):
            with self.subTest(path=path):
                with urlopen(self.base_url + path, timeout=5) as response:
                    self.assertEqual(
                        json.load(response), {"status": "ok", "region": "brazilsouth"}
                    )

    def test_unknown_path(self):
        with self.assertRaises(HTTPError) as raised:
            urlopen(self.base_url + "/unknown", timeout=5)
        with raised.exception as response:
            self.assertEqual(response.code, 404)
            self.assertEqual(json.load(response)["error"], "not_found")

    def test_other_region(self):
        for region in ("eastus", "westus2"):
            with self.subTest(region=region):
                with patch.dict(os.environ, {"REGION": region}):
                    with urlopen(self.base_url + "/", timeout=5) as response:
                        body = json.load(response)
                        self.assertEqual(body["service"], "regional-demo")
                        self.assertEqual(body["region"], region)

    def test_correlation_id_generated(self):
        with urlopen(self.base_url + "/", timeout=5) as response:
            self.assertEqual(str(UUID(response.headers["X-Correlation-ID"])),
                             response.headers["X-Correlation-ID"])

    def test_correlation_id_preserved(self):
        request_id = "00000000-0000-0000-0000-000000000001"
        request = Request(self.base_url + "/", headers={"X-Correlation-ID": request_id})
        with urlopen(request, timeout=5) as response:
            self.assertEqual(response.headers["X-Correlation-ID"], request_id)

    def test_invalid_correlation_id_replaced(self):
        request = Request(self.base_url + "/", headers={"X-Correlation-ID": "not-a-guid"})
        with urlopen(request, timeout=5) as response:
            UUID(response.headers["X-Correlation-ID"])

    def test_structured_request_log(self):
        request_id = "00000000-0000-0000-0000-000000000002"
        request = Request(self.base_url + "/?secret=not-logged",
                          headers={"X-Correlation-ID": request_id})
        with patch("builtins.print") as output:
            with urlopen(request, timeout=5) as response:
                response.read()
            # The HTTP body can arrive just before the handler writes its log.
            for _ in range(100):
                entries = [json.loads(call.args[0]) for call in output.call_args_list]
                matching = [entry for entry in entries if entry.get("request_id") == request_id]
                if matching:
                    break
                threading.Event().wait(0.01)
            self.assertEqual(len(matching), 1)
            entry = matching[0]
            self.assertEqual(entry["event"], "request")
            self.assertEqual(entry["path"], "/")
            self.assertNotIn("secret", json.dumps(entry))
            self.assertEqual(entry["status"], 200)
            self.assertGreaterEqual(entry["duration_ms"], 0)


if __name__ == "__main__":
    unittest.main()
