create policy brand_assets_delete on storage.objects as PERMISSIVE for DELETE to authenticated using (((bucket_id = 'brand-assets'::text) AND zella_can_write_brand_asset(name)));
create policy brand_assets_insert on storage.objects as PERMISSIVE for INSERT to authenticated with check (((bucket_id = 'brand-assets'::text) AND zella_can_write_brand_asset(name)));
create policy brand_assets_select on storage.objects as PERMISSIVE for SELECT to authenticated using (((bucket_id = 'brand-assets'::text) AND zella_can_write_brand_asset(name)));
create policy brand_assets_update on storage.objects as PERMISSIVE for UPDATE to authenticated using (((bucket_id = 'brand-assets'::text) AND zella_can_write_brand_asset(name)));
