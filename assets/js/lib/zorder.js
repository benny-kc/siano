// Stacking order for meal/bill cards: the most recently opened, moved or
// touched card sits on top. The z-index is kept per meal in this map (not just
// on the element) and re-applied after every LiveView re-render — otherwise
// morphdom, reconciling the card's style back to the server's (left/top only),
// would strip the z-index and drop the card behind the others.
let mealZTop = 10
export const mealZOrder = {}
export function bringToFront(card) {
  mealZTop += 1
  mealZOrder[card.dataset.mealId] = mealZTop
  card.style.zIndex = String(mealZTop)
}
export function applyZ(card) {
  const z = mealZOrder[card.dataset.mealId]
  if (z) card.style.zIndex = String(z)
}

