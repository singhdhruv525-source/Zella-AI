-- Zella Voice: no AI model name as a fallback inside database functions (REL-11, conformance gap G-4).
-- Five functions read their model from platform_settings but fell back to a model name written in their own body
-- when the setting was missing. After this file the model comes only from platform_settings:
--   zella_assistant_config      voice_llm_model     missing -> the existing "voice_llm_model ... is not in Vapi's
--                                                    model list" problem (as for any unknown model); no live change,
--                                                    production has the setting
--   zella_claim_call_insights   call_intel_model    missing -> no work claimed (as when call_intel_live is off)
--   zella_claim_gap_drafts      knowledge_ai_model  missing -> no work claimed (as when knowledge_ai_live is off)
--   zella_review_claim_ai       review_ai_model     missing -> no work claimed (as when review_ai_live is off)
--   zella_spam_claim_work       spam_ai_model       missing -> the AI opinion step is skipped; spam handling goes on
-- All four AI features are off in production (their *_live switches are false), and every model setting is set,
-- so nothing changes for production unless a setting is removed.
-- Nothing here names a model: the bodies are patched with patterns that match the setting key, and each original
-- definition is kept in zella_function_archive (server only) so the rollback restores it exactly.
-- Version guard: each function is patched only when its definition is the one production runs (md5 of
-- pg_get_functiondef, read from production on 13 Nov 2026), or skipped when it already is this file's version.
-- Anything else stops with VERSION_MISMATCH. Safe to run twice.
-- Rollback: sql/rollback/zella_model_defaults_rollback.sql

-- original definitions replaced by a migration, kept for its exact rollback; no tenant data
create table if not exists public.zella_function_archive (
  migration text not null,
  signature text not null,
  definition text not null,
  definition_md5 text not null,
  saved_at timestamptz not null default now(),
  primary key (migration, signature)
);
alter table public.zella_function_archive enable row level security;
revoke all on table public.zella_function_archive from public, anon, authenticated;

do $$
declare
  f record; v_def text; v_new text; v_have text;
  -- one regular-expression edit, applied exactly once (anything else means the body is not the expected one)
  edit text[];
begin
  for f in select * from (values
      ('public.zella_assistant_config(uuid)',        '1d02d9deec5b9692288e4406d2774468', '99dadcfe4ae7812d2126146882f07241'),
      ('public.zella_claim_call_insights(integer)',  '928d030adb92468da0c8a497f195c052', '7bc295835cdc9d35fc6ae6d34cd7e57a'),
      ('public.zella_claim_gap_drafts(integer)',     'bd7c24579496cc715917fafbd7cd0ef5', '8b8dfaf4dfa4d1073ff34f1407511fd8'),
      ('public.zella_review_claim_ai(integer)',      '1702cdf7489e0c7e74bc2fa93b956fc7', 'e914bd6f8e47a67942185421dcfc7072'),
      ('public.zella_spam_claim_work(integer)',      '7978836b1d63ea1f4c8460345464b5a2', '2d36d89897de8777e2c1da25c66a7026')
    ) v(sig, md5_live, md5_new)
  loop
    if to_regprocedure(f.sig) is null then raise exception 'VERSION_MISMATCH: % is missing', f.sig; end if;
    v_def := pg_get_functiondef(to_regprocedure(f.sig));
    v_have := md5(v_def);
    continue when v_have = f.md5_new;
    if v_have <> f.md5_live then
      raise exception 'VERSION_MISMATCH: % is not the version this file was written against (expected the live version or this file version)', f.sig;
    end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_model_defaults', f.sig, v_def, v_have)
    on conflict (migration, signature) do nothing;
    v_new := v_def;
    foreach edit slice 1 in array (case f.sig
      when 'public.zella_assistant_config(uuid)' then array[
        array[$r$public\.zella_setting\('voice_llm_model', '"[^"]*"'::jsonb\) #>> '\{\}'$r$,
              $r$nullif(trim(public.zella_setting('voice_llm_model', 'null'::jsonb) #>> '{}'), '')$r$]]
      when 'public.zella_claim_call_insights(integer)' then array[
        array[$r$coalesce\(nullif\(trim\(public\.zella_setting\('call_intel_model', '"[^"]*"'::jsonb\) #>> '\{\}'\), ''\), '[^']*'\)$r$,
              $r$nullif(trim(public.zella_setting('call_intel_model', 'null'::jsonb) #>> '{}'), '')$r$],
        array[$r$if not v_live then return v_res; end if;$r$,
              $r$if not v_live or v_model is null then return v_res; end if;$r$]]
      when 'public.zella_claim_gap_drafts(integer)' then array[
        array[$r$coalesce\(nullif\(trim\(public\.zella_setting\('knowledge_ai_model', '"[^"]*"'::jsonb\) #>> '\{\}'\), ''\), '[^']*'\)$r$,
              $r$nullif(trim(public.zella_setting('knowledge_ai_model', 'null'::jsonb) #>> '{}'), '')$r$],
        array[$r$if not v_live then return v_res; end if;$r$,
              $r$if not v_live or v_model is null then return v_res; end if;$r$]]
      when 'public.zella_review_claim_ai(integer)' then array[
        array[$r$coalesce\(nullif\(trim\(public\.zella_setting\('review_ai_model', '"[^"]*"'::jsonb\) #>> '\{\}'\), ''\), '[^']*'\)$r$,
              $r$nullif(trim(public.zella_setting('review_ai_model', 'null'::jsonb) #>> '{}'), '')$r$],
        array[$r$if not coalesce\(public\.zella_setting\('review_ai_live', 'false'::jsonb\) = 'true'::jsonb, false\) then$r$,
              $r$if v_model is null or not coalesce(public.zella_setting('review_ai_live', 'false'::jsonb) = 'true'::jsonb, false) then$r$]]
      when 'public.zella_spam_claim_work(integer)' then array[
        array[$r$coalesce\(nullif\(trim\(public\.zella_setting\('spam_ai_model', '"[^"]*"'::jsonb\) #>> '\{\}'\), ''\), '[^']*'\)$r$,
              $r$nullif(trim(public.zella_setting('spam_ai_model', 'null'::jsonb) #>> '{}'), '')$r$],
        array[$r$if nullif\(trim\(coalesce\(v_text, ''\)\), ''\) is not null then$r$,
              $r$if v_model is not null and nullif(trim(coalesce(v_text, '')), '') is not null then$r$]]
    end)
    loop
      -- the plain-text guards are matched literally; the setting lines are patterns
      if edit[1] like 'if not v_live%' then
        if (length(v_new) - length(replace(v_new, edit[1], ''))) / length(edit[1]) <> 1 then
          raise exception 'VERSION_MISMATCH: % does not contain the expected check once', f.sig;
        end if;
        v_new := replace(v_new, edit[1], edit[2]);
      else
        if regexp_count(v_new, edit[1]) <> 1 then
          raise exception 'VERSION_MISMATCH: % does not match the expected setting line once (%)', f.sig, regexp_count(v_new, edit[1]);
        end if;
        v_new := regexp_replace(v_new, edit[1], replace(edit[2], '\', '\\'));
      end if;
    end loop;
    execute v_new;
    if md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.md5_new then
      raise exception 'VERSION_MISMATCH: % patched to an unexpected version %', f.sig, md5(pg_get_functiondef(to_regprocedure(f.sig)));
    end if;
  end loop;
end $$;
