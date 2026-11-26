// A tickets_list answer the Support page can show: an object whose tickets is a list (an empty list is a real "none").
// Anything else is unreadable and throws, so the page keeps what it had and says the read failed (never an empty or
// changed list).
export function readTickets(next) {
  if (!next || typeof next !== "object" || !Array.isArray(next.tickets)) throw new Error("The ticket list couldn't be read. Try again.");
  return next;
}
