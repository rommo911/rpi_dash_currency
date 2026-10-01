import json
import os
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
os.environ.setdefault("ADMIN_PASSWORD", "test-password")
sys.path.insert(0, str(ROOT))

from helpers import storage  # noqa: E402
from helpers.remote import validate_payload  # noqa: E402

OLD_FILE = {
    "currencies": [
        {"code": "USD", "name": "US Dollar", "symbol": "$", "price": 5, "flag": None, "enabled": True},
        {"code": "EUR", "name": "Euro", "symbol": "", "price": 6, "flag": None, "enabled": True},
    ],
    "settings": {"title": "Old", "subtitle": "Sub", "color_palette": "midnight", "show_updated_at": True},
    "updated_at": 1,
}


class RowsMigrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        storage.DATA_FILE = os.path.join(self.tmp.name, "data.json")
        storage._data_cache.update(mtime=None, data=None)

    def tearDown(self):
        self.tmp.cleanup()

    def test_old_file_becomes_row_one_and_keeps_legacy_keys(self):
        with open(storage.DATA_FILE, "w") as f:
            json.dump(OLD_FILE, f)
        d = storage.load_data()
        self.assertEqual([r["enabled"] for r in d["rows"]], [True, False])
        self.assertEqual(d["rows"][1]["title"], "Old")  # row 2 = disabled copy of row 1
        self.assertEqual(d["rows"][1]["currencies"], d["rows"][0]["currencies"])
        self.assertEqual(d["rows"][0]["title"], "Old")
        self.assertEqual([c["code"] for c in d["rows"][0]["currencies"]], ["USD", "EUR"])
        saved = json.load(open(storage.DATA_FILE))
        self.assertEqual(saved["settings"]["title"], "Old")  # old code can still read the file
        self.assertEqual([c["code"] for c in saved["currencies"]], ["USD", "EUR"])

    def test_migration_is_idempotent(self):
        with open(storage.DATA_FILE, "w") as f:
            json.dump(OLD_FILE, f)
        first = storage.load_data()
        storage._data_cache.update(mtime=None, data=None)
        self.assertEqual(storage.load_data()["rows"], first["rows"])


class PayloadTest(unittest.TestCase):
    base = {"schema": 1, "version": 3, "settings": {"title": "T", "subtitle": "", "color_palette": "midnight"}}
    cur = [{"code": "USD", "name": "Dollar", "symbol": "$", "price": 1, "flag": None, "enabled": True}]

    def test_old_server_payload_becomes_row_one(self):
        clean, err = validate_payload({**self.base, "currencies": self.cur})
        self.assertIsNone(err)
        self.assertEqual([r["enabled"] for r in clean["rows"]], [True, False])

    def test_two_row_payload(self):
        rows = [{"enabled": True, "title": "A", "subtitle": "", "currencies": self.cur},
                {"enabled": True, "title": "B", "subtitle": "", "currencies": self.cur}]
        clean, err = validate_payload({**self.base, "currencies": self.cur, "rows": rows})
        self.assertIsNone(err)
        self.assertEqual([r["title"] for r in clean["rows"]], ["A", "B"])

    def test_row_over_four_currencies_rejected(self):
        many = [dict(self.cur[0], code=f"C{i}") for i in range(5)]
        _, err = validate_payload({**self.base, "rows": [{"enabled": True, "title": "A", "subtitle": "", "currencies": many}]})
        self.assertIsNotNone(err)


class PriceTest(unittest.TestCase):
    def test_up_to_two_decimals(self):
        from helpers.validation import parse_price
        self.assertEqual(parse_price("1.20"), 1.2)
        self.assertEqual(parse_price("5"), 5)
        self.assertEqual(parse_price("0.25"), 0.25)
        for bad in ("1.234", "1.", ".5", "abc", "1000000.01", "-1"):
            self.assertIsNone(parse_price(bad), bad)


class SyncFailingTest(unittest.TestCase):
    def test_dot_only_after_a_minute_of_failures_in_url_mode(self):
        import time
        from helpers import remote
        real = remote.get_source
        try:
            now = int(time.time())
            for mode, fail_since, expected in (("url", now - 30, False), ("url", now - 61, True),
                                               ("url", 0, False), ("manual", now - 600, False)):
                remote.get_source = lambda m=mode, f=fail_since: {"mode": m, "fail_since": f}
                self.assertEqual(remote.sync_failing(), expected, (mode, fail_since))
        finally:
            remote.get_source = real
        self.assertEqual((remote.POLL_SECONDS, remote.RETRY_SECONDS, remote.FAIL_DOT_SECONDS), (60, 15, 60))


if __name__ == "__main__":
    unittest.main()
