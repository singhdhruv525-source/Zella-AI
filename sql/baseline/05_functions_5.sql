CREATE OR REPLACE FUNCTION public.zella_call_content(p_call_id uuid)
RETURNS TABLE(recording_url text, transcript text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE mfa_ok boolean;
BEGIN
  -- The live MFA migration may be present even when restoring an older baseline.
  IF auth.role() IS DISTINCT FROM 'service_role'
     AND to_regprocedure('public.zella_mfa_satisfied()') IS NOT NULL THEN
    EXECUTE 'SELECT public.zella_mfa_satisfied()' INTO mfa_ok;
    IF mfa_ok IS NOT TRUE THEN RETURN; END IF;
  END IF;
  RETURN QUERY SELECT c.recording_url, c.transcript FROM public.calls c
  WHERE c.id = p_call_id
    AND (auth.role() = 'service_role' OR (public.is_business_member(c.business_id)
    AND public.zella_module_on(c.business_id, 'calls')
    AND public.zella_has_role(c.business_id, ARRAY['owner', 'admin', 'manager'])));
END;
$function$;
