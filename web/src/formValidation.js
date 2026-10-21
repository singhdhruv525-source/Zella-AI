// Checks for phone numbers, emails, passwords and time zones.
// Plain functions with no screen code, so every form in Zella uses the same rules.

/* ------------------------------------------------------------------ */
/* Countries: ISO code, calling code, and the digits after the code      */
/* ------------------------------------------------------------------ */

// ISO  calling-code  fewest-digits  most-digits   (digits that follow the calling code)
const RAW = `
AF 93 9 9|AL 355 8 9|DZ 213 8 9|AS 1 10 10|AD 376 6 9|AO 244 9 9|AI 1 10 10|AG 1 10 10|AR 54 10 11|AM 374 8 8|AW 297 7 7|AU 61 9 10|AT 43 4 13|AZ 994 9 9
BS 1 10 10|BH 973 8 8|BD 880 8 10|BB 1 10 10|BY 375 9 10|BE 32 8 9|BZ 501 7 7|BJ 229 8 10|BM 1 10 10|BT 975 7 8|BO 591 8 8|BQ 599 7 7|BA 387 8 8|BW 267 7 8|BR 55 10 11
IO 246 7 7|VG 1 10 10|BN 673 7 7|BG 359 7 9|BF 226 8 8|BI 257 8 8|KH 855 8 9|CM 237 8 9|CA 1 10 10|CV 238 7 7|KY 1 10 10|CF 236 8 8|TD 235 8 8|CL 56 9 9|CN 86 10 11
CX 61 9 9|CC 61 9 9|CO 57 8 10|KM 269 7 7|CG 242 7 9|CD 243 9 9|CK 682 5 5|CR 506 8 8|CI 225 8 10|HR 385 8 9|CU 53 8 8|CW 599 7 8|CY 357 8 8|CZ 420 9 9|DK 45 8 8
DJ 253 8 8|DM 1 10 10|DO 1 10 10|EC 593 8 9|EG 20 9 10|SV 503 8 8|GQ 240 9 9|ER 291 7 7|EE 372 7 8|SZ 268 8 8|ET 251 9 9|FK 500 5 5|FO 298 6 6|FJ 679 7 7|FI 358 5 12
FR 33 9 9|GF 594 9 9|PF 689 6 8|GA 241 7 8|GM 220 7 7|GE 995 9 9|DE 49 6 13|GH 233 9 9|GI 350 8 8|GR 30 10 10|GL 299 6 6|GD 1 10 10|GP 590 9 9|GU 1 10 10|GT 502 8 8
GG 44 9 10|GN 224 8 9|GW 245 7 9|GY 592 7 7|HT 509 8 8|VA 39 6 11|HN 504 8 8|HK 852 8 8|HU 36 8 9|IS 354 7 9|IN 91 10 10|ID 62 8 12|IR 98 10 10|IQ 964 8 10|IE 353 7 9
IM 44 9 10|IL 972 8 9|IT 39 6 12|JM 1 10 10|JP 81 9 10|JE 44 9 10|JO 962 8 9|KZ 7 10 10|KE 254 9 10|KI 686 5 8|XK 383 8 9|KW 965 8 8|KG 996 9 9|LA 856 8 10|LV 371 8 8
LB 961 7 8|LS 266 8 8|LR 231 7 9|LY 218 8 10|LI 423 7 9|LT 370 8 8|LU 352 6 11|MO 853 8 8|MG 261 9 10|MW 265 7 9|MY 60 7 10|MV 960 7 7|ML 223 8 8|MT 356 8 8|MH 692 7 7
MQ 596 9 9|MR 222 8 8|MU 230 7 8|YT 262 9 9|MX 52 10 10|FM 691 7 7|MD 373 8 8|MC 377 8 9|MN 976 8 8|ME 382 8 9|MS 1 10 10|MA 212 9 9|MZ 258 8 9|MM 95 7 10|NA 264 7 10
NR 674 7 7|NP 977 8 10|NL 31 9 9|NC 687 6 6|NZ 64 8 10|NI 505 8 8|NE 227 8 8|NG 234 8 10|NU 683 4 4|NF 672 6 6|KP 850 8 10|MK 389 8 8|MP 1 10 10|NO 47 8 8|OM 968 8 8
PK 92 9 10|PW 680 7 7|PS 970 8 9|PA 507 7 8|PG 675 7 8|PY 595 8 9|PE 51 8 9|PH 63 8 10|PL 48 9 9|PT 351 9 9|PR 1 10 10|QA 974 8 8|RE 262 9 9|RO 40 9 9|RU 7 10 10
RW 250 9 9|BL 590 9 9|SH 290 4 5|KN 1 10 10|LC 1 10 10|MF 590 9 9|PM 508 6 6|VC 1 10 10|WS 685 5 7|SM 378 6 10|ST 239 7 7|SA 966 8 9|SN 221 9 9|RS 381 8 9|SC 248 7 7
SL 232 8 8|SG 65 8 8|SX 1 10 10|SK 421 9 9|SI 386 8 8|SB 677 5 7|SO 252 7 9|ZA 27 9 9|KR 82 8 11|SS 211 9 9|ES 34 9 9|LK 94 9 9|SD 249 9 9|SR 597 6 7|SJ 47 8 8
SE 46 7 10|CH 41 9 9|SY 963 8 9|TW 886 8 9|TJ 992 9 9|TZ 255 9 9|TH 66 8 9|TL 670 7 8|TG 228 8 8|TK 690 4 5|TO 676 5 7|TT 1 10 10|TN 216 8 8|TR 90 10 10|TM 993 8 8
TC 1 10 10|TV 688 5 7|VI 1 10 10|UG 256 9 9|UA 380 9 9|AE 971 8 9|GB 44 9 10|US 1 10 10|UY 598 8 9|UZ 998 9 9|VU 678 5 7|VE 58 10 10|VN 84 9 10|WF 681 6 6|EH 212 9 9
YE 967 7 9|ZM 260 9 9|ZW 263 7 10|AX 358 6 12
`;

export const COUNTRIES = RAW.split("|").flatMap((chunk) => chunk.split("\n")).map((s) => s.trim()).filter(Boolean).map((row) => {
  const [iso, dial, min, max] = row.split(" ");
  return { iso, dial, min: Number(min), max: Number(max) };
});
const BY_ISO = Object.fromEntries(COUNTRIES.map((c) => [c.iso, c]));
const DIAL_CODES = [...new Set(COUNTRIES.map((c) => c.dial))];

// Countries that keep their leading 0 as part of the number (everyone else drops it).
const KEEPS_ZERO = new Set(["IT", "VA", "SM"]);
// Extra shape rules for the most common countries (the digits after the calling code).
const SHAPES = {
  IN: [/^[6-9]\d{9}$/, "India numbers have 10 digits and start with 6, 7, 8 or 9."],
  GB: [/^[1-37-9]\d{8,9}$/, "UK numbers start with 1, 2, 3, 7, 8 or 9 after the country code, for example 7911 123456."],
  AU: [/^[2-578]\d{8}$|^1[38]\d{8}$|^1[38]\d{4}$/, "Australian numbers have 9 digits, for example 412 345 678."],
  FR: [/^[1-9]\d{8}$/, "French numbers have 9 digits after the country code."],
  ES: [/^[6-9]\d{8}$/, "Spanish numbers have 9 digits and start with 6, 7, 8 or 9."],
  CN: [/^1[3-9]\d{9}$|^[2-9]\d{9,10}$/, "Chinese mobile numbers have 11 digits and start with 13 to 19."],
  PK: [/^[2-9]\d{8,9}$/, "Pakistani numbers have 10 digits, for example 300 1234567."],
  BR: [/^[1-9]{2}9?\d{8}$/, "Brazilian numbers have an area code and 8 or 9 digits."],
  SG: [/^[3689]\d{7}$/, "Singapore numbers have 8 digits and start with 3, 6, 8 or 9."],
  AE: [/^[2-9]\d{7,8}$/, "UAE numbers have 9 digits for mobiles, for example 50 123 4567."],
  JP: [/^[1-9]\d{8,9}$/, "Japanese numbers have 10 digits after the country code, for example 90 1234 5678."],
  DE: [/^[1-9]\d{5,12}$/, "German numbers start with the area or mobile code, without the leading 0."],
  MX: [/^[1-9]\d{9}$/, "Mexican numbers have 10 digits."],
};
const NANP = /^[2-9]\d{2}[2-9]\d{6}$/;

const names = typeof Intl !== "undefined" && Intl.DisplayNames ? new Intl.DisplayNames(["en"], { type: "region" }) : null;
export function countryName(iso) {
  if (iso === "XK") return "Kosovo";
  try { return names?.of(iso) ?? iso; } catch { return iso; }
}
export function flag(iso) {
  return [...iso].map((ch) => String.fromCodePoint(0x1f1e6 + ch.charCodeAt(0) - 65)).join("");
}
export const countryByIso = (iso) => BY_ISO[iso] ?? BY_ISO.US;

// Countries sorted by name, for the dropdown.
export function countryList() {
  return COUNTRIES.map((c) => ({ ...c, name: countryName(c.iso) })).sort((a, b) => a.name.localeCompare(b.name));
}

// Which calling code does a typed "+..." number start with? Longest match wins.
function dialPrefix(digits) {
  for (let len = 4; len >= 1; len -= 1) {
    const head = digits.slice(0, len);
    if (DIAL_CODES.includes(head)) return head;
  }
  return null;
}
// A good guess at the country for a calling code (prefers the one given).
function countryForDial(dial, prefer) {
  if (prefer && BY_ISO[prefer]?.dial === dial) return BY_ISO[prefer];
  const first = { 1: "US", 7: "RU", 44: "GB", 61: "AU", 212: "MA", 262: "RE", 358: "FI", 39: "IT", 47: "NO", 590: "GP", 599: "CW" }[dial];
  return BY_ISO[first] ?? COUNTRIES.find((c) => c.dial === dial);
}

export function defaultCountryFromBrowser() {
  try {
    const region = new Intl.Locale(navigator.language).maximize().region;
    if (region && BY_ISO[region]) return region;
  } catch { /* use the fallback */ }
  return "US";
}

function digitsOf(text) { return String(text ?? "").replace(/\D+/g, ""); }
const lengthText = (c) => (c.min === c.max ? `${c.max} digits` : `${c.min} to ${c.max} digits`);

/**
 * Check what someone typed in the phone box against the country picked beside it.
 * Returns { error, value } where value is "+<code><digits>" when it is good.
 */
export function checkPhone(text, iso, { required = false } = {}) {
  const raw = String(text ?? "").trim();
  const country = countryByIso(iso);
  const name = countryName(country.iso);
  if (!raw) return { error: required ? "Enter a phone number." : "", value: "" };
  if (/[^\d\s+().\-/]/.test(raw)) return { error: "Use digits only. Spaces, dashes and brackets are fine.", value: "" };

  let digits = digitsOf(raw);
  const typedPlus = /^\s*(\+|00)/.test(raw);
  if (typedPlus) {
    if (raw.replace(/^\s*(\+|00)/, "").trim() === "") return { error: "Enter the number after the country code.", value: "" };
    digits = digitsOf(raw.replace(/^\s*(\+|00)/, ""));
    const dial = dialPrefix(digits);
    if (!dial) return { error: "That country code isn't recognised. Check the digits after the +.", value: "" };
    if (dial !== country.dial) {
      const other = countryForDial(dial, null);
      return { error: `This number starts with +${dial} (${countryName(other.iso)}), but the country is set to ${name} (+${country.dial}). Change the country or fix the number.`, value: "" };
    }
    digits = digits.slice(dial.length);
  } else if (digits.length > country.max && digits.startsWith(country.dial) && digits.length - country.dial.length >= country.min && digits.length - country.dial.length <= country.max) {
    digits = digits.slice(country.dial.length); // they typed the country code again, so just drop it
  }

  // Drop the local "0" in front (the trunk prefix) where that is how the country writes numbers.
  if (!KEEPS_ZERO.has(country.iso) && country.dial !== "1" && digits.startsWith("0")) digits = digits.slice(1);
  if (["RU", "KZ"].includes(country.iso) && digits.length === country.max + 1 && digits.startsWith("8")) digits = digits.slice(1);

  if (digits.length < country.min || digits.length > country.max) {
    const issue = digits.length < country.min ? "too short" : "too long";
    return { error: `That number is ${issue} for ${name}. Numbers here have ${lengthText(country)}${country.dial === "1" ? "" : `, without the +${country.dial}`}.`, value: "" };
  }
  if (country.dial === "1" && !NANP.test(digits)) {
    return { error: `That doesn't look like a valid ${name} number. It needs a 3 digit area code and 7 digits, and neither part starts with 0 or 1.`, value: "" };
  }
  const shape = SHAPES[country.iso];
  if (shape && !shape[0].test(digits)) return { error: `That doesn't look like a valid ${name} number. ${shape[1]}`, value: "" };
  if (/^(\d)\1+$/.test(digits)) return { error: "Check the number. It repeats the same digit.", value: "" };
  return { error: "", value: `+${country.dial}${digits}` };
}

// For forms: check a saved value. "" is fine unless required.
export function validatePhone(value, { required = false } = {}) {
  const v = String(value ?? "").trim();
  if (!v) return required ? "Enter a phone number." : "";
  if (v.startsWith("?")) return "Check the phone number.";
  if (!v.startsWith("+")) return checkPhone(v, defaultCountryFromBrowser()).error;
  const dial = dialPrefix(digitsOf(v));
  if (!dial) return "Check the phone number.";
  const guess = countryForDial(dial, null);
  // A number shared by several countries (+1) is checked against the common rules.
  return checkPhone(v, guess.iso).error;
}

// What to split an existing saved number into for display: { iso, national }.
export function splitPhone(value, preferIso) {
  const v = String(value ?? "").trim();
  if (v.startsWith("?")) return { iso: preferIso, national: v.slice(1) };
  if (v.startsWith("+")) {
    const digits = digitsOf(v);
    const dial = dialPrefix(digits);
    if (dial) {
      const country = countryForDial(dial, preferIso);
      return { iso: country.iso, national: digits.slice(dial.length) };
    }
  }
  return { iso: preferIso, national: v };
}

/* ------------------------------------------------------------------ */
/* Email                                                                 */
/* ------------------------------------------------------------------ */

const TYPOS = {
  "gmial.com": "gmail.com", "gmai.com": "gmail.com", "gmail.co": "gmail.com", "gamil.com": "gmail.com", "gnail.com": "gmail.com", "gmail.con": "gmail.com", "gmali.com": "gmail.com",
  "yahooo.com": "yahoo.com", "yaho.com": "yahoo.com", "yahoo.con": "yahoo.com", "hotmial.com": "hotmail.com", "hotmai.com": "hotmail.com", "hotmail.con": "hotmail.com",
  "outlok.com": "outlook.com", "outllok.com": "outlook.com", "outlook.con": "outlook.com", "iclod.com": "icloud.com", "icloud.con": "icloud.com",
};

export function checkEmail(value, { required = false } = {}) {
  const v = String(value ?? "").trim();
  if (!v) return required ? "Enter an email address." : "";
  if (/\s/.test(v)) return "An email address can't contain spaces.";
  if ((v.match(/@/g) ?? []).length !== 1) return v.includes("@") ? "An email address has just one @." : "Add the @ and the domain, like name@business.com.";
  const [local, domain] = v.split("@");
  if (!local) return "Add the part before the @.";
  if (!domain) return "Add the domain after the @, like business.com.";
  if (local.length > 64) return "The part before the @ is too long.";
  if (/^\.|\.$|\.\./.test(local) || !/^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$/.test(local)) return "The part before the @ has a character that isn't allowed.";
  if (!domain.includes(".")) return `Add the ending of the domain, like ${domain}.com.`;
  const labels = domain.split(".");
  if (labels.some((l) => !l || l.length > 63 || !/^[A-Za-z0-9-]+$/.test(l) || l.startsWith("-") || l.endsWith("-"))) return "The domain after the @ doesn't look right.";
  const tld = labels[labels.length - 1];
  if (tld.length < 2 || /^\d+$/.test(tld)) return "The ending of the domain (like .com) doesn't look right.";
  if (v.length > 254) return "That email address is too long.";
  const fix = TYPOS[domain.toLowerCase()];
  if (fix) return `Did you mean ${local}@${fix}?`;
  return "";
}

/* ------------------------------------------------------------------ */
/* Password                                                              */
/* ------------------------------------------------------------------ */

export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 64;

export function passwordRules(password) {
  const p = String(password ?? "");
  return [
    { id: "length", short: `at least ${PASSWORD_MIN} characters`, label: `At least ${PASSWORD_MIN} characters`, met: p.length >= PASSWORD_MIN },
    { id: "upper", short: "an uppercase letter", label: "One uppercase letter (A to Z)", met: /[A-Z]/.test(p) },
    { id: "lower", short: "a lowercase letter", label: "One lowercase letter (a to z)", met: /[a-z]/.test(p) },
    { id: "number", short: "a number", label: "One number (0 to 9)", met: /\d/.test(p) },
  ];
}
export const passwordProblems = (password) => {
  const missing = passwordRules(password).filter((r) => !r.met).map((r) => r.short);
  if (String(password ?? "").length > PASSWORD_MAX) missing.push(`no more than ${PASSWORD_MAX} characters`);
  return missing;
};
export const passwordOk = (password) => passwordProblems(password).length === 0;

/* ------------------------------------------------------------------ */
/* Time zones                                                            */
/* ------------------------------------------------------------------ */

const FALLBACK_ZONES = [
  "UTC", "Pacific/Midway", "Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Phoenix", "America/Denver", "America/Chicago", "America/New_York",
  "America/Halifax", "America/St_Johns", "America/Mexico_City", "America/Bogota", "America/Lima", "America/Caracas", "America/Santiago", "America/Sao_Paulo", "America/Argentina/Buenos_Aires",
  "Atlantic/Azores", "Atlantic/Reykjavik", "Europe/London", "Europe/Dublin", "Europe/Lisbon", "Europe/Paris", "Europe/Berlin", "Europe/Madrid", "Europe/Rome", "Europe/Athens",
  "Europe/Istanbul", "Europe/Moscow", "Africa/Cairo", "Africa/Lagos", "Africa/Nairobi", "Africa/Johannesburg", "Asia/Jerusalem", "Asia/Riyadh", "Asia/Dubai", "Asia/Tehran",
  "Asia/Karachi", "Asia/Calcutta", "Asia/Kathmandu", "Asia/Dhaka", "Asia/Bangkok", "Asia/Jakarta", "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Singapore", "Asia/Manila", "Asia/Tokyo",
  "Asia/Seoul", "Australia/Perth", "Australia/Adelaide", "Australia/Sydney", "Pacific/Auckland", "Pacific/Fiji",
];

function offsetMinutes(zone, at) {
  try {
    const part = new Intl.DateTimeFormat("en-US", { timeZone: zone, timeZoneName: "longOffset" }).formatToParts(at).find((p) => p.type === "timeZoneName")?.value ?? "GMT";
    const m = part.match(/GMT([+-])(\d{1,2})(?::(\d{2}))?/);
    return m ? (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3] ?? 0)) : 0;
  } catch { return 0; }
}
function offsetLabel(mins) {
  const sign = mins < 0 ? "-" : "+";
  const abs = Math.abs(mins);
  return `UTC${sign}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")}`;
}

// Every time zone the browser knows, grouped by region and ordered by offset.
export function timeZoneGroups(extra = []) {
  let zones;
  try { zones = Intl.supportedValuesOf("timeZone"); } catch { zones = FALLBACK_ZONES; }
  zones = [...new Set([...zones, "UTC", ...extra.filter(Boolean)])];
  const now = new Date();
  const items = zones.map((zone) => {
    const mins = offsetMinutes(zone, now);
    const region = zone.includes("/") ? zone.split("/")[0] : "Other";
    return { zone, mins, region, label: `(${offsetLabel(mins)}) ${zone.replace(/_/g, " ")}` };
  });
  const groups = {};
  for (const item of items) (groups[item.region] ??= []).push(item);
  return Object.entries(groups).sort(([a], [b]) => (a === "Other" ? 1 : b === "Other" ? -1 : a.localeCompare(b)))
    .map(([region, list]) => ({ region, items: list.sort((a, b) => a.mins - b.mins || a.zone.localeCompare(b.zone)) }));
}
export const isTimeZone = (zone) => { try { new Intl.DateTimeFormat("en-US", { timeZone: zone }); return Boolean(zone); } catch { return false; } };
