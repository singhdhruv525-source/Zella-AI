import { supabase } from "../supabase";
import { voiceError } from "./voiceChoices";

// The voice and the approved list for one business (zella_business_voice_get), for Settings > Voice and the admin wizard
export async function loadVoice(businessId) {
  const { data, error } = await supabase.rpc("zella_business_voice_get", { p_business_id: businessId });
  if (error) throw new Error(voiceError(error));
  return data;
}
