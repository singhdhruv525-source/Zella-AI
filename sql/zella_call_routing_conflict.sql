-- Zella Voice: an inbound call whose called number and Vapi phone ID belong to two different businesses is refused and
-- alerted, never routed (owner's decision, 27 Nov 2026: "refuse and alert"; docs/ARCHITECTURE.md §6.6 REQ-COM-ISO-01,
-- §6.7, D-52; docs/MEMORY.md open problem "Inbound call routing").
--
-- WHY: zella_business_for_number (sql/zella_phone_numbers.sql; production's body is the 4 Nov 2026 baseline,
-- sql/baseline/05_functions_1.sql, md5 of prosrc eaa05f56f3d943768066e5b48ab780f3 as tests/voice-reliability/
-- prod_md5.txt recorded from production) finds the business for a call from both values. business_phone_numbers.e164
-- and .vapi_phone_number_id are each unique, but nothing stops the number of one row and the ID of another row being
-- sent together. Today the query matches both rows and the ORDER BY picks the Vapi phone ID's business: a call can be
-- answered with another business's receptionist, its knowledge, its caller records and its bookings (TEN-11, TEN-12,
-- NN-1). CodeRabbit raised it on PR #57.
--
-- WHAT: zella_business_for_number keeps its exact signature, owner, grants and return type. One new step comes first:
--   the row the called number names and the row the Vapi phone ID names are read, whatever their status (a paused
--   number, or a stopped business, still names its business). When both exist and belong to different businesses,
--   the function returns null: neither business, and the call settings' business id (p_fallback) is not used either.
--   Every caller already treats null as "no business" (traced in docs/ARCHITECTURE.md §6.7, "Call routing"):
--     voice-rules assistant-request  zella_assistant_for_call: 'unknown_number', no business configuration is read;
--                                    Vapi says the neutral line ("Sorry, we can't take your call right now. Please call
--                                    again a little later.") or the platform's standby assistant, if one is set
--     voice-rules tool-calls, the n8n Brain Tools, Voice Rules, Assistant Tools and Appointment Booking workflows
--                                    p_business_id null: zella_ai_voice raises UNKNOWN_BUSINESS, zella_ai_tool answers
--                                    unknown_business, zella_report_unanswered raises UNKNOWN_BUSINESS,
--                                    zella_store_lookup_begin refuses; nothing is read or written for a business
--     status-update                  zella_record_call_status: 'unknown_business', no call row
--     transfer-destination-request   zella_transfer_destination: refused, reason unknown_business
--     end-of-call-report             zella_record_inbound_call: 'unknown_business', no call row, no caller, lead,
--                                    callback or message
--   A call row is created only by those three functions, each only with a business, so no later step of the same call
--   can find a business through the call either.
--   It raises one urgent platform alert (zella_platform_alert, the existing Zella Voice admin alert: the admin bell,
--   and the admin alert email once email is live), kind call_routing_conflict, with no business on the alert itself
--   (it belongs to neither); meta names both phone number rows and both businesses and the last 4 digits of the called
--   number (never the full number, PRV-7). Repeats for the same two rows add to its occurrences (dedupe key), so a call
--   that asks several times makes one alert. Urgent: calls for two businesses are not being answered (INC-2), and a
--   rule can't switch an urgent alert off (sql/zella_alert_rules.sql). If the alert can't be written (for example in a
--   read only transaction) the call is refused all the same, with a warning carrying the SQLSTATE only.
--   Everything else is byte for byte production's logic: the number alone, the ID alone, a matching pair, a paused or
--   stopped number, and the call settings fallback behave exactly as before.
--   The function becomes VOLATILE (it was STABLE) because it can write the alert; every caller is PL/pgSQL or an RPC.
--
-- VERSION GUARD (DB-3): the live function must be production's version, md5(pg_get_functiondef) =
-- 051170698159c7b440ebb7ca62a3a0eb (the 4 Nov 2026 baseline; its body is production's recorded checksum above; no
-- later file changes it), or exactly this file's (already applied, 5f066cb575f536698873724a6e4b65ef). zella_platform_alert(text,
-- text,text,text,uuid,text,jsonb) and business_phone_numbers (e164, vapi_phone_number_id, business_id) must exist.
-- Otherwise VERSION_MISMATCH and nothing changes. Before applying: confirm production's md5 read only (DB-14,
-- docs/MEMORY.md "Production can be newer than the isolated copy").
-- SAFE TO RUN TWICE (DB-2): a second run replaces the function with the same body.
-- WHO CAN DO WHAT AFTER: unchanged. Server code only (service_role); public, anon and authenticated can't execute it.
-- VERIFY: select md5(pg_get_functiondef('public.zella_business_for_number(text,text,uuid)'::regprocedure));
--           -- 5f066cb575f536698873724a6e4b65ef
-- TESTS: tests/call_routing_conflict/run.sh (isolated local test database only).
-- ROLLBACK (DB-4, NN-10): sql/rollback/zella_call_routing_conflict_rollback.sql restores production's function
-- exactly and keeps every alert raised (a rollback never deletes data).
-- DEPLOY: database only. No edge function, n8n workflow or Vapi change is needed: every path already treats "no
-- business" as unknown. Applying it is a production change on the live call path and needs the owner's approval
-- (NN-4).
-- Rules: NN-1, NN-4, NN-10, NN-11, TEN-3, TEN-4, TEN-11, TEN-12, SEC-5, SEC-9, PRV-7, OBS-2, INC-2, DB-1, DB-2, DB-3,
-- DB-4, DB-7, DB-14, QA-1.
begin;

do $$
declare s constant text := 'public.zella_business_for_number(text,text,uuid)'; h text;
begin
  if to_regprocedure(s) is null then raise exception 'VERSION_MISMATCH: % is missing', s; end if;
  h := md5(pg_get_functiondef(s::regprocedure));
  if h not in ('051170698159c7b440ebb7ca62a3a0eb', '5f066cb575f536698873724a6e4b65ef') then
    raise exception 'VERSION_MISMATCH: % is not the version this file was written for (%)', s, h;
  end if;
  if to_regprocedure('public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: zella_platform_alert is missing';
  end if;
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'business_phone_numbers'
        and column_name in ('id', 'business_id', 'e164', 'vapi_phone_number_id')) <> 4 then
    raise exception 'VERSION_MISMATCH: business_phone_numbers is not the shape this file was written for';
  end if;
end $$;

create or replace function public.zella_business_for_number(p_called_number text, p_vapi_phone_number_id text default null, p_fallback uuid default null)
returns uuid language plpgsql volatile security definer set search_path = public as $function$
declare v_biz uuid; v_e text := public.zella_normalize_e164(p_called_number);
  v_by_number public.business_phone_numbers; v_by_id public.business_phone_numbers;
begin
  -- zella_call_routing_conflict: the number and the Vapi phone ID name rows of two different businesses (whatever
  -- their status). Neither business is used, nor the call settings' business: the call is a call for an unknown
  -- number, and Zella Voice admins get one urgent alert per pair of rows.
  if v_e is not null and nullif(p_vapi_phone_number_id, '') is not null then
    select * into v_by_number from public.business_phone_numbers n where n.e164 = v_e;
    select * into v_by_id from public.business_phone_numbers n where n.vapi_phone_number_id = p_vapi_phone_number_id;
    if v_by_number.business_id is not null and v_by_id.business_id is not null and v_by_number.business_id <> v_by_id.business_id then
      begin
        perform public.zella_platform_alert('call_routing_conflict', 'A call matched two businesses and was not answered for either',
          'An inbound call arrived on a number registered to one business with a Vapi phone ID registered to another. The call '
          || 'was treated as a call for an unknown number. Correct the two phone number records in Voice numbers.',
          'urgent', null,
          'call_routing_conflict:' || least(v_by_number.id::text, v_by_id.id::text) || ':' || greatest(v_by_number.id::text, v_by_id.id::text),
          jsonb_build_object('number_row_id', v_by_number.id, 'number_business_id', v_by_number.business_id,
                             'vapi_row_id', v_by_id.id, 'vapi_business_id', v_by_id.business_id, 'number_ending', right(v_e, 4)));
      exception when others then
        raise warning 'zella_business_for_number: routing conflict alert not raised (%)', sqlstate;
      end;
      return null;
    end if;
  end if;
  select n.business_id into v_biz from public.business_phone_numbers n join public.businesses b on b.id = n.business_id
   where n.status = 'active' and b.suspended_at is null and b.cancelled_at is null
     and ((nullif(p_vapi_phone_number_id, '') is not null and n.vapi_phone_number_id = p_vapi_phone_number_id) or (v_e is not null and n.e164 = v_e))
   order by (n.vapi_phone_number_id = p_vapi_phone_number_id) desc nulls last limit 1;
  if v_biz is not null then return v_biz; end if;
  if exists (select 1 from public.business_phone_numbers n where (v_e is not null and n.e164 = v_e) or (nullif(p_vapi_phone_number_id, '') is not null and n.vapi_phone_number_id = p_vapi_phone_number_id)) then return null; end if;
  if p_fallback is not null and exists (select 1 from public.businesses b where b.id = p_fallback and b.suspended_at is null and b.cancelled_at is null) then return p_fallback; end if;
  return null;
end $function$;

revoke execute on function public.zella_business_for_number(text, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_business_for_number(text, text, uuid) to service_role;

commit;
