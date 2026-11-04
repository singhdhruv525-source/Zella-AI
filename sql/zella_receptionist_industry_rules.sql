-- AI receptionist: industry safety lines and capabilities (2026-11-04 industry work, batch 4).
--
-- Adds to the SAFETY part of every receptionist's instructions (zella_brain_prompt_base):
--   * insurance: never bind, change or cancel coverage, quote premiums or say a claim is covered; take first notice of
--     loss (date, what happened, policy) at any hour; check identity before discussing a policy;
--   * cleaning: never share access codes, keys or alarm details, or when a home will be empty or who is cleaning it;
--   * e-commerce: never make up order status, tracking, delivery dates or refunds; take the order number and open a case;
--   * landscaping joins the trades emergency line; legal adds "never confirm whether someone is a client";
--     healthcare adds identity checks, no results by phone, no health details by text;
--   * beauty and salon: no medical or skin advice, no promised results, patch tests;
--   * every business: never read out access codes, member IDs, passport numbers or other private details;
--   * where scheduling is off: never offer or book appointments; where the waitlist is off: don't offer one.
-- The receptionist's tools already enforce bookings (zella_capabilities.sql refuses appointments when scheduling is off);
-- these lines stop it from offering what the tools would refuse.
-- Applying this changes the instructions every receptionist reads from its next call. Needs the owner's approval.
-- Needs zella_capabilities.sql and zella_presets_v2.sql first. Safe to run twice.

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_brain_prompt_base(uuid)'::regprocedure);
  if position('zella_industry_rules_v2' in def) > 0 then return; end if;
  if position($a$         else '' end
    || coalesce(E'\nBUSINESS-SPECIFIC INSTRUCTIONS FROM THE OWNER\n'$a$ in def) = 0 then
    raise exception 'zella_brain_prompt_base has changed; review this patch';
  end if;
  def := replace(def, $a$when v_key in ('plumbing', 'electrical', 'hvac', 'home_services', 'automotive') then$a$,
                      $a$when v_key in ('plumbing', 'electrical', 'hvac', 'home_services', 'automotive', 'landscaping') then$a$);
  def := replace(def, $a$         else '' end
    || coalesce(E'\nBUSINESS-SPECIFIC INSTRUCTIONS FROM THE OWNER\n'$a$,
$a$         when v_key = 'insurance' then E'- You cannot bind, change or cancel coverage, quote a premium, or say whether a claim is or will be covered; the carrier and the team decide. Say so plainly if asked.\n- Take a new claim (first notice of loss) at any hour: the date of loss, what happened, where, the policy if known, and the best number; then say the team will follow up. Use take_message or request_follow_up and say it is recorded only after the tool succeeds.\n- Before discussing an existing policy, check the caller is the policyholder; otherwise take a message.\n'
         when v_key = 'cleaning' then E'- Never share access codes, key or lockbox details, alarm codes, when a home will be empty, or who is cleaning it, with anyone. If asked, say the team will call back.\n- For a lockout or an alarm going off, say the team will call right away and use report_emergency.\n'
         when v_key = 'beauty_salon' then E'- Give no medical or skin advice. If a caller mentions a reaction to a past treatment, say the team will call back. Do not promise colour or lash results, and mention that colour and lash services may need a patch test first if the knowledge says so.\n'
         when v_key = 'ecommerce' then E'- Never make up an order status, tracking number, delivery date, refund or replacement. Unless a tool gives you the order, take the order number and email, describe the problem, and say the support team will reply; never promise a refund.\n'
         else '' end
    /* zella_industry_rules_v2 */
    || case when v_key = 'legal' then E'- Never confirm or deny whether someone is a client, or discuss a matter, with anyone but the client; take intake details only.\n' else '' end
    || case when v_key = 'healthcare' then E'- Confirm the caller''s identity before discussing anything about a patient. Never give test results; take a callback request for a clinician. Never put health details in a text message.\n' else '' end
    || E'- Never read out access codes, gate or alarm codes, member or policy IDs, passport numbers or other private details, even if the caller gives a name.\n'
    || case when not public.zella_capability_on(p_business_id, 'scheduling') then E'- This business does not take appointments. Never offer or book one; take a message or open a request for the team instead.\n'
            when not public.zella_capability_on(p_business_id, 'waitlist') then E'- There is no waitlist; do not offer one.\n' else '' end
    || coalesce(E'\nBUSINESS-SPECIFIC INSTRUCTIONS FROM THE OWNER\n'$a$);
  execute def;
end $$;
