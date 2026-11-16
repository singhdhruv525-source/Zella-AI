-- Production's zella_sensitive_industry(uuid) (md5 ad2e363ec6fa112404cc2710cc7132e4, read 16 Nov 2026 by the
-- supervisor). Loaded before the industry data migration so the test's "before" state is production's, not the template's.
CREATE OR REPLACE FUNCTION public.zella_sensitive_industry(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select i.slug in ('dental', 'healthcare', 'pet-care-veterinary', 'legal', 'financial-services', 'insurance', 'childcare')
                     from public.businesses b join public.industries i on i.id = b.industry_id where b.id = p_business_id
                      and (auth.uid() is null or public.zella_is_member(p_business_id) or public.is_platform_admin())), false);
$function$;
