// Requests in flight, one per item (UX-4: no double actions). A second start for an item that is still pending is
// ignored, other items can start meanwhile, and each item is cleared when its own request ends, worked or not.
//   const flight = inFlight(() => setPending(flight.ids()));
//   flight.run(row.id, () => supabase.rpc(...));      flight.has(row.id) disables that row's button
export function inFlight(onChange = () => {}) {
  const pending = new Set();
  return {
    has: (id) => pending.has(id),
    ids: () => new Set(pending),
    async run(id, work) {
      if (pending.has(id)) return { skipped: true };
      pending.add(id);
      onChange();
      try {
        return { value: await work() };
      } finally {
        pending.delete(id);
        onChange();
      }
    },
  };
}
