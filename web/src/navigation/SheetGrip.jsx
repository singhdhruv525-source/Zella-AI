// The drag strip at the top of a dialog that becomes a bottom sheet on a phone (BottomSheet.jsx useSheetEnhancer).
// Part of each dialog's own markup, so nothing is added to React owned elements from outside. Hidden for screen
// readers, and shown only in phone mode (styles/phone-nav.css), where it takes vertical drags (touch-action: none)
// while the dialog's content keeps its normal scrolling.
export function SheetGrip() {
  return <span className="pn-sheet-grip" aria-hidden="true" />;
}
