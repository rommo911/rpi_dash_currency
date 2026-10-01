const MAX_DISPLAYED_CURRENCIES = 4; // per row
const PAGE_LOAD_VERSION = window.PAGE_LOAD_VERSION;

let lastUpdatedAt = null;
let lastHostInfo = { hostname: '', ip: '' };
let lastPrices = {}; // "row:code" -> price, for the update-flash effect

// One entry per visible row: {block, titleEl, subEl, wrap, grid, cardEls, count, valueSize}.
// cardEls (code -> card element) is kept across renders instead of rebuilding
// all cards from scratch on every poll (was a visible stutter on weak GPUs).
let rowStates = [];

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
  return Number(n).toLocaleString(undefined, {minimumFractionDigits: 0, maximumFractionDigits: 2});
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

// fitValueText — sizes one price to fit on one line. `size` is the row's
// valueSize from its last layoutGrid() call rather than recomputed geometry.
function fitValueText(valueEl, size) {
  const textLength = Math.max(1, valueEl.textContent.trim().length);
  // The card's inner width (not the element's own: in two-row mode the price
  // row spans only the flag+text group, which is narrower than the card).
  const card = valueEl.parentElement;
  const cs = getComputedStyle(card);
  const width = card.getBoundingClientRect().width
    - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
    - parseFloat(cs.borderLeftWidth) - parseFloat(cs.borderRightWidth);
  const fittedSize = width / textLength * 1.55;
  valueEl.style.fontSize = Math.min(size, fittedSize) + 'px';
}

// layoutGrid — full grid + card resize for ONE row. Only on card-count
// change or resize, not every poll — see refresh()'s structuralChange check.
function layoutGrid(st) {
  const { grid, wrap, count } = st;
  if (!grid || count === 0) return;
  const twoRows = rowStates.length > 1;
  const rect = wrap.getBoundingClientRect();
  // Same gaps as the CSS (#rows.two .grid) so the cell math matches reality.
  const gapX = window.innerWidth * (twoRows ? 0.015 : 0.02);
  const gapY = window.innerHeight * (twoRows ? 0.025 : 0.02);
  const { cols, rows, cellSize } = bestGridSplit(count, rect.width, rect.height, gapX, gapY);
  grid.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
  grid.style.gridTemplateRows = `repeat(${rows}, 1fr)`;

  if (twoRows) {
    layoutCompactCards(st, grid, (rect.width - gapX * (cols - 1)) / cols, (rect.height - gapY * (rows - 1)) / rows);
    return;
  }

  // Budgets real pixels (padding/gaps first) — guessing fractions of
  // cellSize let digits get clipped at some sizes.
  const compactLayout = count <= 2;
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
  st.valueSize = available * (compactLayout ? 0.22 : 0.38);
  grid.style.setProperty('--value-size', st.valueSize + 'px');

  grid.querySelectorAll('.value').forEach(el => fitValueText(el, st.valueSize));
}

// Two-row mode: cells are short and wide, so the card is a grid — big flag on
// the left, code over name on its right, price full-width underneath
// (see #rows.two .card in the CSS). Sizes come from the cell's real w/h.
function layoutCompactCards(st, grid, cellW, cellH) {
  const pad = Math.min(cellH, cellW) * 0.07;
  grid.style.setProperty('--card-pad', pad + 'px');
  const innerW = Math.max(40, cellW - pad * 2);
  const innerH = Math.max(40, cellH - pad * 2);
  // Flag: up to ~46% of the inner height, never more than ~36% of the width,
  // so the code/name column and the price keep room.
  const iconH = Math.min(innerH * 0.46, innerW * 0.36 / 1.5);
  const iconW = iconH * 1.5;
  const colGap = innerW * 0.025;
  const textW = Math.max(30, innerW - iconW - colGap);
  grid.style.setProperty('--icon-h', iconH + 'px');
  grid.style.setProperty('--icon-w', iconW + 'px');
  grid.style.setProperty('--col-gap', colGap + 'px');
  grid.style.setProperty('--text-max', textW + 'px');
  grid.style.setProperty('--value-gap', innerH * 0.12 + 'px');
  grid.style.setProperty('--code-size', Math.min(iconH * 0.40, textW / 3.4) + 'px');
  grid.style.setProperty('--name-size', Math.min(iconH * 0.19, textW / 7) + 'px');
  st.valueSize = innerH * 0.32;
  grid.style.setProperty('--value-size', st.valueSize + 'px');
  grid.querySelectorAll('.value').forEach(el => fitValueText(el, st.valueSize));
}

function layoutAll() {
  rowStates.forEach(layoutGrid);
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

// One header + grid block per visible row. Returns true when the number of
// rows changed (everything must be laid out again).
function ensureRows(n) {
  if (rowStates.length === n) return false;
  const root = document.getElementById('rows');
  root.innerHTML = '';
  rowStates = [];
  for (let i = 0; i < n; i++) {
    const block = document.createElement('div');
    block.className = 'row-block';
    // Static markup only — title/subtitle are filled with textContent.
    block.innerHTML = '<div class="header"><h1></h1><div class="sub"></div></div><div class="grid-wrap"></div>';
    root.appendChild(block);
    rowStates.push({
      block, titleEl: block.querySelector('h1'), subEl: block.querySelector('.sub'),
      wrap: block.querySelector('.grid-wrap'), grid: null, cardEls: new Map(), count: 0, valueSize: 0,
    });
  }
  root.classList.toggle('two', n === 2);
  return true;
}

// Renders one row; returns true if its set of cards changed.
function renderRow(st, idx, row, fxFlash) {
  st.titleEl.textContent = row.title || '';
  st.subEl.textContent = row.subtitle || '';

  // The screen is sized for a handful of big tiles, not a scrolling
  // list — cap what's shown even if more are enabled in the panel.
  const shown = (row.currencies || []).slice(0, MAX_DISPLAYED_CURRENCIES);
  // Only a change in WHICH currencies show needs a full re-layout —
  // a price tick alone doesn't change geometry.
  const newCodes = new Set(shown.map(c => c.code));
  const structuralChange = newCodes.size !== st.cardEls.size || [...newCodes].some(code => !st.cardEls.has(code));
  st.count = shown.length;

  if (st.count === 0) {
    st.wrap.innerHTML = '<div class="empty">No currencies enabled. Add or enable some from the control panel.</div>';
    st.grid = null;
    st.cardEls.clear();
    return false;
  }
  if (!st.grid || !st.grid.isConnected) {
    st.wrap.innerHTML = '';
    st.grid = document.createElement('div');
    st.grid.className = 'grid';
    st.wrap.appendChild(st.grid);
  }

  const changedValueEls = [];
  shown.forEach(c => {
    const key = `${idx}:${c.code}`;
    // undefined = first time seeing this currency — never flash that.
    const priceChanged = lastPrices[key] !== undefined && lastPrices[key] !== c.price;
    let card = st.cardEls.get(c.code);
    if (!card) {
      card = buildCard(c);
      st.cardEls.set(c.code, card);
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
    if (priceChanged && fxFlash) {
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
    st.grid.appendChild(card);
  });

  for (const [code, el] of st.cardEls) {
    if (!newCodes.has(code)) {
      el.remove();
      st.cardEls.delete(code);
    }
  }
  shown.forEach(c => { lastPrices[`${idx}:${c.code}`] = c.price; });

  if (!structuralChange && changedValueEls.length) {
    changedValueEls.forEach(el => fitValueText(el, st.valueSize)); // just the cards whose value text actually changed
  }
  return structuralChange;
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
    // Not behind the updated_at check below: it flips without any data change.
    document.getElementById('sync-dot').hidden = !d.sync_failing;

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

    const rows = d.rows || [{ title: d.title, subtitle: d.subtitle, currencies: d.currencies }];
    let relayout = ensureRows(rows.length);
    rows.forEach((row, i) => {
      if (renderRow(rowStates[i], i, row, d.fx_flash)) relayout = true;
    });
    if (relayout) {
      layoutAll(); // re-measures every card — only worth it when the set changed
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
  resizeTimer = setTimeout(layoutAll, 100);
});

refresh();
setInterval(refresh, 5000);
