import { useId } from "react";
import { supabase } from "../supabase";
import { Banner, Card, LoadState, SaveBar, useAsync, useForm } from "./SettingsKit";
import { VoiceSelect } from "./VoiceSelect";
import { loadVoice } from "./voiceApi";
import { defaultVoiceName, unusedVoiceNote, voiceError, voiceLabel } from "./voiceChoices";

// The receptionist's voice for one business: Zella Voice's default, or one of the voices the platform approved
// (Cartesia, ElevenLabs or Vapi). Read and saved with zella_business_voice_get / _save (sql/zella_business_voice.sql,
// sql/zella_cartesia_voices.sql): owners, admins and managers of the business, or a Zella Voice admin, can change it;
// the server checks the voice is on the approved list. The admin create business wizard uses the same carousel; its
// play buttons ask the voice-sample function for a short sample.

function Editor({ businessId, data }) {
  const labelId = useId();
  const form = useForm({ voice: data.voice_id ?? "" });
  const choices = data.choices ?? [];
  const find = (id) => choices.find((c) => c.id === id);
  const defaultName = defaultVoiceName(data);
  const chosen = find(form.values.voice);
  const note = unusedVoiceNote(chosen, data.provider);

  async function save() {
    await form.save(async (values) => {
      const { data: next, error } = await supabase.rpc("zella_business_voice_save", { p_business_id: businessId, p_voice_id: values.voice || null });
      if (error) throw new Error(voiceError(error));
      return { voice: next?.voice_id ?? "" };
    }, "Saved. It's used the next time the receptionist's settings are sent to the phone line.");
  }

  return (
    <Card title="Voice" sub="How the receptionist sounds on calls. Choose from the voices Zella Voice has approved, and press play to hear one.">
      <div className="zs-field zs-voice-field">
        <span id={labelId}>Voice</span>
        <VoiceSelect value={form.values.voice} disabled={!data.can_edit} onChange={form.set("voice")} choices={choices} defaultName={defaultName}
          defaultId={data.default_voice_id} labelledBy={labelId} />
        <small>{chosen ? voiceLabel(chosen) : defaultName ? `Zella Voice's default is ${defaultName}.` : "Zella Voice's default voice isn't chosen yet."}</small>
      </div>
      {note && <Banner tone="warn">{note}</Banner>}
      <p className="zs-muted zs-voice-note">Samples say one short line in the voice. A saved voice is used once the phone line's settings are updated with it; to hear it on a call, call the business's Zella Voice number.</p>
      {data.can_edit ? <SaveBar form={form} onSave={save} /> : <Banner>You can see the voice but not change it. In the business app owners, admins and managers can change it; Zella Voice admins need permission to set up AI.</Banner>}
    </Card>
  );
}

export function VoicePanel({ businessId }) {
  const state = useAsync(() => loadVoice(businessId), [businessId]);
  return <LoadState state={state}>{(data) => <Editor key={data.voice_id ?? "default"} businessId={businessId} data={data} />}</LoadState>;
}
