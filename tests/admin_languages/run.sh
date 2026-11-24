#!/usr/bin/env bash
# sql/zella_admin_languages.sql on an isolated copy of production's schema with Cartesia applied (lib.sh; never
# production). Checks: drift in a guarded function stops the file and changes nothing; it applies, and applies again;
# an owner (or manager) can't change languages but can read them; a platform admin can; an admin without
# businesses.manage can't, one whose role has it can; every change is audited; the plan decides (a one language plan
# refuses Spanish, two allows it, the business's own plan names its languages, no plan means no limit); the wizard's
# zella_setup_language_apply follows the plan and is audited; voices follow the languages (listed, refused, and the
# config falls back to the default voice with a note, calls still served); the rollback is exact, safe twice, refuses
# drift; applying again after it works.
. "$(dirname "$0")/lib.sh"; fresh_db langs
MIG="$REPO/sql/zella_admin_languages.sql"; RB="$REPO/sql/rollback/zella_admin_languages_rollback.sql"
SIGS="'public.zella_business_language_save(uuid,text,text[],text)','public.zella_business_language_get(uuid)','public.zella_setup_language_apply(uuid,text,text)','public.zella_business_voice_get(uuid)','public.zella_business_voice_save(uuid,text)','public.zella_setup_voice_apply(uuid,text,uuid)','public.zella_business_voice_choice(uuid)','public.zella_assistant_config(uuid)'"
NEWFN="'zella_language_family','zella_language_plan_info','zella_language_plan_refusal','zella_business_voice_languages','zella_voice_fits','zella_business_voice_unfit'"
KATIE=f786b574-daa5-4673-aa0c-cbe3e8534c02; DANIELA=5c5ad5e7-1020-476b-8b91-fdcbe9cc313c

# production's voice settings (the template has none), as in tests/cartesia_voices/run.sh, with the Cartesia voices
q "insert into public.platform_settings (key, value) values
  ('voice_tts_choices', '[{\"id\":\"burt\",\"name\":\"Burt\"},{\"id\":\"marissa\",\"name\":\"Marissa\"}]'),
  ('voice_tts_provider', '\"11labs\"'), ('voice_tts_voice_id', '\"burt\"'), ('voice_tts_model', '\"eleven_v4_turbo\"'), ('voice_stt_model_multilingual', '\"nova-2\"')
  on conflict (key) do update set value = excluded.value" > /dev/null
q "update public.platform_settings set value = value || '[
    {\"id\": \"$KATIE\", \"name\": \"Katie\", \"provider\": \"cartesia\", \"language\": \"en\", \"gender\": \"female\"},
    {\"id\": \"$DANIELA\", \"name\": \"Daniela\", \"provider\": \"cartesia\", \"language\": \"es\", \"gender\": \"female\"}]'::jsonb where key = 'voice_tts_choices'" > /dev/null

fp() {   # everything the file changes
  q "select md5(string_agg(x, '|' order by x collate \"C\")) from (
       select s || '=' || md5(pg_get_functiondef(s::regprocedure)) x from unnest(array[$SIGS]) s
       union all select 'fn:' || p.oid::regprocedure::text from pg_proc p where p.proname in ($NEWFN)
       union all select 'arch:' || count(*) from public.zella_function_archive where migration = 'zella_admin_languages') t"
}
mkbiz() { q "insert into public.businesses (name, industry_id, is_active) select '$1', id, true from public.industries limit 1 returning id" | head -1; }
voice() { q "select public.zella_assistant_config('$1') -> 'assistant' -> 'voice' ->> 'voiceId'"; }
langs() { q "select primary_language || ':' || array_to_string(extra_languages, ',') from public.business_languages where business_id = '$1'"; }
save() {   # save <user> <business> <primary> <extras array literal>
  as_user "$1" "perform public.zella_business_language_save('$2', '$3', $4, null); raise notice 'R=ok';"
}
plan() {   # plan <business> <version> <languages>: the business's own plan (Create Business step 9)
  q "insert into public.business_plans (business_id, version, tier, billing_interval, price_cents, minutes, texts, emails, team_seats, phone_numbers, locations, languages, idempotency_key, values_hash)
     values ('$1', $2, 'base', 'monthly', 29900, 500, 100, 100, 3, 1, 1, '$3', 'idem-$2-$(date +%s%N)', 'h$2')" > /dev/null
}

B1=$(mkbiz "Plain Co"); B2=$(mkbiz "Plan One Co"); B3=$(mkbiz "Legacy Co"); B4=$(mkbiz "Voice Co"); B5=$(mkbiz "Wizard Co")
O=a1000000-0000-0000-0000-000000000001; A=a1000000-0000-0000-0000-000000000002; S=a1000000-0000-0000-0000-000000000003; M=a1000000-0000-0000-0000-000000000004; G=a1000000-0000-0000-0000-000000000005
q "insert into auth.users (id, email, email_confirmed_at) values ('$O', 'own@lang.test', now()), ('$A', 'adm@lang.test', now()), ('$S', 'sup@lang.test', now()), ('$M', 'mgr@lang.test', now()), ('$G', 'ops@lang.test', now())" > /dev/null
q "insert into public.business_members (business_id, user_id, role, status) select b, '$O'::uuid, 'owner', 'active' from unnest(array['$B1','$B2','$B3','$B4','$B5']::uuid[]) b
   union all select '$B1'::uuid, '$M'::uuid, 'manager', 'active'" > /dev/null
q "insert into public.platform_admins (user_id, role, is_active) values ('$A', 'zella_owner', true), ('$S', 'support_admin', true), ('$G', 'platform_operations', true)" > /dev/null
q "insert into public.platform_role_permissions (role, permission) values ('support_admin', 'businesses.view') on conflict do nothing" > /dev/null

# the behaviour today: an owner saves languages
r=$(save $O $B4 en-US "array['es']"); [ "$r" = ok ] && ok "before the file, an owner can change languages (the bug)" || bad "before: $r"
q "delete from public.business_languages where business_id = '$B4'" > /dev/null
BEFORE=$(fp)

# drift stops the file, nothing changes
q "create table public.zal_keep as select pg_get_functiondef('public.zella_business_voice_choice(uuid)'::regprocedure) d" > /dev/null
q "create or replace function public.zella_business_voice_choice(p_business_id uuid) returns jsonb language sql stable security definer set search_path = '' as \$f\$ select null::jsonb /* changed */; \$f\$" > /dev/null
DRIFT=$(fp)
out=$(apply "$MIG"); [[ "$out" == *VERSION_MISMATCH*zella_business_voice_choice* ]] && [ "$(fp)" = "$DRIFT" ] && ok "a changed function stops the file (VERSION_MISMATCH) and nothing changes" || bad "drift: $out"
q "do \$\$ begin execute (select d from public.zal_keep); end \$\$; drop table public.zal_keep" > /dev/null
[ "$(fp)" = "$BEFORE" ] && ok "the expected version is back for the real test" || bad "restore drift"

out=$(apply "$MIG") && ok "applies" || { bad "applies: $out"; finish; }
AFTER=$(fp)
out=$(apply "$MIG") && [ "$(fp)" = "$AFTER" ] && ok "applies again, changing nothing" || bad "second apply: $out"
[ "$(q "select count(*) from public.zella_function_archive where migration = 'zella_admin_languages'")" = 8 ] && ok "the eight changed functions are archived" || bad "archive"
[ "$(q "select count(*) from pg_proc p where p.proname in ($NEWFN) and has_function_privilege('authenticated', p.oid, 'execute')")" = 0 ] && ok "the new helpers are server only" || bad "helper grants"

# 1. only platform admins change languages
r=$(save $O $B1 en-US "array['es']"); [ "$r" = "ERR:LANGUAGES_ADMIN_ONLY" ] && ok "an owner is refused (LANGUAGES_ADMIN_ONLY)" || bad "owner: $r"
r=$(save $M $B1 en-US "array['es']"); [ "$r" = "ERR:LANGUAGES_ADMIN_ONLY" ] && ok "a manager is refused" || bad "manager: $r"
[ -z "$(langs $B1)" ] && ok "and nothing was saved" || bad "owner saved: $(langs $B1)"
r=$(as_user $O "raise notice 'R=%', (select (d ->> 'primary') || ',' || (d ->> 'can_edit') || ',' || (d ->> 'admin_only') from (select public.zella_business_language_get('$B1') d) x);")
[ "$r" = "en-US,false,true" ] && ok "the owner still reads the languages (can_edit false)" || bad "owner read: $r"
r=$(save $S $B1 en-US "array['es']"); [ "$r" = "ERR:LANGUAGES_ADMIN_ONLY" ] && ok "an admin without businesses.manage is refused" || bad "support admin: $r"
r=$(save $G $B1 en-US "array['es']"); [ "$r" = "ERR:LANGUAGES_ADMIN_ONLY" ] && ok "so is platform operations while its role lacks businesses.manage" || bad "ops before grant: $r"
q "insert into public.platform_role_permissions (role, permission) values ('platform_operations', 'businesses.manage')" > /dev/null
r=$(save $G $B1 en-US "array['es']"); [ "$r" = ok ] && [ "$(langs $B1)" = "en-US:es" ] && ok "an admin whose role has businesses.manage changes them" || bad "ops: $r $(langs $B1)"
q "update public.platform_admins set is_active = false where user_id = '$G'" > /dev/null
r=$(save $G $B1 en-US "'{}'"); [ "$r" = "ERR:LANGUAGES_ADMIN_ONLY" ] && ok "an inactive admin is refused" || bad "inactive: $r"
r=$(save $A $B1 en-US "'{}'"); [ "$r" = ok ] && [ "$(langs $B1)" = "en-US:" ] && ok "a Zella Voice owner admin changes them" || bad "zella owner: $r"
[ "$(q "select count(*) from public.audit_logs where business_id = '$B1' and action = 'receptionist.languages_changed' and new_data ->> 'source' = 'admin' and (new_data ->> 'by_platform_admin')::boolean")" = 2 ] \
  && [ "$(q "select old_data ->> 'extras' || '>' || (new_data ->> 'extras') from public.audit_logs where business_id = '$B1' and action = 'receptionist.languages_changed' and user_id = '$A'")" = '["es"]>[]' ] \
  && ok "each change is audited with who, before and after" || bad "audit: $(q "select user_id, old_data, new_data from public.audit_logs where business_id = '$B1' and action = 'receptionist.languages_changed'")"
r=$(save $A $B1 en-US "'{}'"); [ "$(q "select count(*) from public.audit_logs where business_id = '$B1' and action = 'receptionist.languages_changed'")" = 2 ] && ok "saving the same languages again records nothing new" || bad "noop audit"
r=$(as_user $S "raise notice 'R=%', (public.zella_business_language_get('$B1')) ->> 'can_edit';"); [ "$r" = false ] && ok "an admin with businesses.view reads them, can_edit false" || bad "support read: $r"

# 2. the plan decides
r=$(as_user $A "raise notice 'R=%', (public.zella_business_language_get('$B2')) -> 'plan' ->> 'source';"); [ "$r" = none ] && ok "no plan and no subscription: reported as source none (no limit)" || bad "none: $r"
plan $B2 1 "{en}"
r=$(save $A $B2 en-US "array['es']"); [ "$r" = "ERR:PLAN_LANGUAGES" ] && ok "a plan with 1 language refuses Spanish as a second language" || bad "plan1 extra: $r"
r=$(save $A $B2 es "'{}'"); [ "$r" = "ERR:PLAN_LANGUAGES" ] && ok "and Spanish as the only language" || bad "plan1 es only: $r"
r=$(save $A $B2 en-GB "'{}'"); [ "$r" = ok ] && ok "English is allowed" || bad "plan1 en: $r"
r=$(as_user $A "raise notice 'R=%', (select (d -> 'plan' ->> 'source') || ',' || (d -> 'plan' ->> 'plan') || ',' || (d -> 'plan' ->> 'allowance') || ',' || (d -> 'plan' ->> 'spanish_allowed') from (select public.zella_business_language_get('$B2') d) x);")
[ "$r" = "business_plan,Base v1,1,false" ] && ok "the admin sees the plan: Base v1, 1 language, no Spanish" || bad "plan info: $r"
plan $B2 2 "{en,es}"
r=$(save $A $B2 en-US "array['es']"); [ "$r" = ok ] && [ "$(langs $B2)" = "en-US:es" ] && ok "a plan with 2 languages (English and Spanish) allows Spanish" || bad "plan2: $r"
r=$(save $A $B2 en-US "array['fr']"); [ "$r" = "ERR:PLAN_LANGUAGES" ] && ok "a language the plan doesn't name is refused" || bad "plan2 fr: $r"
r=$(save $A $B2 en-US "array['es','es-419']"); [ "$r" = "ERR:PLAN_LANGUAGES" ] && ok "more languages than the plan's count are refused" || bad "plan2 count: $r"
plan $B2 3 "{en}"
r=$(as_user $A "raise notice 'R=%', (public.zella_business_language_get('$B2')) ->> 'within_plan';"); [ "$r" = false ] && ok "after a move to a smaller plan the page says the saved languages are over it" || bad "within: $r"
# a subscription plan that only counts
L1=$(q "insert into public.plans (name, slug, limits) values ('Starter', 'zal-starter', '{\"languages\": 1}') returning id" | head -1)
L2=$(q "insert into public.plans (name, slug, limits) values ('Growth', 'zal-growth', '{\"languages\": 2}') returning id" | head -1)
q "insert into public.subscriptions (business_id, plan_id, status, current_period_start, current_period_end) values ('$B3', '$L1', 'active', now() - interval '1 day', now() + interval '29 days')" > /dev/null
r=$(save $A $B3 en-US "array['es']"); [ "$r" = "ERR:PLAN_LANGUAGES" ] && ok "a subscription plan with languages 1 refuses Spanish" || bad "legacy1: $r"
r=$(save $A $B3 es "'{}'"); [ "$r" = "ERR:PLAN_LANGUAGES" ] && ok "1 means English only" || bad "legacy1 es: $r"
q "update public.subscriptions set plan_id = '$L2' where business_id = '$B3'" > /dev/null
r=$(save $A $B3 en-US "array['es']"); [ "$r" = ok ] && ok "languages 2 allows English and Spanish" || bad "legacy2: $r"
r=$(save $A $B3 en-US "array['es','fr']"); [ "$r" = "ERR:PLAN_LANGUAGES" ] && ok "and not a third" || bad "legacy2 three: $r"

# the create business wizard (server only)
[ "$(q "select public.zella_setup_language_apply('$B5', 'en-US+es-US', null) ->> 'changed'")" = true ] && ok "the wizard sets English and Spanish when there is no plan yet" || bad "wizard none"
[ "$(q "select count(*) from public.audit_logs where business_id = '$B5' and action = 'receptionist.languages_changed' and new_data ->> 'source' = 'setup_wizard'")" = 1 ] && ok "audited (setup_wizard)" || bad "wizard audit"
[ "$(q "select public.zella_setup_language_apply('$B5', 'en-US+es-US', null) ->> 'changed'")" = false ] && [ "$(q "select count(*) from public.audit_logs where business_id = '$B5' and action = 'receptionist.languages_changed'")" = 1 ] && ok "saving the step again changes and records nothing" || bad "wizard again"
plan $B5 1 "{en}"
[ "$(q "select (r ->> 'reason') || ',' || (r -> 'plan' ->> 'allowance') from (select public.zella_setup_language_apply('$B5', 'es-US', null) r) x")" = "PLAN_LANGUAGES,1" ] && ok "the wizard refuses Spanish on a 1 language plan and says why" || bad "wizard plan"
r=$(as_user $A "raise notice 'R=%', public.zella_setup_language_apply('$B5', 'en-US', null);"); [[ "$r" == ERR:*permission* ]] && ok "signed in people can't call the wizard function (server only)" || bad "wizard authenticated: $r"

# 3. voices follow the languages
q "select public.zella_setup_language_apply('$B4', 'en-US', null)" > /dev/null
ids() { as_user $O "raise notice 'R=%', (select string_agg(c ->> 'name', ',' order by n) from jsonb_array_elements(public.zella_business_voice_get('$1') -> 'choices') with ordinality x(c, n));"; }
[ "$(ids $B4)" = "Burt,Marissa,Katie" ] && ok "an English business is offered the multilingual voices and English ones only" || bad "en choices: $(ids $B4)"
r=$(as_user $O "raise notice 'R=%', public.zella_business_voice_save('$B4', '$DANIELA');"); [ "$r" = "ERR:VOICE_LANGUAGE" ] && ok "a Spanish voice is refused for it (VOICE_LANGUAGE)" || bad "save es: $r"
[ "$(q "select public.zella_setup_voice_apply('$B4', '$DANIELA', '$A') ->> 'reason'")" = VOICE_LANGUAGE ] && ok "and by the wizard" || bad "wizard es"
save $A $B4 en-US "array['es']" > /dev/null
[ "$(ids $B4)" = "Burt,Marissa,Katie,Daniela" ] && ok "with Spanish added, the Spanish voices are offered too" || bad "en+es choices: $(ids $B4)"
r=$(as_user $O "raise notice 'R=%', (public.zella_business_voice_save('$B4', '$DANIELA')) ->> 'voice_id';"); [ "$r" = "$DANIELA" ] && ok "and can be saved" || bad "save es ok: $r"
[ "$(voice $B4)" = "$DANIELA" ] && ok "calls use it" || bad "config es: $(voice $B4)"
save $A $B4 en-US "'{}'" > /dev/null
[ "$(voice $B4)" = burt ] && ok "after Spanish is removed, calls fall back to the platform default voice" || bad "fallback: $(voice $B4)"
[ "$(q "select ((c -> 'notes')::text like '%The saved voice Daniela does not speak this business''s languages, so calls use the Zella Voice default voice%')::text || ',' || (c -> 'problems')::text from (select public.zella_assistant_config('$B4') c) x")" = "true,$(q "select (public.zella_assistant_config('$B1') -> 'problems')::text")" ] \
  && ok "the config says so in its notes, and adds no problem (problems stop calls; its problems match a business without a voice)" || bad "notes: $(q "select public.zella_assistant_config('$B4') -> 'notes'")"
r=$(as_user $O "raise notice 'R=%', (select coalesce(d ->> 'voice_id', 'null') || ',' || (d ->> 'unfit_voice_id') from (select public.zella_business_voice_get('$B4') d) x);"); [ "$r" = "null,$DANIELA" ] && ok "Settings shows the default with the saved voice named as not fitting" || bad "get unfit: $r"
[ "$(q "select voice_id from public.business_voice where business_id = '$B4'")" = "$DANIELA" ] && ok "the saved choice is kept (it works again if Spanish comes back)" || bad "row kept"
save $A $B4 es "'{}'" > /dev/null
[ "$(ids $B4)" = "Burt,Marissa,Daniela" ] && [ "$(voice $B4)" = "$DANIELA" ] && ok "a Spanish only business gets the Spanish and multilingual voices, and its Spanish voice back" || bad "es only: $(ids $B4) $(voice $B4)"

# rollback: drift first, then exact, twice; rows are kept
q "create table public.zal_keep as select pg_get_functiondef('public.zella_business_voice_get(uuid)'::regprocedure) d" > /dev/null
q "create or replace function public.zella_business_voice_get(p_business_id uuid) returns jsonb language sql stable security definer set search_path = public as \$f\$ select '{}'::jsonb; \$f\$" > /dev/null
D=$(fp); out=$(apply "$RB"); [[ "$out" == *ROLLBACK_DRIFT*zella_business_voice_get* ]] && [ "$(fp)" = "$D" ] && ok "the rollback refuses a changed function and changes nothing" || bad "rb drift: $out"
q "do \$\$ begin execute (select d from public.zal_keep); end \$\$; drop table public.zal_keep" > /dev/null
[ "$(fp)" = "$AFTER" ] && ok "this file's version is back for the real rollback" || bad "repair"
ROWS=$(q "select md5(string_agg(business_id || ':' || primary_language || ':' || array_to_string(extra_languages, ','), ',' order by business_id)) from public.business_languages")
VROWS=$(q "select md5(string_agg(business_id || ':' || voice_id, ',' order by business_id)) from public.business_voice")
AUD=$(q "select count(*) from public.audit_logs where action = 'receptionist.languages_changed'")
out=$(apply "$RB") && [ "$(fp)" = "$BEFORE" ] && ok "the rollback is exact (eight functions back, six helpers gone, archive cleared)" || bad "rollback: $out"
out=$(apply "$RB") && [ "$(fp)" = "$BEFORE" ] && ok "the rollback runs twice safely" || bad "rollback twice: $out"
[ "$(q "select md5(string_agg(business_id || ':' || primary_language || ':' || array_to_string(extra_languages, ','), ',' order by business_id)) from public.business_languages")" = "$ROWS" ] \
  && [ "$(q "select md5(string_agg(business_id || ':' || voice_id, ',' order by business_id)) from public.business_voice")" = "$VROWS" ] \
  && [ "$(q "select count(*) from public.audit_logs where action = 'receptionist.languages_changed'")" = "$AUD" ] && ok "saved languages, voices and audit rows are kept" || bad "rows"
r=$(save $O $B1 en-US "'{}'"); [ "$r" = ok ] && ok "after the rollback owners can save again (the rule before the file)" || bad "after rb: $r"
out=$(apply "$MIG") && [ "$(fp)" = "$AFTER" ] && ok "applies again after the rollback" || bad "reapply: $out"
# with sql/zella_silence_timeout.sql, which also changes zella_assistant_config: both orders give the same function,
# and each rollback takes out only its own change, whichever was applied first
SIL="$REPO/sql/zella_silence_timeout.sql"; SILRB="$REPO/sql/rollback/zella_silence_timeout_rollback.sql"
if [ -f "$SIL" ] && [ -f "$SILRB" ]; then
  MAIN_DB=$DB
  cfg() { q "select md5(pg_get_functiondef('public.zella_assistant_config(uuid)'::regprocedure))"; }
  for order in languages_first silence_first; do
    DB="zal_order_$order"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
    "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
    if [ $order = languages_first ]; then o1=$(apply "$MIG") && c1=$(cfg) && o2=$(apply "$SIL"); else o1=$(apply "$SIL") && c1=$(cfg) && o2=$(apply "$MIG"); fi
    [ $? -eq 0 ] && [ "$c1" = "$([ $order = languages_first ] && echo 89e090f31515920ac198874946e15780 || echo 7cb1c1ad81a872b2118d66db2eeba959)" ] \
      && [ "$(cfg)" = 36ba71051bc6382c08e782d0a9754e20 ] && ok "$order: both apply and zella_assistant_config is 36ba7105" || bad "$order apply: $o1 $o2 $(cfg)"
    out=$(apply "$MIG") && [ "$(cfg)" = 36ba71051bc6382c08e782d0a9754e20 ] && ok "$order: this file again changes nothing" || bad "$order again: $out"
    q "create table public.zal_keep as select pg_get_functiondef('public.zella_assistant_config(uuid)'::regprocedure) d" > /dev/null
    q "do \$\$ begin execute replace((select d from public.zal_keep), 'Choose another voice.', 'Choose another voice!'); end \$\$" > /dev/null
    out=$(apply "$RB"); [[ "$out" == *ROLLBACK_DRIFT*zella_assistant_config* ]] && [ "$(q "select count(*) from public.zella_function_archive where migration = 'zella_admin_languages'")" = 8 ] && ok "$order: the rollback refuses a changed zella_assistant_config" || bad "$order rb drift: $out"
    q "do \$\$ begin execute (select d from public.zal_keep); end \$\$; drop table public.zal_keep" > /dev/null
    out=$(apply "$RB") && [ "$(cfg)" = 7cb1c1ad81a872b2118d66db2eeba959 ] && [ "$(q "select count(*) from pg_proc where proname = 'zella_voice_fits'")" = 0 ] \
      && ok "$order: this file's rollback keeps the silence timeout (7cb1c1ad)" || bad "$order rb: $out $(cfg)"
    out=$(apply "$RB") && [ "$(cfg)" = 7cb1c1ad81a872b2118d66db2eeba959 ] && ok "$order: and runs twice safely" || bad "$order rb twice: $out"
    out=$(apply "$MIG") && out=$(apply "$SILRB") && [ "$(cfg)" = 89e090f31515920ac198874946e15780 ] && out=$(apply "$RB") && [ "$(cfg)" = e2ae7cfcd60ebf32a7d6bd2247e39ab3 ] \
      && ok "$order: rolled back the other way round, production's version comes back" || bad "$order other way: $out $(cfg)"
    [ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
  done
  DB=$MAIN_DB
else
  echo "SKIP the order checks with sql/zella_silence_timeout.sql (not in this checkout)"
fi
finish
