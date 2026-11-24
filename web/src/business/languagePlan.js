// The receptionist's languages and the business's plan (sql/zella_admin_languages.sql), in words. Pure helpers shared by
// the admin business page (LanguagesCard) and Settings > Languages (LanguagePanel); tests in web/tests/languagePlan.test.mjs.
// planRefusal mirrors zella_language_plan_refusal so the page can say why before saving; the server decides.

const NAMES = { en: "English", es: "Spanish" };

// en for every English variant, otherwise the code's first part (es-419: es)
export function familyOf(code, catalog = []) {
  if (!code) return null;
  const entry = catalog.find((l) => l.code === code);
  if (entry?.english) return "en";
  return String(code).toLowerCase().split("-")[0];
}

export function languageNames(codes, catalog = []) {
  const byCode = Object.fromEntries(catalog.map((l) => [l.code, l.label]));
  return codes.map((c) => byCode[c] ?? NAMES[c] ?? c);
}

// What the plan allows, in one sentence for the admin.
export function planSummary(plan) {
  if (!plan || plan.source === "none" || !plan.source) {
    return "No plan is set for this business yet, so its languages aren't limited. Set the plan first if Spanish should come with it.";
  }
  const name = plan.plan ? `The plan (${plan.plan})` : "The plan";
  const n = plan.allowance;
  if (n === null || n === undefined) return `${name} doesn't limit languages.`;
  const named = Array.isArray(plan.plan_languages) ? ` (${plan.plan_languages.map((l) => NAMES[l] ?? l).join(" and ")})` : "";
  const second = plan.second_language_allowed && plan.spanish_allowed !== false ? " Spanish can be added." : " A second language can't be added.";
  return `${name} includes ${n} ${n === 1 ? "language" : "languages"}${named}.${n === 1 ? second : ""}`;
}

// Why a choice is outside the plan (null when it fits), in the words the server's refusal is shown with.
export function planRefusal(plan, primary, extras = [], catalog = []) {
  const n = plan?.allowance;
  if (n === null || n === undefined) return null;
  const all = [...new Set([primary, ...extras].filter(Boolean))];
  const families = all.map((c) => familyOf(c, catalog));
  const named = Array.isArray(plan.plan_languages) ? plan.plan_languages : null;
  const outside = all.length > n
    || (named ? families.some((f) => !named.includes(f)) : n < 2 && families.some((f) => f !== "en"));
  if (!outside) return null;
  return planMessage(plan);
}

export function planMessage(plan) {
  const n = plan?.allowance;
  const named = Array.isArray(plan?.plan_languages) ? plan.plan_languages : null;
  if (n === 1 && named && named[0] === "es") return "This plan includes Spanish only. Move the business to a plan with English first.";
  if (n === 1) return "This plan includes 1 language. Move the business to a plan with Spanish first.";
  if (typeof n === "number" && plan?.spanish_allowed === false) return `This plan includes ${n} languages, without Spanish. Move the business to a plan with Spanish first.`;
  if (typeof n === "number") return `This plan includes ${n} languages${named ? ` (${named.map((l) => NAMES[l] ?? l).join(" and ")})` : ""}. Choose languages within it, or move the business to a bigger plan first.`;
  return "These languages aren't in the business's plan. Change the plan first.";
}

// The server's refusals of zella_business_language_save, in words.
const CODES = {
  LANGUAGES_ADMIN_ONLY: "Only Zella Voice admins who can manage businesses change a receptionist's languages.",
  NOT_FOUND: "This business no longer exists.",
  UNKNOWN_LANGUAGE: "Pick languages from the list.",
  TOO_MANY_LANGUAGES: "Up to three extra languages.",
  GREETING_LENGTH: "The greeting needs 5 to 200 characters.",
  GREETING_TEXT: "The greeting can't contain links, brackets or placeholders other than {name}.",
  GREETING_AI_DISCLOSURE: "The greeting must tell callers they are speaking with an AI, for example \"I'm the AI receptionist.\"",
};
export function languageError(error, plan) {
  const message = error?.message?.trim() ?? String(error ?? "");
  if (/does not exist|schema cache|Could not find the/i.test(message)) return "Languages need the latest Zella Voice update. Please ask the Zella Voice team.";
  if (message === "PLAN_LANGUAGES") return planMessage(plan);
  return CODES[message] ?? message;
}
