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
  // Clicking a mode switches immediately: the server swaps in that mode's last
  // saved data. Unsaved edits in the main form would be lost, so ask first.
  const main = document.querySelector('form[action$="/admin/save-all"]');
  let dirty = false;
  if (main) main.addEventListener('input', () => { dirty = true; });
  const current = document.querySelector('input[name="mode"]:checked')?.value;
  radios.forEach(r => r.addEventListener('change', () => {
    sync();
    if (dirty && !confirm(document.body.dataset.discardMsg || 'Unsaved changes will be lost. Switch anyway?')) {
      document.querySelector(`input[name="mode"][value="${current}"]`).checked = true;
      sync();
      return;
    }
    const form = r.form;
    const action = document.createElement('input');
    action.type = 'hidden'; action.name = 'action'; action.value = 'switch';
    form.appendChild(action);
    form.submit();
  }));
  sync();
})();
