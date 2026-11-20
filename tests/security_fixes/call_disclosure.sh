#!/usr/bin/env bash
# H4: sql/zella_call_disclosure.sql. Checks: before, the greeting says nothing about AI and the assistant sets no
# recording flag (the gap); after, the standard greeting says "I'm the AI receptionist"; a custom greeting without the
# disclosure gets it added (English and other languages), an English one is refused when saved; the recording line and
# artifactPlan.recordingEnabled follow zella_recording_effective (stubbed here to switch it); applies twice; rollback
# twice restores the three functions exactly; drift stops the file and the rollback.
. "$(dirname "$0")/lib.sh"; fresh_db call_disclosure
SIGS="'public.zella_language_catalog()','public.zella_business_language_save(uuid,text,text[],text)','public.zella_assistant_config(uuid)'"
fp() { q "select string_agg(md5(pg_get_functiondef(s::regprocedure)), ',' order by s) from unnest(array[$SIGS]) s"; }; before=$(fp)
BIZ=$(q "insert into public.businesses (name, industry_id, is_active) select 'Sunny Salon', id, true from public.industries limit 1 returning id" | head -1)
O=f8000000-0000-0000-0000-000000000001
q "insert into auth.users (id, email, email_confirmed_at) values ('$O', 'own@disc.test', now()); insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$O', 'owner', 'active')" > /dev/null
first() { q "select public.zella_assistant_config('$BIZ') #>> '{assistant,firstMessage}'"; }
rec() { q "select coalesce(public.zella_assistant_config('$BIZ') #>> '{assistant,artifactPlan,recordingEnabled}', 'unset')"; }
[[ "$(first)" != *AI* ]] && [ "$(rec)" = unset ] && ok "before: no AI disclosure and no recording flag (the gap): $(first)" || bad "before: $(first) $(rec)"

out=$(apply "$REPO/sql/zella_call_disclosure.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_call_disclosure.sql") && ok "applies again" || bad "second apply: $out"
[ "$(fp)" = "99666d94ffea6b2aeff3f680405b30c9,cf6fd925e723c0f3cd1df07e4974a562,ee4cda5da339a236547506ace897a62b" ] && ok "new fingerprints are the recorded ones" || bad "fingerprints $(fp)"
[ "$(first)" = "Thank you for calling Sunny Salon. I'm the AI receptionist. How can I help you today?" ] && ok "the standard greeting says it is the AI receptionist" || bad "default: $(first)"
[ "$(rec)" = false ] && ok "recording is explicitly off (artifactPlan.recordingEnabled false)" || bad "rec: $(rec)"
# with lane G's own setters (each under the zella_recording_policy lock): legal approval with its wording, then the
# business's policy on, gives the recording line and Vapi recording; switching approval off turns both off again
ZO=f8000000-0000-0000-0000-000000000009
q "insert into auth.users (id, email, email_confirmed_at) values ('$ZO', 'zo@disc.test', now()); insert into public.platform_admins (user_id, role, is_active) values ('$ZO', 'zella_owner', true)" > /dev/null
q "select public.zella_recording_legal_set('$ZO', true, 'This call is recorded for quality and training.', 'counsel approved the wording')" > /dev/null && \
q "select public.zella_recording_policy_set('$ZO', '$BIZ', true, 'owner asked for recording')" > /dev/null
[ "$(rec)" = true ] && [[ "$(first)" == *"This call is recorded for quality and training." ]] && ok "lane G's setters turn recording on: the greeting says so and Vapi records" || bad "setters on: $(rec) $(first)"
q "select public.zella_recording_legal_set('$ZO', false, null, 'approval withdrawn')" > /dev/null
[ "$(rec)" = false ] && [[ "$(first)" != *recorded* ]] && ok "withdrawing legal approval turns both off" || bad "setters off: $(rec) $(first)"
save() { local g=${2//\'/\'\'}; as_user $O aal1 "perform public.zella_business_language_save('$BIZ', '$1', '{}', '$g'); raise notice 'R=saved';"; }
r=$(save en-US "Hi, you've reached Sunny Salon. How can I help?"); [[ "$r" == *GREETING_AI_DISCLOSURE* ]] && ok "an English greeting without AI is refused when saved" || bad "save: $r"
r=$(save en-US "Hi, Sunny Salon here, I'm an AI assistant. How can I help?"); [ "$r" = saved ] && ok "one that says AI is saved" || bad "save ok: $r"
[ "$(first)" = "Hi, Sunny Salon here, I'm an AI assistant. How can I help?" ] && ok "and used as written" || bad "custom: $(first)"
q "update public.business_languages set greeting = 'Hello from {name}. How can I help?' where business_id = '$BIZ'" > /dev/null
[ "$(first)" = "Hello from Sunny Salon. How can I help? I'm the AI receptionist." ] && ok "a greeting stored without it (written before this change) still gets the disclosure on calls" || bad "added: $(first)"
r=$(save es "Gracias por llamar a {name}."); [ "$r" = saved ] || bad "spanish save: $r"
[[ "$(first)" == *"inteligencia artificial"* ]] && ok "a Spanish greeting gets the Spanish disclosure: $(first)" || bad "spanish: $(first)"
r=$(save fr ""); [[ "$(first)" == *"intelligence artificielle"* ]] && ok "the standard French greeting gets it too" || bad "french: $(first)"
r=$(save en-US ""); 
q "create or replace function public.zella_recording_effective(p_business uuid) returns boolean language sql stable as \$f\$ select true \$f\$" > /dev/null
[ "$(first)" = "Thank you for calling Sunny Salon. I'm the AI receptionist. How can I help you today? This call is recorded." ] && [ "$(rec)" = true ] && ok "recording on: the greeting says the call is recorded and Vapi records" || bad "rec on: $(first) $(rec)"
q "insert into public.platform_settings (key, value) values ('recording_disclosure_text', '\"This call may be recorded for quality.\"') on conflict (key) do update set value = excluded.value" > /dev/null 2>&1 || q "alter table public.platform_settings disable trigger user; update public.platform_settings set value = '\"This call may be recorded for quality.\"' where key = 'recording_disclosure_text'; alter table public.platform_settings enable trigger user" > /dev/null
[[ "$(first)" == *"This call may be recorded for quality." ]] && ok "the legal wording, once set, is used instead" || bad "legal wording: $(first)"
q "create or replace function public.zella_recording_effective(p_business uuid) returns boolean language sql stable as \$f\$ select false \$f\$" > /dev/null
[[ "$(first)" != *recorded* ]] && ok "recording off: no recording line" || bad "rec off: $(first)"

apply "$REPO/sql/rollback/zella_call_disclosure_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_call_disclosure_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the three functions exactly" || bad "after rollback"
apply "$REPO/sql/zella_call_disclosure.sql" > /dev/null
q "create or replace function public.zella_language_catalog() returns jsonb language sql immutable as \$f\$ select '[]'::jsonb \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_call_disclosure_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_call_disclosure'" > /dev/null
out=$(apply "$REPO/sql/zella_call_disclosure.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift: $out"
finish
