import importlib.util
import os
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class PortDefaultsTest(unittest.TestCase):
    def test_default_ports_are_80_and_443(self):
        os.environ["ADMIN_PASSWORD"] = "test-password"
        sys.modules.pop("app", None)
        spec = importlib.util.spec_from_file_location("app", ROOT / "app.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.APP_PORT, 80)
        self.assertEqual(module.HTTPS_PORT, 443)


if __name__ == "__main__":
    unittest.main()
