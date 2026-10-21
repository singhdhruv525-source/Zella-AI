
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabasePublishableKey =
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

console.log('Supabase URL loaded:', JSON.stringify(supabaseUrl));
console.log(
  'Publishable key loaded:',
  Boolean(supabasePublishableKey)
);

if (!supabaseUrl || !/^https:\/\/[^/]+\.supabase\.co$/.test(supabaseUrl)) {
  throw new Error(
    'Invalid Supabase URL. Check web/.env.local and restart Vite.'
  );
}

if (!supabasePublishableKey) {
  throw new Error('Supabase publishable key is missing.');
}

export const supabase = createClient(
  supabaseUrl,
  supabasePublishableKey
);
