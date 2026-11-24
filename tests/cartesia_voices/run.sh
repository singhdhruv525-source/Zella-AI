#!/usr/bin/env bash
# sql/zella_cartesia_voices.sql on an isolated copy of production's schema (lib.sh; never production). Checks: drift in a
# guarded function stops the file and changes nothing; it applies, and applies again; ElevenLabs and Vapi voices come out
# of zella_assistant_config exactly as before; an approved Cartesia choice is sent as Vapi's CartesiaVoice (provider,
# voiceId, model, language from Vapi's lists) whatever the platform provider; a Cartesia platform voice works too; a bad
# model is left out and reported; the wizard's zella_setup_voice_apply is admin only, server only and audited, and the
# config uses its choice; the rollback is exact (functions, columns, settings), safe twice, refuses drift, keeps the
# rows; applying again after the rollback works.
. "$(dirname "$0")/lib.sh"; fresh_db voices
MIG="$REPO/sql/zella_cartesia_voices.sql"; RB="$REPO/sql/rollback/zella_cartesia_voices_rollback.sql"
SIGS="'public.zella_voice_choices()','public.zella_business_voice_save(uuid,text)','public.zella_assistant_config(uuid)','public.zella_business_voice_get(uuid)'"
KATIE=f786b574-daa5-4673-aa0c-cbe3e8534c02; DANIELA=5c5ad5e7-1020-476b-8b91-fdcbe9cc313c

# production's settings as sql/zella_business_voice.sql and sql/zella_vapi_voices.sql made them (the template has none)
q "insert into public.platform_settings (key, value) values
  ('voice_tts_choices', '[{\"id\":\"burt\",\"name\":\"Burt\"},{\"id\":\"marissa\",\"name\":\"Marissa\"},{\"id\":\"andrea\",\"name\":\"Andrea\"},{\"id\":\"sarah\",\"name\":\"Sarah\"},
    {\"id\":\"phillip\",\"name\":\"Phillip\"},{\"id\":\"steve\",\"name\":\"Steve\"},{\"id\":\"joseph\",\"name\":\"Joseph\"},{\"id\":\"myra\",\"name\":\"Myra\"},
    {\"id\":\"paula\",\"name\":\"Paula\"},{\"id\":\"ryan\",\"name\":\"Ryan\"},{\"id\":\"drew\",\"name\":\"Drew\"},{\"id\":\"paul\",\"name\":\"Paul\"},
    {\"id\":\"mrb\",\"name\":\"Mr B\"},{\"id\":\"matilda\",\"name\":\"Matilda\"},{\"id\":\"mark\",\"name\":\"Mark\"}]'),
  ('voice_tts_provider', '\"11labs\"'), ('voice_tts_voice_id', '\"burt\"'), ('voice_tts_model', '\"eleven_v4_turbo\"')
  on conflict (key) do update set value = excluded.value" > /dev/null

fp() {   # everything the file changes, before and after
  q "select md5(string_agg(x, '|' order by x collate \"C\")) from (
       select s || '=' || md5(pg_get_functiondef(s::regprocedure)) x from unnest(array[$SIGS]) s
       union all select 'col:' || attname || ':' || format_type(atttypid, atttypmod) || ':' || attnotnull from pg_attribute where attrelid = 'public.business_voice'::regclass and attnum > 0 and not attisdropped
       union all select 'con:' || conname || ':' || pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.business_voice'::regclass
       union all select 'set:' || key || '=' || value::text from public.platform_settings where key in ('voice_tts_choices', 'voice_cartesia_model', 'voice_tts_provider', 'voice_tts_voice_id', 'voice_tts_model')
       union all select 'fn:' || p.oid::regprocedure::text from pg_proc p where p.proname in ('zella_business_voice_choice', 'zella_cartesia_voice', 'zella_setup_voice_apply')
       union all select 'arch:' || count(*) from public.zella_function_archive where migration = 'zella_cartesia_voices') t"
}
mkbiz() { q "insert into public.businesses (name, industry_id, is_active) select '$1', id, true from public.industries limit 1 returning id" | head -1; }
voice() { q "select public.zella_assistant_config('$1') -> 'assistant' -> 'voice'"; }
setting() { q "insert into public.platform_settings (key, value) values ('$1', '$2') on conflict (key) do update set value = excluded.value" > /dev/null; }

B1=$(mkbiz "Plain Co"); B2=$(mkbiz "Marissa Co"); B3=$(mkbiz "Spanish Co"); B4=$(mkbiz "Cartesia Co"); B5=$(mkbiz "Wizard Co")
q "insert into public.business_voice (business_id, voice_id) values ('$B2', 'marissa'), ('$B3', 'marissa')" > /dev/null
q "select public.zella_setup_language_apply('$B3', 'es-US', null)" > /dev/null
setting voice_stt_model_multilingual '"nova-2"'
O=ca000000-0000-0000-0000-000000000001; A=ca000000-0000-0000-0000-000000000002; S=ca000000-0000-0000-0000-000000000003; X=ca000000-0000-0000-0000-000000000004
q "insert into auth.users (id, email, email_confirmed_at) values ('$O', 'own@voice.test', now()), ('$A', 'adm@voice.test', now()), ('$S', 'sup@voice.test', now()), ('$X', 'nobody@voice.test', now())" > /dev/null
q "insert into public.business_members (business_id, user_id, role, status) select b, '$O', 'owner', 'active' from unnest(array['$B1','$B2','$B3','$B4','$B5']::uuid[]) b" > /dev/null
q "insert into public.platform_admins (user_id, role, is_active) values ('$A', 'zella_owner', true), ('$S', 'support_admin', true)" > /dev/null

# the voices production sends today: ElevenLabs default, ElevenLabs business choice, multilingual, and Vapi's own
base() { echo "$(voice $B1);$(voice $B2);$(voice $B3)"; }
setting voice_tts_provider '"vapi"'; setting voice_tts_voice_id '"Elliot"'; VAPI_BEFORE="$(voice $B1);$(voice $B2)"
setting voice_tts_provider '"11labs"'; setting voice_tts_voice_id '"burt"'; ELEVEN_BEFORE=$(base)
BEFORE=$(fp)

# drift stops the file, nothing changes
q "create or replace function public.zella_voice_choices() returns jsonb language sql stable security definer set search_path = public as \$f\$ select coalesce(public.zella_setting('voice_tts_choices', '[]'::jsonb), '[]'::jsonb) /* changed */; \$f\$" > /dev/null
DRIFT=$(fp)
out=$(apply "$MIG"); [[ "$out" == *VERSION_MISMATCH*zella_voice_choices* ]] && [ "$(fp)" = "$DRIFT" ] && ok "a changed function stops the file (VERSION_MISMATCH) and nothing changes" || bad "drift: $out"
q "create or replace function public.zella_voice_choices() returns jsonb language sql stable security definer set search_path = public as \$f\$
  select coalesce(public.zella_setting('voice_tts_choices', '[]'::jsonb), '[]'::jsonb);
\$f\$" > /dev/null
[ "$(fp)" = "$BEFORE" ] && ok "production's version is back for the real test" || bad "restore drift"

out=$(apply "$MIG") && ok "applies" || { bad "applies: $out"; finish; }
AFTER=$(fp)
out=$(apply "$MIG") && [ "$(fp)" = "$AFTER" ] && ok "applies again, changing nothing" || bad "second apply: $out"

[ "$(base)" = "$ELEVEN_BEFORE" ] && ok "ElevenLabs voices are sent exactly as before (default, business choice, multilingual model)" || bad "11labs changed: $(base) vs $ELEVEN_BEFORE"
setting voice_tts_provider '"vapi"'; setting voice_tts_voice_id '"Elliot"'
[ "$(voice $B1);$(voice $B2)" = "$VAPI_BEFORE" ] && ok "Vapi's own voices are sent exactly as before" || bad "vapi changed: $(voice $B1);$(voice $B2) vs $VAPI_BEFORE"
setting voice_tts_provider '"11labs"'; setting voice_tts_voice_id '"burt"'
[ "$(q "select count(*) from jsonb_array_elements(public.zella_voice_choices()) c where c ->> 'provider' = 'cartesia'")" = 6 ] \
  && [ "$(q "select count(*) from jsonb_array_elements(public.zella_voice_choices()) c where c ->> 'provider' = '11labs'")" = 15 ] \
  && [ "$(q "select string_agg(c ->> 'id', ',' order by n) from jsonb_array_elements(public.zella_voice_choices()) with ordinality x(c, n) where n <= 15")" = "burt,marissa,andrea,sarah,phillip,steve,joseph,myra,paula,ryan,drew,paul,mrb,matilda,mark" ] \
  && ok "the list keeps its 15 ElevenLabs voices first (provider filled in) and adds 6 Cartesia voices" || bad "choices: $(q "select public.zella_voice_choices()")"
[ "$(q "select string_agg(distinct provider, ',') from public.business_voice")" = 11labs ] && ok "saved choices are marked ElevenLabs" || bad "provider backfill"

# an owner picks Katie in Settings
r=$(as_user $O aal1 "raise notice 'R=%', (public.zella_business_voice_save('$B4', '$KATIE')) ->> 'voice_id';"); [ "$r" = "$KATIE" ] && ok "an owner saves a Cartesia voice" || bad "save: $r"
[ "$(q "select provider from public.business_voice where business_id = '$B4'")" = cartesia ] && ok "business_voice records provider cartesia" || bad "row provider"
EXPECT="{\"model\": \"sonic-3\", \"voiceId\": \"$KATIE\", \"language\": \"en\", \"provider\": \"cartesia\"}"
[ "$(voice $B4)" = "$EXPECT" ] && ok "the config sends Vapi's CartesiaVoice: provider, voiceId, model sonic-3, language en" || bad "cartesia voice: $(voice $B4)"
q "select public.zella_assistant_config('$B4') -> 'assistant' -> 'voice'" > /dev/null
[ "$(q "select (select bool_and(k in ('provider', 'voiceId', 'model', 'language')) from jsonb_object_keys(v) k) and v ->> 'model' = any (array['sonic-3.5', 'sonic-3.5-2026-05-04', 'sonic-3', 'sonic-3-2026-01-12', 'sonic-3-2025-10-27', 'sonic-2', 'sonic-2-2025-06-11', 'sonic-english', 'sonic-multilingual', 'sonic-preview', 'sonic']) from (select public.zella_assistant_config('$B4') -> 'assistant' -> 'voice' v) x")" = t ] && ok "only fields Vapi's CartesiaVoice has, with a model from its list" || bad "shape"
[ "$(q "select count(*) from jsonb_array_elements_text(public.zella_assistant_config('$B4') -> 'problems') p where p ~* '^voice_(tts|cartesia)'")" = 0 ] && ok "no voice problem reported" || bad "problems: $(q "select public.zella_assistant_config('$B4') -> 'problems'")"
setting voice_tts_provider '"vapi"'; setting voice_tts_voice_id '"Elliot"'
[ "$(voice $B4)" = "$EXPECT" ] && ok "a Cartesia choice is used whatever the platform provider (Vapi here)" || bad "under vapi: $(voice $B4)"
setting voice_tts_provider '"11labs"'; setting voice_tts_voice_id '"burt"'
# Spanish: the business's language wins, then the voice's own
as_user $O aal1 "perform public.zella_business_voice_save('$B3', '$KATIE'); raise notice 'R=ok';" > /dev/null
[ "$(q "select (public.zella_assistant_config('$B3') -> 'assistant' -> 'voice') ->> 'language' || ',' || coalesce((public.zella_assistant_config('$B3') -> 'assistant' -> 'voice') ->> 'model', '')")" = "es,sonic-3" ] && ok "a Spanish speaking business gets language es (and no ElevenLabs model)" || bad "spanish: $(voice $B3)"
as_user $O aal1 "perform public.zella_business_voice_save('$B1', '$DANIELA'); raise notice 'R=ok';" > /dev/null
[ "$(q "select (public.zella_assistant_config('$B1') -> 'assistant' -> 'voice') ->> 'language'")" = es ] && ok "without a business language, the voice's own language (Daniela: es)" || bad "voice lang: $(voice $B1)"
q "insert into public.business_languages (business_id, primary_language, extra_languages) values ('$B1', 'en-US', '{}') on conflict (business_id) do update set primary_language = 'en-US'" > /dev/null
[ "$(q "select (public.zella_assistant_config('$B1') -> 'assistant' -> 'voice') ->> 'language'")" = en ] && ok "an English business with a Spanish voice gets language en" || bad "en business: $(voice $B1)"
r=$(as_user $O aal1 "raise notice 'R=%', public.zella_business_voice_save('$B1', 'not-a-voice');"); [[ "$r" == *UNKNOWN_VOICE* ]] && ok "a voice off the list is refused" || bad "unknown: $r"
# a model Vapi doesn't list is left out and reported
setting voice_cartesia_model '"sonic-9"'
[ "$(q "select not ((public.zella_assistant_config('$B4') -> 'assistant' -> 'voice') ? 'model') and (public.zella_assistant_config('$B4') -> 'problems')::text like '%voice_cartesia_model sonic-9 is not a Cartesia model Vapi lists%'")" = t ] && ok "an unknown Cartesia model is left out and reported" || bad "bad model: $(q "select public.zella_assistant_config('$B4') -> 'problems'")"
setting voice_cartesia_model '"sonic-3"'
# Cartesia as the platform voice
setting voice_tts_provider '"cartesia"'; setting voice_tts_voice_id "\"$KATIE\""
[ "$(voice $B5)" = "{\"model\": \"sonic-3\", \"voiceId\": \"$KATIE\", \"provider\": \"cartesia\"}" ] && [ "$(q "select count(*) from jsonb_array_elements_text(public.zella_assistant_config('$B5') -> 'problems') p where p ~* '^voice_(tts|cartesia)'")" = 0 ] && ok "a Cartesia platform voice is sent the same way (no language set: Vapi uses the voice's own), without a provider problem" || bad "platform cartesia: $(voice $B5)"
[ "$(q "select (public.zella_assistant_config('$B2') -> 'assistant' -> 'voice') ->> 'voiceId'")" = "$KATIE" ] && ok "an ElevenLabs business choice is not used while Cartesia is the platform provider (as with Vapi)" || bad "11labs under cartesia: $(voice $B2)"
setting voice_tts_provider '"11labs"'; setting voice_tts_voice_id '"burt"'

# the create business wizard (server only)
apply_as() { q "select public.zella_setup_voice_apply('$B5', $2, '$1') ->> ${3:-'reason'}"; }
[ "$(apply_as $X "'$KATIE'")" = NOT_ALLOWED ] && ok "the wizard save refuses someone who isn't a platform admin" || bad "non admin"
[ "$(apply_as $S "'$KATIE'")" = NOT_ALLOWED ] && ok "and an admin without businesses.manage" || bad "support admin"
[ "$(apply_as $A "'nope'")" = UNKNOWN_VOICE ] && ok "and a voice off the list" || bad "wizard unknown"
[ "$(apply_as $A "'$KATIE'" "'changed'")" = true ] && [ "$(q "select voice_id || ':' || provider || ':' || updated_by from public.business_voice where business_id = '$B5'")" = "$KATIE:cartesia:$A" ] && ok "an admin's wizard choice becomes the business_voice row" || bad "wizard row"
[ "$(q "select count(*) from public.audit_logs where business_id = '$B5' and action = 'receptionist.voice_changed' and user_id = '$A' and new_data ->> 'source' = 'setup_wizard'")" = 1 ] && ok "audited as receptionist.voice_changed (setup_wizard)" || bad "wizard audit"
setting voice_tts_provider '"vapi"'; setting voice_tts_voice_id '"Elliot"'
[ "$(voice $B5)" = "$EXPECT" ] && ok "the assistant config uses the wizard's choice" || bad "wizard config: $(voice $B5)"
setting voice_tts_provider '"11labs"'; setting voice_tts_voice_id '"burt"'
[ "$(apply_as $A "'$KATIE'" "'changed'")" = false ] && ok "the same choice again changes nothing" || bad "same again"
r=$(as_user $A aal2 "raise notice 'R=%', public.zella_setup_voice_apply('$B5', null, '$A');"); [[ "$r" == ERR:*permission* ]] && ok "signed in people can't call it (server only)" || bad "authenticated: $r"
r=$(as_user $O aal1 "raise notice 'R=%', (public.zella_business_voice_save('$B5', 'marissa')) ->> 'voice_id';"); [ "$r" = marissa ] && [ "$(q "select provider from public.business_voice where business_id = '$B5'")" = 11labs ] && ok "the owner changes it later in Settings" || bad "owner later: $r"
[ "$(apply_as $A "null" "'changed'")" = true ] && [ "$(q "select count(*) from public.business_voice where business_id = '$B5'")" = 0 ] && ok "an empty wizard choice means the platform default (row removed)" || bad "clear"

# rollback: drift first, then exact, twice; rows are kept
q "update public.platform_settings set value = value || '[{\"id\":\"extra\",\"name\":\"Extra\"}]' where key = 'voice_tts_choices'" > /dev/null
D=$(fp); out=$(apply "$RB"); [[ "$out" == *ROLLBACK_DRIFT*voice_tts_choices* ]] && [ "$(fp)" = "$D" ] && ok "the rollback refuses a changed voice list and changes nothing" || bad "rb list drift: $out"
q "update public.platform_settings set value = value - (jsonb_array_length(value) - 1) where key = 'voice_tts_choices'" > /dev/null
q "create table public.zcar_keep as select pg_get_functiondef('public.zella_voice_choices()'::regprocedure) d" > /dev/null
q "create or replace function public.zella_voice_choices() returns jsonb language sql stable security definer set search_path = public as \$f\$ select '[]'::jsonb; \$f\$" > /dev/null
D=$(fp); out=$(apply "$RB"); [[ "$out" == *ROLLBACK_DRIFT*zella_voice_choices* ]] && [ "$(fp)" = "$D" ] && ok "the rollback refuses a changed function and changes nothing" || bad "rb fn drift: $out"
q "do \$\$ begin execute (select d from public.zcar_keep); end \$\$; drop table public.zcar_keep" > /dev/null
[ "$(fp)" = "$AFTER" ] && ok "this file's version is back for the real rollback" || bad "repair"

[ "$(q "select count(*) from public.business_voice")" -ge 4 ] || bad "rows before rollback"
ROWS=$(q "select string_agg(business_id || ':' || voice_id, ',' order by business_id) from public.business_voice")
out=$(apply "$RB") && [ "$(fp)" = "$BEFORE" ] && ok "the rollback is exact (functions, columns, constraint, settings, archive)" || bad "rollback: $out"
out=$(apply "$RB") && [ "$(fp)" = "$BEFORE" ] && ok "the rollback runs twice safely" || bad "rollback twice: $out"
[ "$(q "select string_agg(business_id || ':' || voice_id, ',' order by business_id) from public.business_voice")" = "$ROWS" ] && ok "every business_voice row is kept" || bad "rows lost"
[ "$(q "select (public.zella_assistant_config('$B4') -> 'assistant' -> 'voice') ->> 'voiceId'")" = burt ] && ok "after the rollback a kept Cartesia row falls back to the platform voice" || bad "after rb: $(voice $B4)"
[ "$(voice $B2)" = "$(echo "$ELEVEN_BEFORE" | cut -d';' -f2)" ] && ok "and ElevenLabs choices work as before the file" || bad "11labs after rb: $(voice $B2)"
out=$(apply "$MIG") && [ "$(fp)" = "$AFTER" ] && [ "$(q "select provider from public.business_voice where business_id = '$B4'")" = cartesia ] && [ "$(voice $B4)" = "$EXPECT" ] && ok "applies again after the rollback; kept rows get their provider back" || bad "reapply: $out"
finish
