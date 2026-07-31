// Which traveller is currently "armed" (single-selected in the dock). While a
// traveller is selected, tapping recognised price fields on a bill assigns them
// to that traveller; their custom share becomes the sum of those fields.
// Single-select: selecting one clears the others.
export let selectedMember = null
export function setSelectedTraveller(id) {
  selectedMember = selectedMember === id ? null : id
  document.querySelectorAll(".traveller-token").forEach((t) => {
    t.classList.toggle("is-selected", t.dataset.memberId === selectedMember)
  })
}

// Unconditionally clear the armed traveller (e.g. tapping empty board space).
// Unlike setSelectedTraveller/toggle, this never re-arms anyone.
export function clearSelectedTraveller() {
  if (selectedMember === null) return
  selectedMember = null
  document.querySelectorAll(".traveller-token").forEach((t) => {
    t.classList.remove("is-selected")
  })
}

