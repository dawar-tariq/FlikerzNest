-- Flickerz Nest: mobile-generated TV pairing compatibility upgrade
-- Run this AFTER the original STEP 15 SQL already applied in Supabase.
-- The frontend calls tv_code_create(p_code, p_refresh_token) and
-- tv_code_claim(p_code). This migration adds those exact RPC signatures.

begin;

alter table public.tv_codes
  add column if not exists refresh_token text;

create or replace function public.tv_code_create(
  p_code text,
  p_refresh_token text
)
returns table (code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expiry timestamptz := pg_catalog.now() + interval '3 minutes';
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in on your phone first.' using errcode = '42501';
  end if;

  if p_code is null
     or p_code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'
     or p_refresh_token is null
     or pg_catalog.length(p_refresh_token) < 20 then
    raise exception 'Invalid TV code request.' using errcode = '22023';
  end if;

  delete from public.tv_codes where expires_at <= pg_catalog.now();

  -- Store only the refresh token required for this one-time TV sign-in.
  -- Keep the legacy secret/user_id/grant_token/claimed_at columns untouched.
  insert into public.tv_codes (code, refresh_token, expires_at)
  values (p_code, p_refresh_token, v_expiry);

  return query select p_code, v_expiry;
end;
$$;

create or replace function public.tv_code_claim(p_code text)
returns table (refresh_token text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_code is null
     or p_code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' then
    return;
  end if;

  -- Atomic consume: only one TV can exchange a code.
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

commit;
