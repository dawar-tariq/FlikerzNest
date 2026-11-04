-- Flickerz Nest TV pairing upgrade: mobile generates; TV redeems.
-- Run once in Supabase SQL Editor. Safe to re-run.
begin;

alter table public.tv_codes add column if not exists refresh_token text;
alter table public.tv_codes alter column secret_hash drop not null;
alter table public.tv_codes alter column expires_at set default (now() + interval '3 minutes');

create or replace function public.tv_code_create(p_code text, p_refresh_token text)
returns table (code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in on your phone first.' using errcode = '42501';
  end if;
  if p_code is null or p_code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'
     or p_refresh_token is null or pg_catalog.length(p_refresh_token) < 20 then
    raise exception 'Invalid TV code request.' using errcode = '22023';
  end if;

  delete from public.tv_codes where expires_at <= pg_catalog.now();
  insert into public.tv_codes (code, secret_hash, grant_token, refresh_token, expires_at)
  values (p_code, null, null, p_refresh_token, pg_catalog.now() + interval '3 minutes');

  return query select p_code, pg_catalog.now() + interval '3 minutes';
end;
$$;

create or replace function public.tv_code_claim(p_code text)
returns table (refresh_token text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_code is null or p_code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' then
    return;
  end if;

  -- Atomic DELETE ... RETURNING guarantees a code can be redeemed only once.
  return query
    delete from public.tv_codes t
     where t.code = p_code
       and t.expires_at > pg_catalog.now()
       and t.refresh_token is not null
    returning t.refresh_token;
end;
$$;

revoke all on function public.tv_code_create(text, text) from public, anon;
grant execute on function public.tv_code_create(text, text) to authenticated;
revoke all on function public.tv_code_claim(text) from public;
grant execute on function public.tv_code_claim(text) to anon, authenticated;

-- Retire the old TV-generated/phone-approved endpoints.
revoke all on function public.tv_code_create() from public, anon, authenticated;
revoke all on function public.tv_code_approve(text, text) from public, anon, authenticated;
revoke all on function public.tv_code_poll(text, text) from public, anon, authenticated;

commit;
