// type="text" (not "number") to kill the native spinner; this restores
// "digits only" by hand (prices are whole numbers).
function filterDecimalInput(el) {
  const v = el.value.replace(/[^0-9]/g, '');
  if (v !== el.value) el.value = v;
}
