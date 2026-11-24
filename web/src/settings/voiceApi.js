import { supabase } from "../supabase";
import { voiceError } from "./voiceChoices";

// The voice and the approved list for one business (zella_business_voice_get), for Settings > Voice and the admin wizard
export async function loadVoice(businessId) {
  const { data, error } = await supabase.rpc("zella_business_voice_get", { p_business_id: businessId });
  if (error) throw new Error(voiceError(error));
  // no answer is an error, never an empty list with the default chosen
  if (!data || !Array.isArray(data.choices)) throw new Error("The voices couldn't be loaded. Please try again.");
  return data;
}
