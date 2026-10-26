
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabasePublishableKey =
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

if (!supabaseUrl || !/^https:\/\/[^/]+\.supabase\.co$/.test(supabaseUrl)) {
  throw new Error(
    'Invalid Supabase URL. Check web/.env.local and restart Vite.'
  );
}

if (!supabasePublishableKey) {
  throw new Error('Supabase publishable key is missing.');
}

// The address an email link opened, saved before the sign-in library reads
// and tidies it (it removes "#access_token=..." and "#error=..." from the bar).
export const LANDING_URL = typeof window === 'undefined'
  ? { hash: '', search: '' }
  : { hash: window.location.hash || '', search: window.location.search || '' };

export const supabase = createClient(
  supabaseUrl,
  supabasePublishableKey
);
