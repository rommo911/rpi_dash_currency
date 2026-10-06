import base64
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
os.environ.setdefault("ADMIN_PASSWORD", "test-password")
sys.path.insert(0, str(ROOT))

from core import app  # noqa: E402
from helpers import remote, storage  # noqa: E402
from helpers.remote import apply_payload, validate_payload  # noqa: E402
from helpers.security import csrf_token  # noqa: E402
from routes import admin, admin_source, admin_system, dashboard  # noqa: E402,F401  (registers the routes)

# A data.json as written by the release before rows existed (flat list, no layout).
OLD_FILE = {
    "currencies": [
        {"code": "USD", "name": "US Dollar", "symbol": "$", "price": 5, "flag": "/static/flags/us.png", "enabled": True},
        {"code": "EUR", "name": "Euro", "symbol": "E", "price": 6.5, "flag": "/static/flags/eu.png", "enabled": True},
        {"code": "TRY", "name": "Lira", "symbol": "T", "price": 7, "flag": "/static/flags/tr.png", "enabled": False},
    ],
    "settings": {"title": "Old", "subtitle": "Sub", "color_palette": "sunset", "show_updated_at": True, "admin_language": "ar"},
    "updated_at": 1,
}
AUTH = {"Authorization": "Basic " + base64.b64encode(b"admin:test-password").decode()}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.patches = [
            mock.patch.object(storage, "DATA_FILE", os.path.join(t, "data.json")),
            mock.patch.object(remote, "SOURCE_FILE", os.path.join(t, "source.json")),
            mock.patch.object(remote, "SNAPSHOTS", {"manual": os.path.join(t, "l.json"), "url": os.path.join(t, "r.json")}),
        ]
        for p in self.patches:
            p.start()
        storage.invalidate_cache()
        self.client = app.test_client()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def write(self, obj):
        with open(storage.DATA_FILE, "w") as f:
            json.dump(obj, f)
        storage.invalidate_cache()

    def post(self, path, **data):
        return self.client.post(path, headers=AUTH, data={"csrf_token": csrf_token(), **data})


class LayoutMigrationTest(Base):
    def test_old_file_stays_cards_and_gets_no_matrix(self):
        self.write(OLD_FILE)
        d = storage.load_data()
        self.assertEqual(d["settings"]["layout"], "cards")
        self.assertNotIn("matrix", d)
        self.assertEqual([c["code"] for c in d["rows"][0]["currencies"]], ["USD", "EUR", "TRY"])

    def test_switching_layouts_keeps_each_ones_data(self):
        self.write(OLD_FILE)
        cards_before = storage.load_data()["rows"]
        self.assertEqual(self.post("/admin/layout", layout="matrix").status_code, 302)
        d = storage.load_data()
        m = d["matrix"]
        self.assertEqual(d["settings"]["layout"], "matrix")
        self.assertEqual([c["code"] for c in m["currencies"]], ["USD", "EUR", "TRY"])
        self.assertEqual(m["rows"][0]["prices"], {"USD": 5, "EUR": 6.5, "TRY": 7})
        self.assertGreaterEqual(sum(r["enabled"] for r in m["rows"]), 2)
        self.assertEqual(d["rows"], cards_before)  # card data untouched
        self.post("/admin/layout", layout="cards")
        d = storage.load_data()
        self.assertEqual(d["settings"]["layout"], "cards")
        self.assertEqual(d["rows"], cards_before)
        self.assertIn("matrix", d)  # kept for the next switch

    def test_load_is_idempotent_in_matrix_mode(self):
        self.write(OLD_FILE)
        self.post("/admin/layout", layout="matrix")
        a = storage.load_data()
        storage.invalidate_cache()
        self.assertEqual(storage.load_data(), a)

    def test_api_data_matrix_rows_share_currencies(self):
        self.write(OLD_FILE)
        self.post("/admin/layout", layout="matrix")
        j = self.client.get("/api/data").get_json()
        self.assertEqual(j["layout"], "matrix")
        self.assertGreaterEqual(len(j["rows"]), 2)
        self.assertEqual({tuple(c["code"] for c in r["currencies"]) for r in j["rows"]}, {("USD", "EUR")})  # TRY is switched off
        self.assertEqual(j["admin_language"], "ar")

    def test_api_data_cards_has_layout_key(self):
        self.write(OLD_FILE)
        self.assertEqual(self.client.get("/api/data").get_json()["layout"], "cards")


class MatrixAdminTest(Base):
    def setUp(self):
        super().setUp()
        self.write(OLD_FILE)
        self.post("/admin/layout", layout="matrix")

    def form(self, **over):
        m = storage.load_data()["matrix"]
        f = {"color_palette": "midnight", "show_updated_at": "on"}
        for c in m["currencies"]:
            f[f"m_name_{c['code']}"] = c["name"]
            f[f"m_symbol_{c['code']}"] = c["symbol"]
            f[f"m_enabled_{c['code']}"] = "on"
        for n, r in enumerate(m["rows"]):
            if r["enabled"]:
                f[f"mr{n}_enabled"] = "on"
            f[f"mr{n}_title"] = r["title"] or f"T{n}"
            f[f"mr{n}_subtitle"] = r["subtitle"]
            for code, price in r["prices"].items():
                f[f"mr{n}_price_{code}"] = str(price)
        f.update(over)
        return f

    def test_save_prices_and_titles_per_row(self):
        f = self.form(mr2_enabled="on", mr2_title="Third", mr2_price_USD="530", mr2_price_EUR="5710.25", mr2_price_TRY="1")
        r = self.post("/admin/save-all", **f)
        self.assertNotIn("error", r.location)
        m = storage.load_data()["matrix"]
        self.assertEqual(m["rows"][2]["title"], "Third")
        self.assertEqual(m["rows"][2]["prices"]["EUR"], 5710.25)
        self.assertTrue(m["rows"][2]["enabled"])

    def test_needs_two_rows_and_valid_prices(self):
        f = self.form()
        f.pop("mr1_enabled", None); f.pop("mr2_enabled", None)
        self.assertIn("error", self.post("/admin/save-all", **f).location)
        self.assertIn("error", self.post("/admin/save-all", **self.form(mr0_price_USD="1.234")).location)
        self.assertIn("error", self.post("/admin/save-all", **self.form(mr0_title="")).location)

    def test_add_and_delete_shared_currency(self):
        with mock.patch.object(admin, "fetch_suggested_flag", return_value="/static/flags/sy.png"):
            r = self.post("/admin/matrix/currency/add", code="syp", name="Pound", symbol="", price="9", flag_source="auto")
        self.assertNotIn("error", r.location, r.location)
        m = storage.load_data()["matrix"]
        self.assertEqual([c["code"] for c in m["currencies"]][-1], "SYP")
        self.assertTrue(all(r["prices"]["SYP"] == 9 for r in m["rows"]))
        # 4 is the maximum
        with mock.patch.object(admin, "fetch_suggested_flag", return_value="/static/flags/gb.png"):
            self.assertIn("error", self.post("/admin/matrix/currency/add", code="gbp", name="P", symbol="", price="1").location)
        with mock.patch.object(admin, "delete_flag_file"):
            self.post("/admin/matrix/currency/SYP/delete")
        m = storage.load_data()["matrix"]
        self.assertEqual([c["code"] for c in m["currencies"]], ["USD", "EUR", "TRY"])
        self.assertTrue(all("SYP" not in r["prices"] for r in m["rows"]))

    def test_cannot_go_below_two_currencies(self):
        with mock.patch.object(admin, "delete_flag_file"):
            self.post("/admin/matrix/currency/TRY/delete")
            self.assertIn("error", self.post("/admin/matrix/currency/EUR/delete").location)
        self.assertEqual(len(storage.load_data()["matrix"]["currencies"]), 2)

    def test_admin_page_renders_in_both_layouts(self):
        r = self.client.get("/admin", headers=AUTH)
        self.assertEqual(r.status_code, 200)
        self.assertIn(b'name="mr0_price_USD"', r.data)
        self.assertNotIn(b'name="r0_title"', r.data)
        self.post("/admin/layout", layout="cards")
        r = self.client.get("/admin", headers=AUTH)
        self.assertIn(b'name="r0_title"', r.data)
        self.assertNotIn(b'name="mr0_title"', r.data)


class PayloadTest(Base):
    base = {"schema": 1, "version": 3, "settings": {"title": "T", "subtitle": "", "color_palette": "midnight", "layout": "matrix"}}

    def cur(self, price, flag="https://x/f.png"):
        return [{"code": "USD", "name": "Dollar", "symbol": "$", "price": price, "flag": flag, "enabled": True},
                {"code": "EUR", "name": "Euro", "symbol": "E", "price": price * 2, "flag": flag, "enabled": True}]

    def rows3(self):
        row = lambda n, p: {"enabled": True, "title": f"R{n}", "subtitle": "", "currencies": self.cur(p)}  # noqa: E731
        return [row(1, 10), row(2, 20)], [row(3, 30)]

    def test_three_row_matrix_payload_validates(self):
        rows, more = self.rows3()
        clean, err = validate_payload({**self.base, "rows": rows, "more_rows": more})
        self.assertIsNone(err)
        self.assertEqual(clean["settings"]["layout"], "matrix")
        self.assertEqual([r["title"] for r in clean["rows"]], ["R1", "R2", "R3"])

    def test_cards_payload_with_three_rows_is_rejected(self):
        rows, more = self.rows3()
        base = {**self.base, "settings": {**self.base["settings"], "layout": "cards"}}
        _, err = validate_payload({**base, "rows": rows, "more_rows": more})
        self.assertIsNotNone(err)

    def test_payload_without_layout_means_cards(self):
        rows, _ = self.rows3()
        base = {**self.base, "settings": {k: v for k, v in self.base["settings"].items() if k != "layout"}}
        clean, err = validate_payload({**base, "rows": rows})
        self.assertIsNone(err)
        self.assertEqual(clean["settings"]["layout"], "cards")

    def test_apply_matrix_then_cards_keeps_both(self):
        self.write(OLD_FILE)
        rows, more = self.rows3()
        clean, _ = validate_payload({**self.base, "rows": rows, "more_rows": more})
        with mock.patch.object(remote, "_sync_flag", return_value="/static/flags/us.png"):
            apply_payload(clean, False)
        d = storage.load_data()
        self.assertEqual(d["settings"]["layout"], "matrix")
        self.assertEqual([r["prices"]["EUR"] for r in d["matrix"]["rows"]], [20, 40, 60])
        self.assertEqual(d["rows"][0]["title"], "Old")  # card data was not overwritten by a matrix payload
        cards = {**self.base, "settings": {**self.base["settings"], "layout": "cards"}, "version": 4, "rows": rows}
        clean, _ = validate_payload(cards)
        with mock.patch.object(remote, "_sync_flag", return_value="/static/flags/us.png"):
            apply_payload(clean, False)
        d = storage.load_data()
        self.assertEqual(d["settings"]["layout"], "cards")
        self.assertEqual(d["rows"][0]["title"], "R1")
        self.assertEqual(len(d["matrix"]["rows"]), 3)


if __name__ == "__main__":
    unittest.main()
