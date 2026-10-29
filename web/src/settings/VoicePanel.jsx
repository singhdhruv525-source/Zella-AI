import { supabase } from "../supabase";
import { Banner, Card, Field, LoadState, SaveBar, useAsync, useForm } from "./SettingsKit";

// The receptionist's voice for one business: Zella's default, or one of the voices the platform approved.
// Read and saved with zella_business_voice_get / _save (sql/zella_business_voice.sql): owners, admins and managers of
// the business, or a Zella admin, can change it; the server checks the voice is on the approved list.

const CODES = {
  NOT_ALLOWED: "Only owners, admins and managers can change the voice.",
  UNKNOWN_VOICE: "Pick a voice from the list.",
  NOT_FOUND: "This business no longer exists.",
};
const say = (error) => {
  const message = error?.message?.trim() ?? String(error);
  if (/does not exist|schema cache|Could not find the/i.test(message)) return "Voice choice needs the latest Zella update. Please ask the Zella team.";
  return CODES[message] ?? message;
};

function Editor({ businessId, data }) {
  const form = useForm({ voice: data.voice_id ?? "" });
  const choices = data.choices ?? [];
  const nameOf = (id) => choices.find((c) => c.id === id)?.name ?? id;
  const defaultName = data.default_voice_id ? nameOf(data.default_voice_id) : null;

  async function save() {
    await form.save(async (values) => {
      const { data: next, error } = await supabase.rpc("zella_business_voice_save", { p_business_id: businessId, p_voice_id: values.voice || null });
      if (error) throw new Error(say(error));
      return { voice: next?.voice_id ?? "" };
    }, "Saved. It's used the next time the receptionist's settings are sent to the phone line.");
  }

  return (
    <Card title="Voice" sub="How the receptionist sounds on calls. Choose from the voices Zella has approved.">
      <div className="zs-grid">
        <Field label="Voice" hint={defaultName ? `Zella's default is ${defaultName}.` : "Zella's default voice isn't chosen yet."}>
          <select value={form.values.voice} disabled={!data.can_edit} onChange={form.set("voice")}>
            <option value="">{defaultName ? `Zella default (${defaultName})` : "Zella default"}</option>
            {choices.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </Field>
      </div>
      {data.provider !== "11labs" && (
        <Banner tone="warn">Zella's voices currently come from another provider, so this choice isn't used until ElevenLabs is the voice provider again.</Banner>
      )}
      <p className="zs-muted">Voices can't be played here yet. To hear one, make a test call after it's saved.</p>
      {data.can_edit ? <SaveBar form={form} onSave={save} /> : <Banner>Only owners, admins and managers can change the voice.</Banner>}
    </Card>
  );
}

export function VoicePanel({ businessId }) {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_business_voice_get", { p_business_id: businessId });
    if (error) throw new Error(say(error));
    return data;
  }, [businessId]);
  return <LoadState state={state}>{(data) => <Editor key={data.voice_id ?? "default"} businessId={businessId} data={data} />}</LoadState>;
}
