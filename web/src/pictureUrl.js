// Only a public picture under brand-assets/user/ in this project's own storage. The URL is placed inside CSS url("..."),
// so anything that could end that value (quotes, brackets, backslash, whitespace, angle brackets, backtick) is refused.
export function isOwnPicture(u, origin) {
  if (typeof u !== "string" || !origin || /[\\\s"'()<>`]/.test(u)) return false;
  try {
    const x = new URL(u);
    return x.protocol === "https:" && x.origin === origin && x.pathname.startsWith("/storage/v1/object/public/brand-assets/user/");
  } catch { return false; }
}
