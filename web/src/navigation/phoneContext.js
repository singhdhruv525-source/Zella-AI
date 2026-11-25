import { createContext, createElement, useContext } from "react";

// What the pages need to know about the phone layout, without each one asking the browser: whether it is a phone,
// and the toast above the bar (P21) for messages with Undo. Desktop and tablet get { phone: false } and pages keep
// their usual layout.
export const PhoneUi = createContext({ phone: false, toast: () => {} });
export const usePhoneUi = () => useContext(PhoneUi);

// The "Needs you now" block on Today (P14). The workspace fills it on a phone; BusinessToday only says where it goes.
export const TodayTop = createContext(null);
export function TodayTopSlot() {
  const node = useContext(TodayTop);
  return node ? createElement("div", { className: "pn-today-top" }, node) : null;
}
