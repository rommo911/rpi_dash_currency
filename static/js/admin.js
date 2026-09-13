// Price fields are type="text" (not type="number") specifically to kill
// the browser's native spinner/scroll-to-change-value behavior on number
// inputs — this restores "only digits and one dot" by hand instead.
function filterDecimalInput(el) {
  let v = el.value.replace(/[^0-9.]/g, '');
  const i = v.indexOf('.');
  if (i !== -1) v = v.slice(0, i + 1) + v.slice(i + 1).replace(/\./g, '');
  if (v !== el.value) el.value = v;
}
