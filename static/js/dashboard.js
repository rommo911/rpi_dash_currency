const MAX_DISPLAYED_CURRENCIES = 5;
const PAGE_LOAD_VERSION = window.PAGE_LOAD_VERSION;

let lastUpdatedAt = null;
let lastCount = 0;
let lastHostInfo = { hostname: '', ip: '' };
let lastPrices = {}; // code -> price, for the update-flash effect

// code -> card element, kept across renders instead of rebuilding all
// cards from scratch on every poll (was a visible stutter on weak GPUs).
const cardEls = new Map();
let currentValueSize = 0; // px — last computed by layoutGrid(), reused by fitValueText()

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

// Shows hostname/IP once for 10s, 2min after load — not a repeating cycle.
setTimeout(showHostInfo, 120000);

function fmt(n) {
  if (n === null || n === undefined) return '—';
  return Number(n).toLocaleString(undefined, {minimumFractionDigits: 1, maximumFractionDigits: 2});
}

function esc(s) {
  // Escapes quotes too — safe for attribute contexts, unlike textContent.
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

// Fixed UI label (unlike currency names/title), so it follows admin_language.
const LAST_UPDATED_LABEL = { en: 'Last updated', ar: 'آخر تحديث' };

function pad2(n) { return String(n).padStart(2, '0'); }

// Fixed HH:MM:SS DD/MM/YYYY — not toLocaleString(), which varies by locale.
function formatDateTime(dt) {
  const time = `${pad2(dt.getHours())}:${pad2(dt.getMinutes())}:${pad2(dt.getSeconds())}`;
  const date = `${pad2(dt.getDate())}/${pad2(dt.getMonth() + 1)}/${dt.getFullYear()}`;
  return `${time} ${date}`;
}

// Picks the cols/rows split with the largest resulting cell, not a fixed
// column count — so N cards always fill the screen well.
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

// fitValueText — sizes one price to fit on one line. Uses currentValueSize
// from the last layoutGrid() call rather than recomputing grid geometry.
function fitValueText(valueEl) {
  const textLength = Math.max(1, valueEl.textContent.trim().length);
  const width = valueEl.getBoundingClientRect().width;
  const fittedSize = width / textLength * 1.55;
  valueEl.style.fontSize = Math.min(currentValueSize, fittedSize) + 'px';
}

// layoutGrid — full grid + card resize. Only on card-count change or
// resize, not every poll — see refresh()'s structuralChange check.
function layoutGrid() {
  const gridWrap = document.getElementById('grid-wrap');
  const grid = gridWrap.querySelector('.grid');
  if (!grid || lastCount === 0) return;
  const rect = gridWrap.getBoundingClientRect();
  const gapX = window.innerWidth * 0.02;
  const gapY = window.innerHeight * 0.02;
  const { cols, rows, cellSize } = bestGridSplit(lastCount, rect.width, rect.height, gapX, gapY);
  grid.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
  grid.style.gridTemplateRows = `repeat(${rows}, 1fr)`;

  // Budgets real pixels (padding/gaps first) — guessing fractions of
  // cellSize let digits get clipped at some sizes.
  const compactLayout = lastCount <= 2;
  const cardPad = cellSize * (compactLayout ? 0.045 : 0.075);
  const cardGap = cellSize * (compactLayout ? 0.025 : 0.055);
  grid.style.setProperty('--card-pad', cardPad + 'px');
  grid.style.setProperty('--card-gap', cardGap + 'px');

  const available = Math.max(20, cellSize - cardPad * 2 - cardGap * 3);
  // Price > code > name in size; icon gets the largest share (recognizable
  // from across a room).
  const iconScale = 0.85;
  const iconHeight = available * (compactLayout ? 0.36 : 0.30) * iconScale;
  grid.style.setProperty('--icon-h', compactLayout ? iconHeight + 'px' : 'auto');
  // For two cards, derive the image width from its capped height. This keeps
  // the 3:2 image visible without allowing its width to consume the row.
  grid.style.setProperty('--icon-w', compactLayout ? (iconHeight * 1.5) + 'px' : (95 * iconScale) + '%');
  grid.style.setProperty('--code-size', (available * (compactLayout ? 0.12 : 0.22)) + 'px');
  grid.style.setProperty('--name-size', (available * (compactLayout ? 0.075 : 0.14)) + 'px');
  currentValueSize = available * (compactLayout ? 0.22 : 0.38);
  grid.style.setProperty('--value-size', currentValueSize + 'px');

  grid.querySelectorAll('.value').forEach(fitValueText);
}

// buildCard — one-time DOM build for a new currency, via innerHTML so
// esc()/safeFlagSrc() are required (see CLAUDE.md).
function buildCard(c) {
  const card = document.createElement('div');
  card.className = 'card';
  card.innerHTML = `
    <div class="icon-badge">${c.flag ? `<img src="${safeFlagSrc(c.flag)}" alt="${esc(c.name)} flag">` : ''}</div>
    <div class="code">${esc(c.code)}</div>
    <div class="name">${esc(c.name)}</div>
    <div class="value">${esc(c.symbol)}${fmt(c.price)}</div>
  `;
  return card;
}

async function refresh() {
  try {
    const res = await fetch('/api/data');
    if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
    }
    const d = await res.json();

    if (d.app_version && d.app_version !== PAGE_LOAD_VERSION) {
      // A redeploy swapped in new code after this tab loaded — a service
      // restart alone wouldn't touch an already-open kiosk tab.
      location.reload();
      return;
    }

    lastHostInfo = { hostname: d.hostname || '', ip: d.ip || '' };

    if (d.updated_at === lastUpdatedAt) {
      return; // nothing changed since last poll — skip the re-render
    }
    lastUpdatedAt = d.updated_at;

    if (d.color_palette) {
      document.documentElement.dataset.palette = d.color_palette;
    }
    // Effect toggles, kept live in sync same as color_palette.
    document.body.classList.toggle('fx-glass', !!d.fx_glass);
    document.body.classList.toggle('fx-scan', !!d.fx_scan);
    document.body.classList.toggle('fx-flash', !!d.fx_flash);
    document.body.classList.toggle('fx-glow', !!d.fx_glow);

    document.getElementById('dash-title').textContent = d.title || '';
    document.getElementById('dash-subtitle').textContent = d.subtitle || '';

    const wrap = document.getElementById('grid-wrap');
    // The screen is sized for a handful of big tiles, not a scrolling
    // list — cap what's shown even if more are enabled in the panel.
    const shown = (d.currencies || []).slice(0, MAX_DISPLAYED_CURRENCIES);
    // Only a change in WHICH currencies show needs a full re-layout —
    // a price tick alone doesn't change geometry.
    const newCodes = new Set(shown.map(c => c.code));
    const structuralChange = newCodes.size !== cardEls.size || [...newCodes].some(code => !cardEls.has(code));
    lastCount = shown.length;

    if (lastCount === 0) {
      wrap.innerHTML = '<div class="empty">No currencies enabled. Add or enable some from the control panel.</div>';
      cardEls.clear();
    } else {
      let grid = wrap.querySelector('.grid');
      if (!grid) {
        wrap.innerHTML = '';
        grid = document.createElement('div');
        grid.className = 'grid';
        wrap.appendChild(grid);
      }

      const changedValueEls = [];
      shown.forEach(c => {
        // undefined = first time seeing this currency — never flash that.
        const priceChanged = lastPrices[c.code] !== undefined && lastPrices[c.code] !== c.price;
        let card = cardEls.get(c.code);
        if (!card) {
          card = buildCard(c);
          cardEls.set(c.code, card);
        } else {
          const codeEl = card.querySelector('.code');
          if (codeEl.textContent !== c.code) codeEl.textContent = c.code;
          const nameEl = card.querySelector('.name');
          if (nameEl.textContent !== c.name) nameEl.textContent = c.name;
          const iconEl = card.querySelector('.icon-badge');
          const wantedFlag = safeFlagSrc(c.flag);
          const currentFlag = iconEl.querySelector('img');
          if (wantedFlag !== (currentFlag ? currentFlag.getAttribute('src') : '')) {
            // The one spot here still touching innerHTML — same esc()
            // rule as buildCard() applies.
            iconEl.innerHTML = wantedFlag ? `<img src="${wantedFlag}" alt="${esc(c.name)} flag">` : '';
          }
          const valueEl = card.querySelector('.value');
          const wantedValue = `${c.symbol || ''}${fmt(c.price)}`;
          if (valueEl.textContent !== wantedValue) {
            valueEl.textContent = wantedValue;
            changedValueEls.push(valueEl);
          }
        }
        if (priceChanged && d.fx_flash) {
          // Replaying a CSS animation needs remove -> reflow -> re-add.
          card.classList.remove('flash');
          void card.offsetWidth;
          card.classList.add('flash');
          // Must come back off (card is persistent now) — the class also
          // carries overflow:visible in CSS, which can't stay on forever.
          card.addEventListener('animationend', () => card.classList.remove('flash'), { once: true });
        }
        // appendChild on an existing child MOVES it — keeps DOM order in
        // sync with `shown` with no separate reorder pass.
        grid.appendChild(card);
      });

      for (const [code, el] of cardEls) {
        if (!newCodes.has(code)) {
          el.remove();
          cardEls.delete(code);
        }
      }

      lastPrices = Object.fromEntries(shown.map(c => [c.code, c.price]));

      if (structuralChange) {
        layoutGrid(); // re-measures every card — only worth it when the set changed
      } else if (changedValueEls.length) {
        changedValueEls.forEach(fitValueText); // just the cards whose value text actually changed
      }
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
  resizeTimer = setTimeout(layoutGrid, 100);
});

refresh();
setInterval(refresh, 5000);
