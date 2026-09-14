// type="text" (not "number") to kill the native spinner; this restores
// "digits + one dot" by hand.
function filterDecimalInput(el) {
  let v = el.value.replace(/[^0-9.]/g, '');
  const i = v.indexOf('.');
  if (i !== -1) v = v.slice(0, i + 1) + v.slice(i + 1).replace(/\./g, '');
  if (v !== el.value) el.value = v;
}
