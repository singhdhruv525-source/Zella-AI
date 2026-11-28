// Which screen the CRM shows for the list of workspaces (UX-1: a failed load is never shown as "nothing here").
//   workspaces: null while a read (or a retry) is pending, else the list from the last read that worked
//   failed:     the last read failed or answered without a list
// "empty" only follows a read that worked and found no workspace.
export function workspaceScreen({ workspaces, failed }) {
  if (failed) return "error";
  if (workspaces === null || workspaces === undefined) return "loading";
  return workspaces.length ? "app" : "empty";
}

// The list in a read's answer, or null when the answer isn't a list (treated as a failed read).
export const workspaceList = (data) => (Array.isArray(data) ? data : null);

// Only the latest of overlapping reads may write: start() gives each read a number, and isCurrent(n) is false once a
// newer read has started, so an older answer that arrives late is dropped.
export function latestOnly() {
  let latest = 0;
  return { start: () => ++latest, isCurrent: (n) => n === latest };
}
