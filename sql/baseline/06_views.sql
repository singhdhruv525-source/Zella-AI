create or replace view public.calls_view with (security_invoker=true) as  SELECT id,
    business_id,
    customer_id,
    conversation_id,
    direction,
    status,
    from_number,
    to_number,
    started_at,
    answered_at,
    ended_at,
    duration_seconds,
    ai_handled,
    external_call_id,
    metadata,
    created_at,
    updated_at,
    needs_human,
    escalation_reason,
    escalated_at,
    escalation_resolved_at,
    escalation_resolved_by,
    summary,
    transfer_status,
    failure_reason,
    failure_context,
    assigned_to,
    outcome,
    outcome_note,
    outcome_at,
    escalation_acknowledged_at,
    escalation_acknowledged_by,
    escalation_reminded_at,
        CASE
            WHEN zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]) THEN recording_url
            ELSE NULL::text
        END AS recording_url,
        CASE
            WHEN zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]) THEN transcript
            ELSE NULL::text
        END AS transcript
   FROM calls c;
