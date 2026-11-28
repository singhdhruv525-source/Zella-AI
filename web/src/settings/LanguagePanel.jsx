import { supabase } from "../supabase";
import { Banner, Card, Facts, LinkRows, LoadState, useAsync } from "./SettingsKit";
import { languageError, languageNames } from "../business/languagePlan";

// AI receptionist languages, read only. Only the Zella Voice team changes them, within the business's plan, from the
// admin business page (sql/zella_admin_languages.sql: zella_business_language_save refuses owners and staff with
// LANGUAGES_ADMIN_ONLY). Owners, admins, managers and staff read them here with zella_business_language_get.

export const LANGUAGES_NOTE = "Your AI receptionist's languages are set by Zella Voice and come with your plan. To add Spanish, contact Zella Voice support.";

function View({ w, data, onGo }) {
  const catalog = data.catalog ?? [];
  const byCode = Object.fromEntries(catalog.map((l) => [l.code, l]));
  const main = byCode[data.primary];
  const extras = (data.extras ?? []).filter((c) => c !== data.primary);
  const other = !main?.english || extras.some((c) => !byCode[c]?.english);
  const standard = (main?.greeting ?? "").replace("{name}", w.name);
  const plan = data.plan ?? {};
  const included = typeof plan.allowance === "number" ? `${plan.allowance} ${plan.allowance === 1 ? "language" : "languages"}` : null;

  return (
    <>
      <Card title="Languages" sub="The language your AI receptionist answers every call in, and the ones it switches to when a caller speaks them.">
        <Facts rows={[
          ["Main language", main?.label ?? data.primary],
          ["Other languages", extras.length ? languageNames(extras, catalog).join(", ") : "None"],
          ["Greeting", data.greeting ? data.greeting.replace("{name}", w.name) : `Standard: “${standard}”`],
          included && ["Your plan includes", included],
        ]} />
        <Banner>{LANGUAGES_NOTE}</Banner>
        {onGo && <LinkRows rows={[{ title: "Contact Zella Voice support", detail: "Help and support: send a request", label: "Open", onClick: () => onGo("settings/help/tickets") }]} />}
      </Card>
      {other && (
        <Banner tone="warn">
          Other languages need a transcriber that understands them. The Zella Voice team switches your line over and makes a test call in each language before it goes live.
          Booking times, names and texts you send stay as they are; texts and emails are still sent in English.
        </Banner>
      )}
    </>
  );
}

export function LanguagePanel({ w, onGo }) {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_business_language_get", { p_business_id: w.id });
    if (error) throw new Error(languageError(error));
    return data;
  }, [w.id]);
  return <LoadState state={state}>{(data) => <View w={w} data={data} onGo={onGo} />}</LoadState>;
}
