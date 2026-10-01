// type="text" (not "number") to kill the native spinner; this restores
// digits plus one optional ".dd" by hand (prices: up to 2 decimals).
function filterDecimalInput(el) {
  let v = el.value.replace(/,/g, '.').replace(/[^0-9.]/g, '');
  const dot = v.indexOf('.');
  if (dot !== -1) v = v.slice(0, dot + 1) + v.slice(dot + 1).replace(/\./g, '').slice(0, 2);
  if (v !== el.value) el.value = v;
}

// Data source: the URL, token, insecure, Test and Fetch controls only apply
// to "URL" mode, so they are disabled while "Manual" is selected.
(function () {
  const radios = document.querySelectorAll('input[name="mode"]');
  if (!radios.length) return;
  function sync() {
    const urlMode = document.querySelector('input[name="mode"]:checked')?.value === 'url';
    document.querySelectorAll('[data-url-only]').forEach(el => { el.disabled = !urlMode; });
  }
  radios.forEach(r => r.addEventListener('change', sync));
  sync();
})();
