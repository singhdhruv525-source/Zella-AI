// One shared lock on the page's scroll for everything that covers it (bottom sheets, the side panel). The page's own
// overflow value is saved when the first lock is taken and put back when the last is released, so locks released in
// any order never leave the page locked, or unlocked while something still covers it. Each release works once.
//   doc: the document (passed in by tests)
export function createScrollLock(doc) {
  let locks = 0;
  let saved = "";
  return function lockBodyScroll() {
    const body = (doc ?? (typeof document === "undefined" ? null : document))?.body;
    if (!body) return () => {};
    if (locks === 0) saved = body.style.overflow;
    locks += 1;
    body.style.overflow = "hidden";
    let released = false;
    return () => {
      if (released) return;
      released = true;
      locks -= 1;
      if (locks === 0) body.style.overflow = saved;
    };
  };
}
export const lockBodyScroll = createScrollLock();
