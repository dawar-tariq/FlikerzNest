-- Flickerz Nest TV pairing migration
-- Run once in Supabase Dashboard -> SQL Editor -> New query.
-- Safe to re-run; table, index and functions are created idempotently.
begin;

-- ############################################################################
--  STEP 15 - TV DEVICE CODE SIGN-IN (TV generates, phone approves)
-- ############################################################################
-- The TV creates a six-character code plus a private 256-bit secret.
-- The phone approves that code while authenticated. The TV polls using the
-- secret and receives a one-use refresh-token grant only after approval.
-- Direct table access is revoked; all access goes through scoped RPCs.

create table if not exists public.tv_codes (
  code text primary key check (code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'),
  secret_hash bytea not null,
  grant_token text,
  expires_at timestamptz not null default (now() + interval '9 minutes'),
  created_at timestamptz not null default now()
);
create index if not exists tv_codes_expires_idx on public.tv_codes (expires_at);
alter table public.tv_codes enable row level security;
revoke all on table public.tv_codes from public, anon, authenticated;

create or replace function public.tv_code_create()
returns table (code text, secret text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_secret text;
  v_bytes bytea;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i integer;
  attempts integer := 0;
begin
  delete from public.tv_codes where tv_codes.expires_at <= pg_catalog.now();
  v_bytes := extensions.gen_random_bytes(32);
  v_secret := pg_catalog.encode(v_bytes, 'hex');

  loop
    attempts := attempts + 1;
    v_bytes := extensions.gen_random_bytes(6);
    v_code := '';
    for i in 0..5 loop
      v_code := v_code || pg_catalog.substr(v_alphabet, (pg_catalog.get_byte(v_bytes, i) % pg_catalog.length(v_alphabet)) + 1, 1);
    end loop;
    exit when not exists (select 1 from public.tv_codes t where t.code = v_code);
    if attempts > 10 then
      raise exception 'Could not allocate a TV code. Try again.';
    end if;
  end loop;

  insert into public.tv_codes (code, secret_hash, expires_at)
  values (v_code, extensions.digest(v_secret, 'sha256'), pg_catalog.now() + interval '9 minutes');

  return query select v_code, v_secret, pg_catalog.now() + interval '9 minutes';
end;
$$;

create or replace function public.tv_code_approve(p_code text, p_grant text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in on your phone or computer first.' using errcode = '42501';
  end if;
  if p_code is null or p_code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'
     or p_grant is null or pg_catalog.length(p_grant) < 20 then
    raise exception 'Invalid TV approval request.' using errcode = '22023';
  end if;

  update public.tv_codes
     set grant_token = p_grant
   where code = p_code
     and expires_at > pg_catalog.now()
     and grant_token is null;
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;

create or replace function public.tv_code_poll(p_code text, p_secret text)
returns table (status text, grant_token text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.tv_codes%rowtype;
begin
  if p_code is null or p_secret is null then return; end if;

  select * into v_row
    from public.tv_codes t
   where t.code = p_code
     and t.secret_hash = extensions.digest(p_secret, 'sha256')
   for update;

  if not found then return; end if;

  if v_row.expires_at <= pg_catalog.now() then
    delete from public.tv_codes where code = v_row.code;
    return query select 'expired'::text, null::text;
    return;
  end if;

  if v_row.grant_token is null then
    return query select 'pending'::text, null::text;
    return;
  end if;

  -- Consume the code exactly once before releasing the grant.
  delete from public.tv_codes where code = v_row.code;
  return query select 'approved'::text, v_row.grant_token;
end;
$$;

revoke all on function public.tv_code_create() from public;
grant execute on function public.tv_code_create() to anon, authenticated;
revoke all on function public.tv_code_approve(text, text) from public, anon;
grant execute on function public.tv_code_approve(text, text) to authenticated;
revoke all on function public.tv_code_poll(text, text) from public;
grant execute on function public.tv_code_poll(text, text) to anon, authenticated;

do $$ begin raise notice 'STEP 15 ok - TV device-code sign-in enabled'; end $$;

commit;
