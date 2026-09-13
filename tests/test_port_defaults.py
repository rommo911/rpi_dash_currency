import importlib.util
import os
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class PortDefaultsTest(unittest.TestCase):
    def test_default_ports_are_80_and_443(self):
        # Port defaults live in config.py (app.py is just the entrypoint
        # that reads them) — loaded fresh via spec_from_file_location,
        # same as before, so a stale os.environ from another test can't
        # leak in through Python's module cache.
        os.environ["ADMIN_PASSWORD"] = "test-password"
        os.environ.pop("APP_PORT", None)
        os.environ.pop("HTTPS_PORT", None)
        sys.modules.pop("config", None)
        spec = importlib.util.spec_from_file_location("config", ROOT / "config.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.APP_PORT, 80)
        self.assertEqual(module.HTTPS_PORT, 443)


if __name__ == "__main__":
    unittest.main()
