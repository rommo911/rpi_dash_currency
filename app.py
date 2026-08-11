#!/usr/bin/env python3
"""Currency dashboard: static amount in a chosen base currency, converted
live to all other supported currencies.

Single-file Flask app: dashboard at /, control panel at /admin.
Rates are fetched from open.er-api.com (free, no API key) using USD as the
pivot base, since most of these currencies aren't valid `base` currencies on
free providers.
"""
import json
import os
import time
import threading

from flask import Flask, Response, jsonify, render_template_string, request

import config

APP_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(APP_DIR, "data.json")
RATES_URL = "https://open.er-api.com/v6/latest/USD"
RATES_TTL = 300  # seconds

CURRENCIES = {
    "SYP": {"flag": "/static/flags/sy.png", "symbol": "", "name": "Syrian Pound"},
    "USD": {"flag": "/static/flags/us.png", "symbol": "$", "name": "US Dollar"},
    "EUR": {"flag": "/static/flags/eu.png", "symbol": "€", "name": "Euro"},
    "TRY": {"flag": "/static/flags/tr.png", "symbol": "₺", "name": "Turkish Lira"},
}
DEFAULT_BASE = "SYP"
DEFAULT_AMOUNT = 700000

app = Flask(__name__)

_rates_lock = threading.Lock()
_rates_cache = {"data": None, "fetched_at": 0, "error": None}


def load_data():
    if not os.path.exists(DATA_FILE):
        return {"base_currency": DEFAULT_BASE, "amount": DEFAULT_AMOUNT}
    with open(DATA_FILE) as f:
        data = json.load(f)
    if "base_currency" not in data:
        # Migrate from the old single-currency (syp_amount) format.
        data = {"base_currency": DEFAULT_BASE, "amount": data.get("syp_amount", DEFAULT_AMOUNT)}
    if data["base_currency"] not in CURRENCIES:
        data["base_currency"] = DEFAULT_BASE
    return data


def save_data(data):
    with open(DATA_FILE, "w") as f:
        json.dump(data, f, indent=2)


def get_rates():
    """Return USD-based rates dict, cached for RATES_TTL seconds."""
    import urllib.request

    with _rates_lock:
        now = time.time()
        if _rates_cache["data"] and (now - _rates_cache["fetched_at"] < RATES_TTL):
            return _rates_cache["data"], _rates_cache["error"]
        try:
            req = urllib.request.Request(RATES_URL, headers={"User-Agent": "currency-dashboard"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                payload = json.loads(resp.read().decode())
            rates = payload["rates"]
            _rates_cache["data"] = rates
            _rates_cache["fetched_at"] = now
            _rates_cache["error"] = None
            return rates, None
        except Exception as exc:  # noqa: BLE001 - surface any fetch failure to UI
            _rates_cache["error"] = str(exc)
            # Fall back to stale cache if we have one, otherwise propagate.
            if _rates_cache["data"]:
                return _rates_cache["data"], str(exc)
            return None, str(exc)


def compute_conversion(base_currency, amount):
    rates, error = get_rates()
    result = {
        "base_currency": base_currency,
        "amount": amount,
        "values": {},
        "updated_at": int(_rates_cache["fetched_at"]) if _rates_cache["fetched_at"] else None,
        "error": error,
    }
    if not rates:
        return result

    usd_rates = dict(rates)
    usd_rates.setdefault("USD", 1.0)

    missing = [code for code in CURRENCIES if code not in usd_rates]
    if missing:
        result["error"] = f"Missing rate(s) from provider: {', '.join(missing)}"
        return result

    usd_amount = amount / usd_rates[base_currency]
    for code in CURRENCIES:
        if code == base_currency:
            result["values"][code] = amount
        else:
            result["values"][code] = usd_amount * usd_rates[code]
    return result


DASHBOARD_HTML = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Currency Dashboard</title>
<style>
  :root {
    --bg-1: #0f172a;
    --bg-2: #1e1b4b;
    --card-bg: rgba(255, 255, 255, 0.06);
    --card-border: rgba(255, 255, 255, 0.12);
    --text-main: #f8fafc;
    --text-dim: #94a3b8;
    --accent: #22d3ee;
    --accent-2: #a78bfa;
    --accent-3: #fbbf24;
    --accent-4: #34d399;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: radial-gradient(circle at 20% 20%, var(--bg-2), var(--bg-1) 60%);
    color: var(--text-main);
    padding: 24px;
  }
  .wrap { width: 94vw; max-width: 2000px; min-width: 320px; }
  .header {
    text-align: center;
    margin-bottom: 44px;
  }
  .header h1 {
    font-size: clamp(2.2rem, 4.2vw, 3.4rem);
    margin: 0 0 12px;
    font-weight: 800;
    letter-spacing: -0.02em;
  }
  .header .sub {
    color: var(--text-dim);
    font-size: clamp(1.1rem, 1.6vw, 1.5rem);
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 28px;
  }
  @media (max-width: 1000px) {
    .wrap { width: 96vw; }
    .grid { grid-template-columns: repeat(2, 1fr); }
  }
  @media (max-width: 560px) {
    .grid { grid-template-columns: 1fr; }
  }
  .card {
    background: var(--card-bg);
    border: 1px solid var(--card-border);
    border-radius: 28px;
    padding: 48px 32px;
    backdrop-filter: blur(12px);
    transition: transform 0.2s ease;
    text-align: center;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 18px;
    min-height: 38vh;
  }
  .card:hover { transform: translateY(-4px); }
  .card.base {
    background: linear-gradient(160deg, rgba(34,211,238,0.2), rgba(167,139,250,0.14));
    border: 1px solid rgba(34,211,238,0.45);
    box-shadow: 0 0 0 1px rgba(34,211,238,0.18), 0 20px 48px -16px rgba(34,211,238,0.4);
    position: relative;
  }
  .card.base .badge {
    position: absolute;
    top: 20px;
    right: 22px;
    font-size: 0.8rem;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--accent);
    background: rgba(34,211,238,0.14);
    border: 1px solid rgba(34,211,238,0.45);
    padding: 5px 14px;
    border-radius: 999px;
    font-weight: 600;
  }
  .icon-badge {
    width: 140px;
    height: 96px;
    border-radius: 16px;
    overflow: hidden;
    box-shadow: 0 8px 24px -8px rgba(0,0,0,0.5), 0 0 0 1px var(--card-border);
    background: rgba(255,255,255,0.05);
  }
  .icon-badge img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
  .card .code {
    font-size: 1.3rem;
    color: var(--text-main);
    letter-spacing: 0.1em;
    text-transform: uppercase;
    font-weight: 700;
  }
  .card .name {
    font-size: 1.1rem;
    color: var(--text-dim);
    margin-top: -14px;
  }
  .card .value {
    font-size: clamp(2rem, 3.4vw, 2.8rem);
    font-weight: 800;
    letter-spacing: -0.01em;
    word-break: break-word;
  }
  .card.base .value {
    font-size: clamp(2.4rem, 4.6vw, 3.4rem);
  }
  .card .value.c-USD { color: var(--accent); }
  .card .value.c-EUR { color: var(--accent-2); }
  .card .value.c-TRY { color: var(--accent-3); }
  .card .value.c-SYP { color: var(--accent-4); }
  .footer {
    margin-top: 36px;
    text-align: center;
    color: var(--text-dim);
    font-size: 1rem;
  }
  .error-banner {
    display: none;
    background: rgba(239, 68, 68, 0.15);
    border: 1px solid rgba(239, 68, 68, 0.4);
    color: #fca5a5;
    padding: 10px 16px;
    border-radius: 12px;
    text-align: center;
    margin-bottom: 20px;
    font-size: 0.9rem;
  }

</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    <h1>Live Currency Dashboard</h1>
    <div class="sub">A static amount converted live via open exchange rates</div>
  </div>

  <div id="error-banner" class="error-banner">Could not refresh rates — showing last known values.</div>

  <div class="grid" id="grid"></div>

  <div class="footer">
    <div id="updated-at">Loading…</div>
  </div>
</div>

<script>
const CURRENCIES = {{ currencies | tojson }};

function fmt(n, opts) {
  if (n === null || n === undefined) return '—';
  return n.toLocaleString(undefined, opts || {maximumFractionDigits: 2});
}

async function refresh() {
  try {
    const res = await fetch('/api/data');
    const d = await res.json();
    const base = d.base_currency;
    const orderedCodes = [base, ...Object.keys(CURRENCIES).filter(c => c !== base)];

    const grid = document.getElementById('grid');
    grid.innerHTML = '';
    orderedCodes.forEach(code => {
      const meta = CURRENCIES[code];
      const isBase = code === base;
      const val = isBase ? d.amount : (d.values ? d.values[code] : null);
      const card = document.createElement('div');
      card.className = 'card' + (isBase ? ' base' : '');
      card.innerHTML = `
        ${isBase ? '<span class="badge">Base</span>' : ''}
        <div class="icon-badge"><img src="${meta.flag}" alt="${meta.name} flag"></div>
        <div class="code">${code}</div>
        <div class="name">${meta.name}</div>
        <div class="value c-${code}">${val !== null && val !== undefined ? (meta.symbol + fmt(val, isBase ? {maximumFractionDigits: 0} : undefined)) : '—'}</div>
      `;
      grid.appendChild(card);
    });

    const banner = document.getElementById('error-banner');
    banner.style.display = d.error ? 'block' : 'none';
    const updated = document.getElementById('updated-at');
    if (d.updated_at) {
      const dt = new Date(d.updated_at * 1000);
      updated.textContent = 'Rates updated ' + dt.toLocaleTimeString();
    } else {
      updated.textContent = 'Waiting for first rate fetch…';
    }
  } catch (e) {
    document.getElementById('error-banner').style.display = 'block';
  }
}

refresh();
setInterval(refresh, 30000);
</script>
</body>
</html>
"""

ADMIN_HTML = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Control Panel — Currency Dashboard</title>
<style>
  :root {
    --bg-1: #0f172a;
    --bg-2: #1e1b4b;
    --card-bg: rgba(255, 255, 255, 0.06);
    --card-border: rgba(255, 255, 255, 0.12);
    --text-main: #f8fafc;
    --text-dim: #94a3b8;
    --accent: #22d3ee;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: radial-gradient(circle at 20% 20%, var(--bg-2), var(--bg-1) 60%);
    color: var(--text-main);
    padding: 24px;
  }
  .card {
    width: 100%;
    max-width: 420px;
    background: var(--card-bg);
    border: 1px solid var(--card-border);
    border-radius: 20px;
    padding: 32px;
    backdrop-filter: blur(12px);
  }
  h1 { font-size: 1.4rem; margin: 0 0 6px; }
  p.sub { color: var(--text-dim); margin: 0 0 24px; font-size: 0.9rem; }
  label { display: block; font-size: 0.85rem; color: var(--text-dim); margin-bottom: 8px; }
  select, input[type=number] {
    width: 100%;
    padding: 14px 16px;
    font-size: 1.2rem;
    border-radius: 12px;
    border: 1px solid var(--card-border);
    background: rgba(255,255,255,0.05);
    color: var(--text-main);
    margin-bottom: 20px;
  }
  select option { background: #1e1b4b; color: var(--text-main); }
  button {
    width: 100%;
    padding: 14px;
    font-size: 1rem;
    font-weight: 600;
    border-radius: 12px;
    border: none;
    background: var(--accent);
    color: #0f172a;
    cursor: pointer;
  }
  button:hover { opacity: 0.9; }
  .msg {
    margin-top: 16px;
    text-align: center;
    color: #86efac;
    font-size: 0.9rem;
  }
  a.back {
    display: inline-block;
    margin-top: 20px;
    color: var(--text-dim);
    text-decoration: none;
    font-size: 0.85rem;
  }
  a.back:hover { color: var(--text-main); }
</style>
</head>
<body>
  <div class="card">
    <h1>⚙ Control Panel</h1>
    <p class="sub">Choose the base currency and static amount used on the dashboard. It will be converted live into the other currencies.</p>
    <form method="post">
      <label for="base_currency">Base currency</label>
      <select id="base_currency" name="base_currency">
        {% for code, meta in currencies.items() %}
        <option value="{{ code }}" {% if code == base_currency %}selected{% endif %}>{{ meta.name }} ({{ code }})</option>
        {% endfor %}
      </select>
      <label for="amount">Amount</label>
      <input type="number" step="any" min="0" id="amount" name="amount" value="{{ amount }}" required>
      <button type="submit">Save</button>
    </form>
    {% if saved %}<div class="msg">Saved — dashboard will update within 30s.</div>{% endif %}
    <a class="back" href="/">&larr; Back to dashboard</a>
  </div>
</body>
</html>
"""


@app.route("/")
def dashboard():
    return render_template_string(DASHBOARD_HTML, currencies=CURRENCIES)


@app.route("/api/data")
def api_data():
    data = load_data()
    result = compute_conversion(data["base_currency"], data["amount"])
    return jsonify(result)


def require_admin_auth():
    auth = request.authorization
    if not auth or auth.password != config.ADMIN_PASSWORD:
        return Response(
            "Authentication required.",
            401,
            {"WWW-Authenticate": 'Basic realm="Admin Panel"'},
        )
    return None


@app.route("/admin", methods=["GET", "POST"])
def admin():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized

    data = load_data()
    saved = False
    if request.method == "POST":
        try:
            base_currency = request.form["base_currency"]
            amount = float(request.form["amount"])
            if base_currency not in CURRENCIES or amount < 0:
                raise ValueError
            data["base_currency"] = base_currency
            data["amount"] = amount
            save_data(data)
            saved = True
        except (KeyError, ValueError):
            pass
    return render_template_string(
        ADMIN_HTML,
        currencies=CURRENCIES,
        base_currency=data["base_currency"],
        amount=data["amount"],
        saved=saved,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
