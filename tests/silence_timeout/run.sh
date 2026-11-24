#!/usr/bin/env bash
# sql/zella_silence_timeout.sql on an isolated copy of production's schema (lib.sh; never production). Checks: drift
# stops the file and changes nothing; it applies, and applies again; the config gains only "hooks" (everything else
# exactly as before, for English, Spanish and two language businesses); the hooks are one "Are you still there?" at
# 30 s and the goodbye with the business's name at 60 s, then the call ends, in English and Spanish; names with an
# apostrophe, an ampersand or dashes, and a missing name; the setting is clamped (never below 60, never above Vapi's
# 1000); the shape matches @vapi-ai/server-sdk 3.0.0 (deno type check against CreateAssistantDto, and the fields named
# in the SDK's own files); both orders with sql/zella_admin_languages.sql; the rollback is exact on both bases, safe
# twice, refuses drift; applying again after the rollback works.
. "$(dirname "$0")/lib.sh"
MIG="$REPO/sql/zella_silence_timeout.sql"; RB="$REPO/sql/rollback/zella_silence_timeout_rollback.sql"
SIG="'public.zella_assistant_config(uuid)'::regprocedure"
PROD=e2ae7cfcd60ebf32a7d6bd2247e39ab3; MINE_PROD=7cb1c1ad81a872b2118d66db2eeba959
LANG_BASE=89e090f31515920ac198874946e15780; MINE_LANG=36ba71051bc6382c08e782d0a9754e20
SDK=$(ls -d /root/.cache/deno/npm/registry.npmjs.org/@vapi-ai/server-sdk/3.0.0/dist/cjs/api/types 2>/dev/null | head -1)
DENO=${DENO:-$(command -v deno || true)}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# the admin languages migration (another pull request): from this tree once merged, else from its branch
LANGS="$REPO/sql/zella_admin_languages.sql"
if [ ! -f "$LANGS" ]; then
  git -C "$REPO" show origin/claude/admin-only-languages:sql/zella_admin_languages.sql > "$WORK/langs.sql" 2> /dev/null && LANGS="$WORK/langs.sql" || LANGS=""
fi

md5f() { q "select md5(pg_get_functiondef($SIG))"; }
fp() {   # everything the file changes
  q "select md5(string_agg(x, '|' order by x collate \"C\")) from (
       select 'cfg=' || md5(pg_get_functiondef($SIG)) x
       union all select 'fn:' || p.oid::regprocedure::text from pg_proc p where p.proname in ('zella_silence_hooks', 'zella_silence_timeout_seconds')
       union all select 'set:' || key || '=' || value::text from public.platform_settings where key = 'voice_silence_timeout_seconds'
       union all select 'ms:' || migration || ':' || key from public.zella_migration_settings where migration = 'zella_silence_timeout'
       union all select 'arch:' || count(*) from public.zella_function_archive where migration = 'zella_silence_timeout') t"
}
mkbiz() { q "insert into public.businesses (name, industry_id, is_active) select \$n\$$1\$n\$, id, true from public.industries limit 1 returning id" | head -1; }
lang() { q "insert into public.business_languages (business_id, primary_language, extra_languages) values ('$1', '$2', '$3')
  on conflict (business_id) do update set primary_language = excluded.primary_language, extra_languages = excluded.extra_languages" > /dev/null; }
setting() { q "insert into public.platform_settings (key, value) values ('$1', '$2') on conflict (key) do update set value = excluded.value" > /dev/null; }
hooks() { q "select public.zella_assistant_config('$1') -> 'assistant' -> 'hooks'"; }
# hook <business> <jsonpath>: one value from the hooks
hv() { q "select jsonb_path_query_first(public.zella_assistant_config('$1') -> 'assistant' -> 'hooks', '$2') #>> '{}'"; }
rest() { q "select md5((public.zella_assistant_config('$1') #- '{assistant,hooks}')::text)"; }

setup_businesses() {
  BE=$(mkbiz "Joe's Plumbing & Heating"); BS=$(mkbiz "Clínica Dental Sonrisa"); BB=$(mkbiz "Smith-Jones — Dental"); BN=$(mkbiz "Name Later")
  q "update public.businesses set name = '   ' where id = '$BN'" > /dev/null
  lang "$BE" en-US '{}'; lang "$BS" es-US '{}'; lang "$BB" en-US '{es-US}'
  setting voice_stt_model_multilingual '"nova-2"'
  ALL="$BE $BS $BB $BN"
}
snapshot() { local b s=""; for b in $ALL; do s="$s$(rest "$b");"; done; echo "$s"; }

# ---------------------------------------------------------------- production's version first
fresh_db prod_first; setup_businesses
[ "$(md5f)" = "$PROD" ] && ok "the copy has production's zella_assistant_config ($PROD)" || bad "base md5 $(md5f)"
BEFORE=$(fp); CFG_BEFORE=$(snapshot)
[ "$(q "select count(*) from public.businesses b where b.id in ('$BE','$BS','$BB','$BN') and public.zella_assistant_config(b.id) -> 'assistant' ? 'hooks'")" = 0 ] && ok "before: no silence hooks (Vapi's default applies)" || bad "hooks before"

# drift stops the file, nothing changes
q "create table public.zsil_keep as select pg_get_functiondef($SIG) d" > /dev/null
q "do \$\$ begin execute replace((select d from public.zsil_keep), 'temperature'', 0.3', 'temperature'', 0.4'); end \$\$" > /dev/null
DRIFT=$(fp); out=$(apply "$MIG")
[[ "$out" == *VERSION_MISMATCH*zella_assistant_config* ]] && [ "$(fp)" = "$DRIFT" ] && [ "$(q "select count(*) from pg_proc where proname = 'zella_silence_hooks'")" = 0 ] \
  && ok "a changed zella_assistant_config stops the file (VERSION_MISMATCH) and nothing changes" || bad "drift: $out"
q "do \$\$ begin execute (select d from public.zsil_keep); end \$\$; drop table public.zsil_keep" > /dev/null
[ "$(fp)" = "$BEFORE" ] && ok "production's version is back for the real test" || bad "restore drift"

out=$(apply "$MIG") && [ "$(md5f)" = "$MINE_PROD" ] && ok "applies on production's version ($MINE_PROD)" || { bad "applies: $out $(md5f)"; finish; }
AFTER=$(fp)
out=$(apply "$MIG") && [ "$(fp)" = "$AFTER" ] && ok "applies again, changing nothing" || bad "second apply: $out"
[ "$(q "select count(*) from public.zella_migration_settings where migration = 'zella_silence_timeout' and key = 'voice_silence_timeout_seconds'")$(q "select value from public.platform_settings where key = 'voice_silence_timeout_seconds'")" = "160" ] \
  && ok "voice_silence_timeout_seconds = 60, recorded in zella_migration_settings" || bad "setting"
[ "$(snapshot)" = "$CFG_BEFORE" ] && ok "nothing else in the config changed (English, Spanish, two languages, no name)" || bad "config changed beyond hooks"
[ "$(q "select string_agg(k, ',' order by k) from jsonb_object_keys(public.zella_assistant_config('$BE') -> 'assistant') k where k = 'hooks'")" = hooks ] && ok "the assistant now carries hooks" || bad "no hooks key"

# the hooks: shape and timing
H=$(hooks "$BE")
[ "$(q "select jsonb_array_length('$(echo "$H" | sed "s/'/''/g")'::jsonb)")" = 2 ] && ok "two hooks" || bad "hook count: $H"
[ "$(hv "$BE" '$[0].on')|$(hv "$BE" '$[0].name')|$(hv "$BE" '$[0].options.timeoutSeconds')|$(hv "$BE" '$[0].options.triggerMaxCount')|$(hv "$BE" '$[0].options.triggerResetMode')|$(hv "$BE" '$[0].do[0].type')|$(hv "$BE" '$[0].do[0].exact')" \
  = "customer.speech.timeout|zella_silence_check|30|1|onUserSpeech|say|Are you still there?" ] && ok "after 30 s of silence: one \"Are you still there?\" (reset when the caller speaks)" || bad "check hook: $H"
[ "$(hv "$BE" '$[1].on')|$(hv "$BE" '$[1].name')|$(hv "$BE" '$[1].options.timeoutSeconds')|$(hv "$BE" '$[1].options.triggerMaxCount')|$(hv "$BE" '$[1].options.triggerResetMode')|$(hv "$BE" '$[1].do[0].type')|$(hv "$BE" '$[1].do[0].tool.type')|$(hv "$BE" '$[1].do[0].tool.messages[0].type')|$(hv "$BE" '$[1].do[0].tool.messages[0].blocking')" \
  = "customer.speech.timeout|zella_silence_goodbye|60|1|onUserSpeech|tool|endCall|request-start|true" ] && ok "at 60 s: the endCall tool, its goodbye spoken first (blocking request-start)" || bad "goodbye hook: $H"
[ "$(q "select coalesce(min((h #>> '{options,timeoutSeconds}')::int), 0) from jsonb_array_elements(public.zella_assistant_config('$BE') -> 'assistant' -> 'hooks') h where h::text like '%endCall%'")" -ge 60 ] && ok "nothing ends the call before 60 s of silence" || bad "ends early"
[ "$(hv "$BE" '$[1].do[0].tool.messages[0].content')" = "It seems we've been disconnected. Thanks for calling Joe's Plumbing & Heating, goodbye." ] \
  && [ "$(hv "$BE" '$[1].do[0].tool.messages[0].contents.size()')" = 1 ] && [ "$(hv "$BE" '$[1].do[0].tool.messages[0].contents[0].language')" = en ] \
  && ok "English goodbye with the name as written (apostrophe and ampersand kept)" || bad "english goodbye: $(hooks "$BE")"
[ "$(hv "$BS" '$[0].do[0].exact')" = "¿Sigue ahí?" ] && [ "$(hv "$BS" '$[1].do[0].tool.messages[0].content')" = "Parece que se cortó la llamada. Gracias por llamar a Clínica Dental Sonrisa, adiós." ] \
  && [ "$(hv "$BS" '$[1].do[0].tool.messages[0].contents[0].language')" = es ] && ok "a Spanish speaking business: \"¿Sigue ahí?\" and the Spanish goodbye with its name" || bad "spanish: $(hooks "$BS")"
[ "$(hv "$BB" '$[1].do[0].tool.messages[0].content')" = "It seems we've been disconnected. Thanks for calling Smith Jones Dental, goodbye." ] && ok "dashes in a name are spoken as spaces (no dashes in spoken text)" || bad "dash name: $(hooks "$BB")"
[ "$(q "select string_agg((c ->> 'language') || '=' || (c ->> 'text'), ' / ' order by n) from jsonb_array_elements(jsonb_path_query_first(public.zella_assistant_config('$BB') -> 'assistant' -> 'hooks', '\$[1].do[0].tool.messages[0].contents')) with ordinality x(c, n)")" \
  = "en=It seems we've been disconnected. Thanks for calling Smith Jones Dental, goodbye. / es=Parece que se cortó la llamada. Gracias por llamar a Smith Jones Dental, adiós." ] \
  && ok "an English business that also speaks Spanish gets both goodbyes, English first (Vapi picks the call's language)" || bad "bilingual: $(hooks "$BB")"
[ "$(hv "$BN" '$[1].do[0].tool.messages[0].content')" = "It seems we've been disconnected. Thanks for calling, goodbye." ] && ok "no name: \"Thanks for calling, goodbye.\"" || bad "no name: $(hooks "$BN")"
lang "$BN" es-MX '{}'
[ "$(hv "$BN" '$[1].do[0].tool.messages[0].content')" = "Parece que se cortó la llamada. Gracias por llamar, adiós." ] && ok "no name, in Spanish: \"Gracias por llamar, adiós.\"" || bad "no name es: $(hooks "$BN")"
q "update public.businesses set name = '——' where id = '$BN'" > /dev/null
[ "$(hv "$BN" '$[1].do[0].tool.messages[0].content')" = "Parece que se cortó la llamada. Gracias por llamar, adiós." ] && ok "a name of only dashes counts as no name" || bad "dash only: $(hooks "$BN")"
q "delete from public.business_languages where business_id = '$BN'; update public.businesses set name = 'Plain Co' where id = '$BN'" > /dev/null
[ "$(hv "$BN" '$[0].do[0].exact')|$(hv "$BN" '$[1].do[0].tool.messages[0].content')" = "Are you still there?|It seems we've been disconnected. Thanks for calling Plain Co, goodbye." ] && ok "no language row: English" || bad "no lang row"
q "update public.businesses set name = '   ' where id = '$BN'" > /dev/null   # as it was (no language row)
[ "$(q "select count(*) from public.businesses b, jsonb_path_query(public.zella_assistant_config(b.id) -> 'assistant' -> 'hooks', '\$[*].do[*].exact') t where b.id in ('$BE','$BS','$BB','$BN') and t #>> '{}' ~ '[‐‑‒–—―−-]'")$(q "select count(*) from public.businesses b, jsonb_path_query(public.zella_assistant_config(b.id) -> 'assistant' -> 'hooks', '\$[*].do[*].tool.messages[*].**.text') t where b.id in ('$BE','$BS','$BB','$BN') and t #>> '{}' ~ '[‐‑‒–—―−-]'")$(q "select count(*) from public.businesses b, jsonb_path_query(public.zella_assistant_config(b.id) -> 'assistant' -> 'hooks', '\$[*].do[*].tool.messages[*].content') t where b.id in ('$BE','$BS','$BB','$BN') and t #>> '{}' ~ '[‐‑‒–—―−-]'")" = 000 ] && ok "no dash in any spoken text" || bad "dash spoken"

# the setting changes without code, clamped to 60..1000
t() { setting voice_silence_timeout_seconds "$1"; echo "$(hv "$BE" '$[0].options.timeoutSeconds')/$(hv "$BE" '$[1].options.timeoutSeconds')"; }
[ "$(t 90)" = 45/90 ] && ok "90 s: check at 45, goodbye at 90" || bad "90: $(t 90)"
[ "$(t '"75"')" = 37/75 ] && ok "a number as text works (75)" || bad "text 75"
[ "$(t 30)" = 30/60 ] && ok "below 60 is raised to 60 (never ends sooner)" || bad "30: $(t 30)"
[ "$(t 5000)" = 500/1000 ] && ok "above Vapi's maximum (1000) is lowered to 1000" || bad "5000: $(t 5000)"
[ "$(t '"soon"')" = 30/60 ] && [ "$(t 'null')" = 30/60 ] && [ "$(t '-5')" = 30/60 ] && ok "not a number counts as 60" || bad "garbage"
q "delete from public.platform_settings where key = 'voice_silence_timeout_seconds'" > /dev/null
[ "$(hv "$BE" '$[1].options.timeoutSeconds')" = 60 ] && ok "no setting: 60" || bad "missing setting"
setting voice_silence_timeout_seconds 60

# Vapi's own types
if [ -n "$SDK" ]; then
  grep -q "silenceTimeoutSeconds" "$SDK/CreateAssistantDto.d.ts" && bad "CreateAssistantDto has silenceTimeoutSeconds now: revisit the design" \
    || ok "the SDK's CreateAssistantDto has no silenceTimeoutSeconds (only TransferAssistant does), so hooks are the way"
  grep -q "hooks?: Vapi.CreateAssistantDtoHooksItem\[\]" "$SDK/CreateAssistantDto.d.ts" && grep -q "Vapi.CallHookCustomerSpeechTimeout" "$SDK/CreateAssistantDtoHooksItem.d.ts" \
    && grep -q '"customer.speech.timeout"' "$SDK/CallHookCustomerSpeechTimeout.d.ts" && grep -q "@maximum 1000" "$SDK/CustomerSpeechTimeoutOptions.d.ts" \
    && grep -q '"onUserSpeech"' "$SDK/CustomerSpeechTimeoutOptionsTriggerResetMode.d.ts" && grep -q 'type: "endCall"' "$SDK/ToolCallHookActionTool.d.ts" \
    && grep -q "blocking?: boolean" "$SDK/ToolMessageStart.d.ts" && grep -q "contents?: Vapi.TextContent\[\]" "$SDK/ToolMessageStart.d.ts" \
    && ok "every field used is in @vapi-ai/server-sdk 3.0.0 (hooks, customer.speech.timeout, timeoutSeconds max 1000, onUserSpeech, endCall, blocking, contents)" || bad "SDK fields"
else skip "SDK files not in the Deno cache"; fi
if [ -n "$DENO" ]; then
  for b in "$BE" "$BS" "$BB"; do
    printf 'import type { Vapi } from "npm:@vapi-ai/server-sdk@3.0.0";\nexport const assistant: Vapi.CreateAssistantDto = %s;\n' \
      "$(q "select jsonb_set(public.zella_assistant_config('$b') -> 'assistant', '{model,model}', to_jsonb((regexp_match(pg_get_functiondef($SIG), 'v_vapi_models text\[\] := array\[''([^'']+)'''))[1]))")" > "$WORK/assistant_$b.ts"
  done
  # (the model id is not set in this copy: the first entry of the function's own Vapi list stands in for it)
  # the same check refuses a wrong shape (proves it checks the hooks)
  printf 'import type { Vapi } from "npm:@vapi-ai/server-sdk@3.0.0";\nexport const h: Vapi.CreateAssistantDto = { hooks: [{ on: "customer.speech.timeout", do: [{ type: "say", exact: "x" }], options: { timeoutSeconds: 60, triggerResetMode: "sometimes" } }] };\n' > "$WORK/wrong.ts"
  if out=$(cd "$WORK" && "$DENO" check assistant_*.ts 2>&1); then
    ok "the English, Spanish and two language configs type-check as Vapi's CreateAssistantDto"
    out=$(cd "$WORK" && "$DENO" check wrong.ts 2>&1) && bad "the type check accepted a wrong hook" || ok "and the same check refuses a hook with a wrong option"
  elif echo "$out" | grep -q "TS[0-9]"; then bad "config does not match Vapi's types: $(echo "$out" | grep -m1 -A3 TS)"
  else skip "Vapi type check (package not reachable): $out"; fi
else skip "deno not installed"; fi

# permissions: server only
r=$(q "do \$\$ begin set local role authenticated; perform public.zella_silence_hooks('$BE'); exception when others then raise notice 'R=%', sqlerrm; end \$\$" 2>&1 | sed -n 's/.*R=//p')
[[ "$r" == *permission* ]] && ok "signed in people can't call zella_silence_hooks" || bad "authenticated: $r"

# rollback: drift first, then exact, twice
q "create table public.zsil_keep as select pg_get_functiondef($SIG) d" > /dev/null
q "do \$\$ begin execute replace((select d from public.zsil_keep), 'temperature'', 0.3', 'temperature'', 0.4'); end \$\$" > /dev/null
D=$(fp); out=$(apply "$RB"); [[ "$out" == *ROLLBACK_DRIFT*zella_assistant_config* ]] && [ "$(fp)" = "$D" ] && ok "the rollback refuses a changed function and changes nothing" || bad "rb drift: $out"
q "do \$\$ begin execute (select d from public.zsil_keep); end \$\$; drop table public.zsil_keep" > /dev/null
[ "$(fp)" = "$AFTER" ] && ok "this file's version is back for the real rollback" || bad "repair"
out=$(apply "$RB") && [ "$(fp)" = "$BEFORE" ] && [ "$(md5f)" = "$PROD" ] && ok "the rollback is exact (function md5 $PROD, setting, new functions, archive)" || bad "rollback: $out"
[ "$(snapshot)" = "$CFG_BEFORE" ] && [ "$(q "select count(*) from public.businesses b where b.id in ('$BE','$BS','$BB','$BN') and public.zella_assistant_config(b.id) -> 'assistant' ? 'hooks'")" = 0 ] && ok "and the config is as before" || bad "config after rb: $(snapshot) vs $CFG_BEFORE"
out=$(apply "$RB") && [ "$(fp)" = "$BEFORE" ] && ok "the rollback runs twice safely" || bad "rollback twice: $out"
out=$(apply "$MIG") && [ "$(fp)" = "$AFTER" ] && ok "applies again after the rollback" || bad "reapply: $out"
# a value the owner set before the file stays after the rollback
out=$(apply "$RB"); setting voice_silence_timeout_seconds 120; out=$(apply "$MIG")
[ "$(q "select count(*) from public.zella_migration_settings where migration = 'zella_silence_timeout'")" = 0 ] && [ "$(hv "$BE" '$[1].options.timeoutSeconds')" = 120 ] && out=$(apply "$RB") \
  && [ "$(q "select value from public.platform_settings where key = 'voice_silence_timeout_seconds'")" = 120 ] && ok "a timeout set before the file is used and kept by the rollback" || bad "preexisting setting: $out"

# ---------------------------------------------------------------- both orders with sql/zella_admin_languages.sql
if [ -z "$LANGS" ]; then skip "sql/zella_admin_languages.sql is neither in this tree nor on origin/claude/admin-only-languages"; finish; fi
LANGS_ALT="$WORK/langs_on_silence.sql"   # the admin languages file, also accepting this file's version as its base
sed "s/'prod', '$PROD', 'mine', '$LANG_BASE'/'prod', '$MINE_PROD', 'mine', '$MINE_LANG'/" "$LANGS" > "$LANGS_ALT"

# languages first, then this file
fresh_db langs_first; setup_businesses
out=$(apply "$LANGS") && [ "$(md5f)" = "$LANG_BASE" ] && ok "languages first: zella_admin_languages applies ($LANG_BASE)" || bad "langs: $out"
LB=$(fp); LCFG=$(snapshot)
out=$(apply "$MIG") && [ "$(md5f)" = "$MINE_LANG" ] && ok "then this file applies on that version ($MINE_LANG)" || bad "mine on langs: $out $(md5f)"
LA=$(fp); out=$(apply "$MIG") && [ "$(fp)" = "$LA" ] && ok "and again, changing nothing" || bad "twice on langs"
[ "$(snapshot)" = "$LCFG" ] && [ "$(hv "$BE" '$[1].options.timeoutSeconds')|$(hv "$BS" '$[1].do[0].tool.messages[0].content')" = "60|Parece que se cortó la llamada. Gracias por llamar a Clínica Dental Sonrisa, adiós." ] \
  && ok "the hooks are added and nothing else changes on the languages version" || bad "langs config"
q "select pg_get_functiondef($SIG)" > "$WORK/order1.sql"
D=$(fp); out=$(apply "$LANGS"); [[ "$out" == *VERSION_MISMATCH* ]] && [ "$(fp)" = "$D" ] && ok "zella_admin_languages run again afterwards stops safely (it doesn't know this file's version) and changes nothing" || bad "langs rerun: $out"
out=$(apply "$RB") && [ "$(fp)" = "$LB" ] && [ "$(md5f)" = "$LANG_BASE" ] && [ "$(snapshot)" = "$LCFG" ] && ok "the rollback gives back exactly the languages version" || bad "rb on langs: $out $(md5f)"
out=$(apply "$RB") && [ "$(fp)" = "$LB" ] && ok "and runs twice safely" || bad "rb twice on langs"

# this file first, then languages
fresh_db silence_first; setup_businesses
out=$(apply "$MIG") && [ "$(md5f)" = "$MINE_PROD" ] || bad "mine first: $out"
D=$(fp); out=$(apply "$LANGS")
if [ $? -eq 0 ] && [ "$(md5f)" = "$MINE_LANG" ]; then ok "this file first: zella_admin_languages applies after it"
elif [[ "$out" == *VERSION_MISMATCH* ]] && [ "$(fp)" = "$D" ]; then
  ok "this file first: zella_admin_languages as it is today stops safely (VERSION_MISMATCH, nothing changes); its plan must also accept $MINE_PROD"
  out=$(apply "$LANGS_ALT") && [ "$(md5f)" = "$MINE_LANG" ] && ok "with $MINE_PROD added as a base it applies and gives the same function as the other order ($MINE_LANG)" || bad "langs alt: $out $(md5f)"
else bad "langs after mine: $out"; fi
q "select pg_get_functiondef($SIG)" > "$WORK/order2.sql"
cmp -s "$WORK/order1.sql" "$WORK/order2.sql" && ok "both orders give the same zella_assistant_config, byte for byte" || bad "orders differ"
out=$(apply "$RB") && [ "$(md5f)" = "$LANG_BASE" ] && [ "$(q "select count(*) from pg_proc where proname = 'zella_silence_hooks'")" = 0 ] && ok "the rollback then gives back the languages version (only this file's line goes)" || bad "rb after langs: $out $(md5f)"
out=$(apply "$MIG") && [ "$(md5f)" = "$MINE_LANG" ] && ok "and this file applies again" || bad "reapply after langs: $out"
finish
