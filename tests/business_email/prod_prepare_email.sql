-- Test only: brings the 4 Nov baseline's zella_prepare_email to production's version (169dc4af..., 18 Nov 2026), which is
-- the baseline plus sql/zella_usage_enforcement.sql's one patch. That file needs the billing migrations, so its patch is
-- repeated here word for word, with a stand in message gate (allow everything) when the real one isn't there.
do $$
begin
  if to_regprocedure('public.zella_message_gate(uuid,text,text)') is null then
    execute $f$create function public.zella_message_gate(p_business_id uuid, p_channel text, p_kind text) returns jsonb
      language sql stable as $gate$ select '{"allow": true}'::jsonb $gate$ $f$;
  end if;
end $$;
select public.zella_patch_function('public.zella_prepare_email(uuid,uuid,text,jsonb,text)', '/* zella_usage_enforcement */',
         '    return jsonb_build_object(''allowed'', false, ''reason'', ''business_not_available'', ''live'', v_live);
  end if;',
         '    return jsonb_build_object(''allowed'', false, ''reason'', ''business_not_available'', ''live'', v_live);
  end if;
  if not (public.zella_message_gate(p_business_id, ''email'', p_template_key) ->> ''allow'')::boolean then   /* zella_usage_enforcement */
    return jsonb_build_object(''allowed'', false, ''reason'', ''allowance_used'', ''live'', v_live);
  end if;');
