# The multilingual assistant (English + Spanish + Hindi, then French) against Vapi's own types.
for L in "en-US|{es,hi}" "fr|{}"; do
  q $DB "select set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', false);
    select zella_business_language_save('aaaaaaaa-0000-4000-8000-000000000001', '${L%%|*}', '${L##*|}', null);" > /dev/null
  printf 'import type { Vapi } from "npm:@vapi-ai/server-sdk@3.0.0";\nexport const assistant: Vapi.CreateAssistantDto = %s;\n' \
    "$(q $DB "select zella_assistant_config('aaaaaaaa-0000-4000-8000-000000000001') -> 'assistant'")" > "$WORK/assistant_${L%%|*}.ts"
done
if out=$(cd "$WORK" && "$DENO" check assistant_*.ts 2>&1); then pass "multilingual assistants (English+Spanish+Hindi, French) type-check as Vapi CreateAssistantDto"
elif echo "$out" | grep -q "TS[0-9]"; then fail "multilingual assistant does not match Vapi's types: $(echo "$out" | grep -m1 -A3 TS)"
else echo "skip  Vapi type check (npm registry not reachable)"; fi
