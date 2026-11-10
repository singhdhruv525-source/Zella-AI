
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

// Development preview (/app/preview) uses a placeholder business that matches nothing. Its requests would only be
// refused by the live database and fill its logs, so in development they are answered here with "nothing found".
// Never active in a production build, or under browser automation (tests supply their own answers).
const PREVIEW_ID = '00000000-0000-0000-0000-000000000000';
const isPreview = () => import.meta.env.DEV && typeof window !== 'undefined' && window.location.pathname.startsWith('/app/preview')
  && !(typeof navigator !== 'undefined' && navigator.webdriver);
async function previewFetch(input, init) {
  const url = typeof input === 'string' ? input : input?.url ?? '';
  const body = typeof init?.body === 'string' ? init.body : '';
  if (isPreview() && url.includes('/rest/v1/') && (url.includes(PREVIEW_ID) || body.includes(PREVIEW_ID))) {
    const single = String(init?.headers?.Accept ?? init?.headers?.accept ?? '').includes('vnd.pgrst.object');
    return new Response(single ? 'null' : '[]', { status: 200, headers: { 'Content-Type': 'application/json', 'Content-Range': '*/0' } });
  }
  return fetch(input, init);
}

export const supabase = createClient(
  supabaseUrl,
  supabasePublishableKey,
  import.meta.env.DEV ? { global: { fetch: previewFetch } } : undefined
);
