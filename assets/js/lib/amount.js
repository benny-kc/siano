// Which meal's "Total" input is currently focused for writing (and the element
// itself). While it is focused, tapping a recognised price field on that meal's
// bill photo writes the field's value into the total — a photo-driven way to
// fill in the meal total, alongside typing it or the /head shortcut.
//
// This is deliberately a one-shot mode: the field tap consumes the armed state
// (see `endAmountArm`) so a stray later tap can't keep hijacking the total.
export let armedAmount = null

export function setArmedAmount(mealId, el) {
  armedAmount = { mealId, el }
}

// Clear the armed state. Guarded by mealId so a late `blur` from an old input
// can't wipe a newer meal's focus. Pass no id to force-clear.
export function clearArmedAmount(mealId) {
  if (mealId == null || (armedAmount && armedAmount.mealId === mealId)) armedAmount = null
}

// Is the Total field of THIS meal armed (focused for writing)?
export function amountArmedFor(mealId) {
  return !!armedAmount && armedAmount.mealId === mealId
}

// End the one-shot "fill total from a field" mode after a field tap has been
// used. Blanks the input while it still holds focus so the phx-blur that follows
// fires `set_amount` with an empty value (a harmless no-op) rather than pushing a
// stale typed value that would race the field write; then drops focus so the mode
// doesn't linger.
export function endAmountArm(mealId) {
  const st = armedAmount
  clearArmedAmount(mealId)
  if (st && st.el) {
    if (document.activeElement === st.el) st.el.value = ""
    st.el.blur()
  }
}
