const MAX_DISPLAYED_CURRENCIES = 5;
const PAGE_LOAD_VERSION = window.PAGE_LOAD_VERSION;

// Single kill switch for every visual effect (card border scan, frosted
// glass, price glow pulse, update flash — see dashboard.css's `fx-on`
// rules). Flip to false on weak boards (Pi Zero) where the continuous
// CSS animations cost real CPU/GPU. Nothing else needs to change.
const EFFECTS_ENABLED = true;
document.body.classList.toggle('fx-on', EFFECTS_ENABLED);

let lastUpdatedAt = null;
let lastCount = 0;
let lastHostInfo = { hostname: '', ip: '' };
let lastPrices = {}; // code -> price, for the update-flash effect

let hostInfoShown = false;

function showHostInfo() {
  if (hostInfoShown) return;
  const el = document.getElementById('hostinfo');
  if (!lastHostInfo.hostname && !lastHostInfo.ip) return;
  hostInfoShown = true;
  // textContent, not innerHTML — no escaping needed, the browser can't
  // interpret this as markup regardless of what the values contain.
  el.textContent = [lastHostInfo.hostname, lastHostInfo.ip].filter(Boolean).join('   ');
  el.classList.add('show');
  setTimeout(() => el.classList.remove('show'), 10000);
}

// Show the hostname/IP once — 10s, starting 2 minutes after page load —
// not a repeating cycle. Stays hidden after that until the kiosk session
// restarts (service restart or reboot reloads the page, resetting
// hostInfoShown).
setTimeout(showHostInfo, 120000);

function fmt(n) {
  if (n === null || n === undefined) return '—';
  return Number(n).toLocaleString(undefined, {minimumFractionDigits: 1, maximumFractionDigits: 2});
}

function esc(s) {
  // Full escaper (incl. quotes) — safe for both text and attribute
  // contexts, unlike a textContent/innerHTML round-trip which leaves
  // quote characters untouched.
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function safeFlagSrc(src) {
  // Only ever expect a same-origin /static/flags/... path from the API.
  // Reject anything else (e.g. a javascript: URL) before it reaches src=.
  return typeof src === 'string' && src.startsWith('/static/flags/') ? esc(src) : '';
}

// "Last updated" label only — not free text the admin typed, so (unlike
// currency names/dashboard title, which are never auto-translated by
// design) this follows admin_language like the /admin UI chrome does.
const LAST_UPDATED_LABEL = { en: 'Last updated', ar: 'آخر تحديث' };

function pad2(n) { return String(n).padStart(2, '0'); }

// Fixed HH:MM:SS DD/MM/YYYY (24h, zero-padded) regardless of browser/OS
// locale — toLocaleString() output varies unpredictably by locale, which
// is exactly what a wall-mounted kiosk display shouldn't have.
function formatDateTime(dt) {
  const time = `${pad2(dt.getHours())}:${pad2(dt.getMinutes())}:${pad2(dt.getSeconds())}`;
  const date = `${pad2(dt.getDate())}/${pad2(dt.getMonth() + 1)}/${dt.getFullYear()}`;
  return `${time} ${date}`;
}

// Picks the column/row split (out of every split that fits n cards) whose
// resulting cell is the largest — so 2 cards fill the screen as two big
// tiles, 3 as three, 7 as a balanced 4x2ish block, and so on, instead of
// a fixed column count leaving unused space.
function bestGridSplit(n, w, h, gapX, gapY) {
  let best = null;
  for (let cols = 1; cols <= n; cols++) {
    const rows = Math.ceil(n / cols);
    const cellW = (w - gapX * (cols - 1)) / cols;
    const cellH = (h - gapY * (rows - 1)) / rows;
    if (cellW <= 0 || cellH <= 0) continue;
    const cellSize = Math.min(cellW, cellH);
    if (!best || cellSize > best.cellSize) {
      best = { cols, rows, cellSize };
    }
  }
  return best || { cols: 1, rows: 1, cellSize: Math.min(w, h) };
}

function fitGrid() {
  const gridWrap = document.getElementById('grid-wrap');
  const grid = gridWrap.querySelector('.grid');
  if (!grid || lastCount === 0) return;
  const rect = gridWrap.getBoundingClientRect();
  const gapX = window.innerWidth * 0.02;
  const gapY = window.innerHeight * 0.02;
  const { cols, rows, cellSize } = bestGridSplit(lastCount, rect.width, rect.height, gapX, gapY);
  grid.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
  grid.style.gridTemplateRows = `repeat(${rows}, 1fr)`;

  // Budget the cell's actual pixels (padding + gaps first) instead of
  // guessing fixed fractions of cellSize — that's what let the price
  // digits get clipped once cells got bigger/smaller than expected.
  const compactLayout = lastCount <= 2;
  const cardPad = cellSize * (compactLayout ? 0.045 : 0.075);
  const cardGap = cellSize * (compactLayout ? 0.025 : 0.055);
  grid.style.setProperty('--card-pad', cardPad + 'px');
  grid.style.setProperty('--card-gap', cardGap + 'px');

  const available = Math.max(20, cellSize - cardPad * 2 - cardGap * 3);
  // Price is the star of the card: bigger than the code, which is
  // bigger than the currency name. Icon gets the single largest share
  // since it's the most recognizable element from across a room.
  const iconScale = 0.85;
  const iconHeight = available * (compactLayout ? 0.36 : 0.30) * iconScale;
  grid.style.setProperty('--icon-h', compactLayout ? iconHeight + 'px' : 'auto');
  // For two cards, derive the image width from its capped height. This keeps
  // the 3:2 image visible without allowing its width to consume the row.
  grid.style.setProperty('--icon-w', compactLayout ? (iconHeight * 1.5) + 'px' : (95 * iconScale) + '%');
  grid.style.setProperty('--code-size', (available * (compactLayout ? 0.12 : 0.22)) + 'px');
  grid.style.setProperty('--name-size', (available * (compactLayout ? 0.075 : 0.14)) + 'px');
  const valueSize = available * (compactLayout ? 0.22 : 0.38);
  grid.style.setProperty('--value-size', valueSize + 'px');

  // Keep every formatted price on one line without ellipsis. Longer values
  // get a smaller font, while short values keep the largest possible size.
  grid.querySelectorAll('.value').forEach(value => {
    const textLength = Math.max(1, value.textContent.trim().length);
    const width = value.getBoundingClientRect().width;
    const fittedSize = width / textLength * 1.55;
    value.style.fontSize = Math.min(valueSize, fittedSize) + 'px';
  });
}

async function refresh() {
  try {
    const res = await fetch('/api/data');
    if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
    }
    const d = await res.json();

    if (d.app_version && d.app_version !== PAGE_LOAD_VERSION) {
      // A deploy/auto-update swapped in new app code (e.g. changed JS in
      // this very file) after this tab's page was loaded — restarting
      // the systemd service does not touch an already-open kiosk tab, so
      // without this the kiosk would keep running stale JS indefinitely.
      location.reload();
      return;
    }

    lastHostInfo = { hostname: d.hostname || '', ip: d.ip || '' };

    if (d.updated_at === lastUpdatedAt) {
      return; // nothing changed since last poll — skip the re-render
    }
    lastUpdatedAt = d.updated_at;

    document.getElementById('dash-title').textContent = d.title || '';
    document.getElementById('dash-subtitle').textContent = d.subtitle || '';

    const wrap = document.getElementById('grid-wrap');
    // The screen is sized for a handful of big tiles, not a scrolling
    // list — cap what's shown even if more are enabled in the panel.
    const shown = (d.currencies || []).slice(0, MAX_DISPLAYED_CURRENCIES);
    lastCount = shown.length;
    if (lastCount === 0) {
      wrap.innerHTML = '<div class="empty">No currencies enabled. Add or enable some from the control panel.</div>';
    } else {
      const grid = document.createElement('div');
      grid.className = 'grid';
      const nextPrices = {};
      shown.forEach(c => {
        const card = document.createElement('div');
        // lastPrices[c.code] === undefined means "first time we've seen
        // this currency" (page just loaded, or it was just enabled) —
        // never flash that, only an actual change from a known value.
        const changed = EFFECTS_ENABLED && lastPrices[c.code] !== undefined && lastPrices[c.code] !== c.price;
        card.className = changed ? 'card flash' : 'card';
        card.innerHTML = `
          <div class="icon-badge">${c.flag ? `<img src="${safeFlagSrc(c.flag)}" alt="${esc(c.name)} flag">` : ''}</div>
          <div class="code">${esc(c.code)}</div>
          <div class="name">${esc(c.name)}</div>
          <div class="value">${esc(c.symbol)}${fmt(c.price)}</div>
        `;
        grid.appendChild(card);
        nextPrices[c.code] = c.price;
      });
      lastPrices = nextPrices;
      wrap.innerHTML = '';
      wrap.appendChild(grid);
      fitGrid();
    }

    document.getElementById('footer').hidden = !d.show_updated_at;
    const updated = document.getElementById('updated-at');
    if (d.updated_at) {
      const dt = new Date(d.updated_at * 1000);
      const label = LAST_UPDATED_LABEL[d.admin_language] || LAST_UPDATED_LABEL.en;
      updated.textContent = `${label} ${formatDateTime(dt)}`;
    }
  } catch (e) {
    document.getElementById('updated-at').textContent = 'Could not load data';
  }
}

let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(fitGrid, 100);
});

refresh();
setInterval(refresh, 5000);
