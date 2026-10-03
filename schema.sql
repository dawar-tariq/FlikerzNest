-- ============================================================================
--   F L I C K E R Z   N E S T   -   S U P A B A S E   S E T U P
--   Complete script. Run the WHOLE file once, top to bottom.
--
--   WHERE TO RUN IT
--     Supabase Dashboard  ->  SQL Editor  ->  New query  ->  paste  ->  Run
--
--   PROJECT
--     ref  : ctbrfynxmgcyvsrdihfg
--     url  : https://ctbrfynxmgcyvsrdihfg.supabase.co
--
--   OWNER ACCOUNT (created automatically in STEP 10)
--     email    : wanidawar03@gmail.com
--     password : dawar@123
--
--   WHAT THIS FILE DOES
--     STEP 0   required extension
--     STEP 1   tables: profiles, watchlists, custom_streams, custom_content,
--              admin_allowlist
--     STEP 2   indexes
--     STEP 3   seed the owner into the allowlist
--     STEP 4   functions
--     STEP 5   triggers (auto profile, auto promote, email sync, role guard)
--     STEP 6   enable Row Level Security
--     STEP 7   RLS policies for every table (select / insert / update / delete)
--     STEP 8   table + function grants
--     STEP 9   Realtime for live watchlists
--     STEP 10  create the owner account and promote it to admin
--     STEP 11  verification queries
--
--   NOTES
--     * Safe to re-run. Everything uses "if not exists" / "drop ... if exists".
--     * Table names and column names match index.html exactly.
--     * FORCE ROW LEVEL SECURITY is intentionally NOT used: the SECURITY
--       DEFINER trigger that creates profiles must bypass RLS, and the table
--       owner (postgres) must stay exempt or signups would fail.
-- ============================================================================

begin;


-- ############################################################################
--  STEP 0 - EXTENSION (needed for crypt() / gen_salt() to hash the password)
-- ############################################################################

do $$
begin
  create extension if not exists pgcrypto with schema extensions;
  raise notice 'STEP 0 ok - pgcrypto available';
exception when others then
  raise notice 'STEP 0 skipped - pgcrypto: %', sqlerrm;
end;
$$;


-- ############################################################################
--  STEP 1 - TABLES
-- ############################################################################

-- 1a. profiles ---------------------------------------------------------------
-- One row per authenticated user. "role" decides admin access in the app.
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  email        text not null unique,
  display_name text not null default '',
  role         text not null default 'user' check (role in ('user','admin')),
  created_at   timestamptz not null default now()
);

-- 1b. watchlists -------------------------------------------------------------
-- A member's saved titles. This is the "My Watchlist" row in the app.
create table if not exists public.watchlists (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  tmdb_id     bigint not null check (tmdb_id > 0),
  title       text not null,
  poster_path text,
  media_type  text not null check (media_type in ('movie','tv')),
  added_at    timestamptz not null default now(),
  constraint watchlists_user_media_unique unique (user_id, tmdb_id, media_type)
);

-- 1c. custom_streams ---------------------------------------------------------
-- Owner-defined stream overrides. If a row exists for a TMDB id, Server 1 in
-- the player loads stream_url instead of VidSrc.
create table if not exists public.custom_streams (
  id         uuid primary key default gen_random_uuid(),
  tmdb_id    bigint not null unique check (tmdb_id > 0),
  stream_url text not null check (stream_url ~ '^https://'),
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

-- 1d. custom_content ---------------------------------------------------------
-- Owner-published custom films or announcements ("From the Nest" row).
create table if not exists public.custom_content (
  id                uuid primary key default gen_random_uuid(),
  title             text not null,
  description       text,
  banner_url        text,
  custom_stream_url text,
  created_at        timestamptz not null default now()
);

-- 1e. admin_allowlist --------------------------------------------------------
-- Emails that must always be admin. Holds the owner account.
create table if not exists public.admin_allowlist (
  email    text primary key,
  added_at timestamptz not null default now()
);

do $$ begin raise notice 'STEP 1 ok - tables ready'; end $$;


-- ############################################################################
--  STEP 2 - INDEXES
-- ############################################################################

create index if not exists watchlists_user_added_idx
  on public.watchlists (user_id, added_at desc);

create index if not exists custom_content_created_idx
  on public.custom_content (created_at desc);

create index if not exists custom_streams_updated_idx
  on public.custom_streams (updated_by);

create index if not exists profiles_role_idx
  on public.profiles (role);

do $$ begin raise notice 'STEP 2 ok - indexes ready'; end $$;


-- ############################################################################
--  STEP 3 - SEED THE OWNER INTO THE ALLOWLIST
-- ############################################################################

insert into public.admin_allowlist (email)
values ('wanidawar03@gmail.com')
on conflict (email) do nothing;

do $$ begin raise notice 'STEP 3 ok - owner allowlisted'; end $$;


-- ############################################################################
--  STEP 4 - FUNCTIONS
-- ############################################################################

-- 4a. handle_new_user --------------------------------------------------------
-- Creates a profile automatically when a new user signs up, and promotes the
-- account to admin if its email is on the allowlist.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, display_name, role)
  values (
    new.id,
    new.email,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      split_part(coalesce(new.email, ''), '@', 1)
    ),
    case
      when exists (
        select 1 from public.admin_allowlist a
         where lower(a.email) = lower(new.email)
      ) then 'admin'
      else 'user'
    end
  )
  on conflict (id) do update
    set email = excluded.email,
        role  = case
                  when exists (
                    select 1 from public.admin_allowlist a
                     where lower(a.email) = lower(excluded.email)
                  ) then 'admin'
                  else public.profiles.role
                end;

  return new;
end;
$$;

-- 4b. promote_allowlisted ----------------------------------------------------
-- If an email is added to the allowlist later, promote the existing profile.
create or replace function public.promote_allowlisted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles p
     set role = 'admin'
   where lower(p.email) = lower(new.email);
  return new;
end;
$$;

-- 4c. is_admin ---------------------------------------------------------------
-- Admin test used by every policy. SECURITY DEFINER avoids recursive RLS
-- evaluation on public.profiles.
--
-- Grants admin when EITHER condition is true:
--   1. the profile row has role = 'admin'
--   2. the profile's email is on the admin allowlist
-- Condition 2 is the self-healing path: it keeps the owner in control even if
-- the profile row is missing, or its role was never promoted.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.profiles p
     where p.id = (select auth.uid())
       and (
             p.role = 'admin'
             or exists (
                  select 1 from public.admin_allowlist a
                   where lower(a.email) = lower(p.email)
                )
           )
  );
$$;

-- 4d. guard_role_change ------------------------------------------------------
-- Stops a non-admin from promoting themselves through the REST API.
-- The SQL Editor and service_role have no auth.uid(), so they stay unrestricted.
create or replace function public.guard_role_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role is distinct from new.role
     and (select auth.uid()) is not null
     and not public.is_admin()
  then
    raise exception 'Only an admin can change member roles.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

-- 4e. sync_profile_email -----------------------------------------------------
-- Keeps profiles.email correct if a user changes their auth email.
create or replace function public.sync_profile_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
     set email = new.email
   where id = new.id;
  return new;
end;
$$;

do $$ begin raise notice 'STEP 4 ok - functions ready'; end $$;


-- ############################################################################
--  STEP 5 - TRIGGERS
-- ############################################################################

-- 5a. create a profile on signup
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 5b. promote when an email is allowlisted later
drop trigger if exists promote_allowlisted_email on public.admin_allowlist;
create trigger promote_allowlisted_email
  after insert on public.admin_allowlist
  for each row execute function public.promote_allowlisted();

-- 5c. block self-promotion through the API
drop trigger if exists guard_role_change on public.profiles;
create trigger guard_role_change
  before update of role on public.profiles
  for each row execute function public.guard_role_change();

-- 5d. keep profile email in sync with auth email
drop trigger if exists sync_profile_email on auth.users;
create trigger sync_profile_email
  after update of email on auth.users
  for each row execute function public.sync_profile_email();

do $$ begin raise notice 'STEP 5 ok - triggers ready'; end $$;


-- ############################################################################
--  STEP 6 - ENABLE ROW LEVEL SECURITY
-- ############################################################################

alter table public.profiles        enable row level security;
alter table public.watchlists      enable row level security;
alter table public.custom_streams  enable row level security;
alter table public.custom_content  enable row level security;
alter table public.admin_allowlist enable row level security;

do $$ begin raise notice 'STEP 6 ok - RLS enabled on all tables'; end $$;


-- ############################################################################
--  STEP 7 - RLS POLICIES
-- ############################################################################

-- ===========================================================================
--  7a. profiles  (members see their own row, admins see all)
-- ===========================================================================

drop policy if exists profiles_select_self_or_admin on public.profiles;
create policy profiles_select_self_or_admin
  on public.profiles for select to authenticated
  using ( id = (select auth.uid()) or public.is_admin() );

drop policy if exists profiles_insert_self_as_user on public.profiles;
create policy profiles_insert_self_as_user
  on public.profiles for insert to authenticated
  with check (
    id = (select auth.uid())
    and (
      role = 'user'
      or exists (
        select 1 from public.admin_allowlist a
         where lower(a.email) = lower(email)
      )
    )
  );

drop policy if exists profiles_update_self_or_admin on public.profiles;
create policy profiles_update_self_or_admin
  on public.profiles for update to authenticated
  using ( id = (select auth.uid()) or public.is_admin() )
  with check ( id = (select auth.uid()) or public.is_admin() );

drop policy if exists profiles_delete_admin on public.profiles;
create policy profiles_delete_admin
  on public.profiles for delete to authenticated
  using ( public.is_admin() );

-- ===========================================================================
--  7b. watchlists  (private per member, admins may audit all lists)
-- ===========================================================================

drop policy if exists watchlists_select_own on public.watchlists;
create policy watchlists_select_own
  on public.watchlists for select to authenticated
  using ( user_id = (select auth.uid()) );

drop policy if exists watchlists_select_admin on public.watchlists;
create policy watchlists_select_admin
  on public.watchlists for select to authenticated
  using ( public.is_admin() );

drop policy if exists watchlists_insert_own on public.watchlists;
create policy watchlists_insert_own
  on public.watchlists for insert to authenticated
  with check ( user_id = (select auth.uid()) );

drop policy if exists watchlists_update_own on public.watchlists;
create policy watchlists_update_own
  on public.watchlists for update to authenticated
  using ( user_id = (select auth.uid()) )
  with check ( user_id = (select auth.uid()) );

drop policy if exists watchlists_delete_own on public.watchlists;
create policy watchlists_delete_own
  on public.watchlists for delete to authenticated
  using ( user_id = (select auth.uid()) );

-- ===========================================================================
--  7c. custom_streams  (everyone may read, only admins may write)
-- ===========================================================================

drop policy if exists custom_streams_select_public on public.custom_streams;
create policy custom_streams_select_public
  on public.custom_streams for select to anon, authenticated
  using ( true );

drop policy if exists custom_streams_insert_admin on public.custom_streams;
create policy custom_streams_insert_admin
  on public.custom_streams for insert to authenticated
  with check ( public.is_admin() );

drop policy if exists custom_streams_update_admin on public.custom_streams;
create policy custom_streams_update_admin
  on public.custom_streams for update to authenticated
  using ( public.is_admin() )
  with check ( public.is_admin() );

drop policy if exists custom_streams_delete_admin on public.custom_streams;
create policy custom_streams_delete_admin
  on public.custom_streams for delete to authenticated
  using ( public.is_admin() );

-- ===========================================================================
--  7d. custom_content  (everyone may read, only admins may write)
-- ===========================================================================

drop policy if exists custom_content_select_public on public.custom_content;
create policy custom_content_select_public
  on public.custom_content for select to anon, authenticated
  using ( true );

drop policy if exists custom_content_insert_admin on public.custom_content;
create policy custom_content_insert_admin
  on public.custom_content for insert to authenticated
  with check ( public.is_admin() );

drop policy if exists custom_content_update_admin on public.custom_content;
create policy custom_content_update_admin
  on public.custom_content for update to authenticated
  using ( public.is_admin() )
  with check ( public.is_admin() );

drop policy if exists custom_content_delete_admin on public.custom_content;
create policy custom_content_delete_admin
  on public.custom_content for delete to authenticated
  using ( public.is_admin() );

-- ===========================================================================
--  7e. admin_allowlist  (readable to confirm admin state, admin-only writes)
-- ===========================================================================

drop policy if exists admin_allowlist_select on public.admin_allowlist;
create policy admin_allowlist_select
  on public.admin_allowlist for select to authenticated
  using (
    public.is_admin()
    or lower(email) = lower(
         (select email from public.profiles where id = (select auth.uid()))
       )
  );

drop policy if exists admin_allowlist_insert_admin on public.admin_allowlist;
create policy admin_allowlist_insert_admin
  on public.admin_allowlist for insert to authenticated
  with check ( public.is_admin() );

drop policy if exists admin_allowlist_update_admin on public.admin_allowlist;
create policy admin_allowlist_update_admin
  on public.admin_allowlist for update to authenticated
  using ( public.is_admin() )
  with check ( public.is_admin() );

drop policy if exists admin_allowlist_delete_admin on public.admin_allowlist;
create policy admin_allowlist_delete_admin
  on public.admin_allowlist for delete to authenticated
  using ( public.is_admin() );

do $$ begin raise notice 'STEP 7 ok - 21 RLS policies created'; end $$;


-- ############################################################################
--  STEP 8 - GRANTS
-- ############################################################################

grant usage on schema public to anon, authenticated;

-- start from a clean slate
revoke all on table public.profiles        from public, anon, authenticated;
revoke all on table public.watchlists      from public, anon, authenticated;
revoke all on table public.custom_streams  from public, anon, authenticated;
revoke all on table public.custom_content  from public, anon, authenticated;
revoke all on table public.admin_allowlist from public, anon, authenticated;

-- members can manage their own rows (RLS decides which rows)
grant select, insert, update, delete
  on table public.profiles   to authenticated;
grant select, insert, update, delete
  on table public.watchlists to authenticated;

-- public catalog reads, admin-only writes
grant select                    on table public.custom_streams to anon, authenticated;
grant insert, update, delete    on table public.custom_streams to authenticated;
grant select                    on table public.custom_content to anon, authenticated;
grant insert, update, delete    on table public.custom_content to authenticated;

-- allowlist is read-only to clients
grant select on table public.admin_allowlist to authenticated;

-- internal trigger functions stay private
revoke all on function public.handle_new_user()     from public, anon, authenticated;
revoke all on function public.promote_allowlisted() from public, anon, authenticated;
revoke all on function public.guard_role_change()   from public, anon, authenticated;
revoke all on function public.sync_profile_email()  from public, anon, authenticated;

revoke all on function public.is_admin()    from public;
grant  execute on function public.is_admin() to anon, authenticated;

do $$ begin raise notice 'STEP 8 ok - grants applied'; end $$;


-- ############################################################################
--  STEP 9 - REALTIME (so "My Watchlist" updates without a refresh)
-- ############################################################################

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname  = 'supabase_realtime'
          and schemaname = 'public'
          and tablename  = 'watchlists'
     )
  then
    execute 'alter publication supabase_realtime add table public.watchlists';
  end if;
  raise notice 'STEP 9 ok - realtime enabled for watchlists';
exception when others then
  raise notice 'STEP 9 skipped (%) - enable it manually: Database > Replication > watchlists', sqlerrm;
end;
$$;


-- ############################################################################
--  STEP 10 - CREATE THE OWNER ACCOUNT AND PROMOTE IT
-- ############################################################################
--  Creates wanidawar03@gmail.com with password dawar@123, already confirmed, so
--  you can sign in immediately without waiting for a confirmation email.
--  If this step errors (rare), just sign up through the app's Sign in dialog -
--  the allowlist trigger from STEP 5 promotes you to admin automatically.

do $$
declare
  v_user_id   uuid;
  v_owner_mail constant text := 'wanidawar03@gmail.com';
  v_owner_pass constant text := 'dawar@123';
begin
  -- 10a. create the auth user (confirmed, so no email link needed)
  insert into auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    recovery_token,
    email_change_token_new,
    email_change
  ) values (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    v_owner_mail,
    extensions.crypt(v_owner_pass, extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Dawar Tariq"}',
    now(),
    now(),
    '',
    '',
    '',
    ''
  )
  on conflict (email) do nothing;

  select id into v_user_id
    from auth.users
   where lower(email) = lower(v_owner_mail)
   limit 1;

  if v_user_id is null then
    raise notice 'STEP 10 warning - could not resolve owner user id';
    return;
  end if;

  -- 10b. create the identity row (required for password sign-in)
  insert into auth.identities (
    id,
    user_id,
    provider_id,
    identity_data,
    last_sign_in_at,
    created_at,
    updated_at
  ) values (
    gen_random_uuid(),
    v_user_id,
    'email',
    json_build_object(
      'sub',            v_user_id::text,
      'email',          v_owner_mail,
      'email_verified', true
    ),
    now(),
    now(),
    now()
  )
  on conflict do nothing;

  -- 10c. create or promote the profile row
  insert into public.profiles (id, email, display_name, role)
  values (v_user_id, v_owner_mail, 'Dawar Tariq', 'admin')
  on conflict (id) do update
    set role         = 'admin',
        display_name = coalesce(nullif(public.profiles.display_name, ''), 'Dawar Tariq');

  raise notice 'STEP 10 ok - owner ready: % (admin)', v_owner_mail;
exception
  when others then
    raise notice 'STEP 10 skipped (%) - sign up in the app instead; the allowlist promotes you.', sqlerrm;
end;
$$;


commit;


-- ============================================================================
--  STEP 12 - v2 FEATURES: list statuses, watch history, member suspension
--  Included when you run the whole file. Safe to run again at any time.
--  Already set up? Run just this STEP 12 block on its own.
-- ============================================================================

begin;

-- 12a. watchlist status: Plan to watch / Watching / Completed ----------------
alter table public.watchlists
  add column if not exists status text not null default 'plan';

do $$
begin
  alter table public.watchlists
    add constraint watchlists_status_check check (status in ('plan','watching','completed'));
exception when duplicate_object then null;
end $$;

create index if not exists watchlists_user_status_idx on public.watchlists (user_id, status);

-- 12b. suspension fields on profiles -----------------------------------------
alter table public.profiles add column if not exists is_blocked     boolean not null default false;
alter table public.profiles add column if not exists blocked_reason text;
alter table public.profiles add column if not exists blocked_at     timestamptz;

-- 12c. watch history (one row every time a signed-in member opens a title) --
create table if not exists public.watch_history (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  tmdb_id     bigint not null check (tmdb_id > 0),
  media_type  text not null check (media_type in ('movie','tv')),
  title       text not null,
  poster_path text,
  season      integer check (season is null or season > 0),
  episode     integer check (episode is null or episode > 0),
  watched_at  timestamptz not null default now()
);
create index if not exists watch_history_user_idx   on public.watch_history (user_id, watched_at desc);
create index if not exists watch_history_recent_idx on public.watch_history (watched_at desc);

-- 12d. helpers -----------------------------------------------------------------
-- A suspended admin loses admin rights immediately.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = (select auth.uid())
       and not p.is_blocked
       and ( p.role = 'admin'
             or exists (select 1 from public.admin_allowlist a
                        where lower(a.email) = lower(p.email)) )
  );
$$;

-- True unless the signed-in account is suspended.
create or replace function public.is_active()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1 from public.profiles p
     where p.id = (select auth.uid()) and p.is_blocked
  );
$$;

-- 12e. moderation guard ----------------------------------------------------------
--  * only admins may suspend or restore members
--  * nobody can suspend themselves
--  * the owner (allowlisted email) can never be suspended
--  * blocked_at is stamped by the database, not the browser
create or replace function public.guard_moderation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.is_blocked     is distinct from new.is_blocked
  or old.blocked_reason is distinct from new.blocked_reason
  or old.blocked_at     is distinct from new.blocked_at then

    if (select auth.uid()) is not null then
      if not public.is_admin() then
        raise exception 'Only an admin can suspend or restore members.' using errcode = '42501';
      end if;
      if new.id = (select auth.uid()) and new.is_blocked then
        raise exception 'You cannot suspend your own account.' using errcode = '42501';
      end if;
    end if;

    if new.is_blocked and exists (
      select 1 from public.admin_allowlist a where lower(a.email) = lower(new.email)
    ) then
      raise exception 'The owner account cannot be suspended.' using errcode = '42501';
    end if;

    if new.is_blocked and not coalesce(old.is_blocked, false) then
      new.blocked_at := now();
    end if;
    if not new.is_blocked then
      new.blocked_at := null;
      new.blocked_reason := null;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists guard_moderation on public.profiles;
create trigger guard_moderation
  before update of is_blocked, blocked_reason, blocked_at on public.profiles
  for each row execute function public.guard_moderation();

-- 12f. real sign-in ban ------------------------------------------------------------
-- Mirrors the suspension onto auth.users.banned_until, so Supabase Auth itself
-- refuses sign-ins and token refreshes. Wrapped in an exception handler: if your
-- project does not allow this, the suspension still works through RLS + the app.
create or replace function public.sync_auth_ban()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.is_blocked is distinct from new.is_blocked then
    begin
      update auth.users
         set banned_until = case when new.is_blocked then now() + interval '100 years' else null end
       where id = new.id;
    exception when others then
      raise notice 'sync_auth_ban skipped: %', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_auth_ban on public.profiles;
create trigger sync_auth_ban
  after update of is_blocked on public.profiles
  for each row execute function public.sync_auth_ban();

-- 12g. watchlists: writes now require an active (not suspended) account --------
drop policy if exists watchlists_insert_own on public.watchlists;
create policy watchlists_insert_own
  on public.watchlists for insert to authenticated
  with check ( user_id = (select auth.uid()) and public.is_active() );

drop policy if exists watchlists_update_own on public.watchlists;
create policy watchlists_update_own
  on public.watchlists for update to authenticated
  using ( user_id = (select auth.uid()) )
  with check ( user_id = (select auth.uid()) and public.is_active() );

drop policy if exists watchlists_delete_own on public.watchlists;
create policy watchlists_delete_own
  on public.watchlists for delete to authenticated
  using ( user_id = (select auth.uid()) and public.is_active() );

drop policy if exists watchlists_delete_admin on public.watchlists;
create policy watchlists_delete_admin
  on public.watchlists for delete to authenticated
  using ( public.is_admin() );

-- 12h. watch_history RLS -------------------------------------------------------------
alter table public.watch_history enable row level security;

drop policy if exists watch_history_select_own on public.watch_history;
create policy watch_history_select_own
  on public.watch_history for select to authenticated
  using ( user_id = (select auth.uid()) );

drop policy if exists watch_history_select_admin on public.watch_history;
create policy watch_history_select_admin
  on public.watch_history for select to authenticated
  using ( public.is_admin() );

drop policy if exists watch_history_insert_own on public.watch_history;
create policy watch_history_insert_own
  on public.watch_history for insert to authenticated
  with check ( user_id = (select auth.uid()) and public.is_active() );

drop policy if exists watch_history_delete_own on public.watch_history;
create policy watch_history_delete_own
  on public.watch_history for delete to authenticated
  using ( user_id = (select auth.uid()) );

drop policy if exists watch_history_delete_admin on public.watch_history;
create policy watch_history_delete_admin
  on public.watch_history for delete to authenticated
  using ( public.is_admin() );

-- 12i. grants ------------------------------------------------------------------------
revoke all on table public.watch_history from public, anon, authenticated;
grant select, insert, delete on table public.watch_history to authenticated;

revoke all on function public.is_active()          from public;
grant execute on function public.is_active()        to anon, authenticated;
revoke all on function public.guard_moderation()   from public, anon, authenticated;
revoke all on function public.sync_auth_ban()      from public, anon, authenticated;

commit;

-- 12j. realtime on profiles, so a suspension signs the member out instantly --
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'profiles'
     ) then
    execute 'alter publication supabase_realtime add table public.profiles';
  end if;
  raise notice 'STEP 12 ok - statuses, watch history and suspensions ready';
exception when others then
  raise notice 'STEP 12j skipped (%) - enable Realtime on profiles manually: Database > Replication', sqlerrm;
end;
$$;


-- ============================================================================
--  STEP 13 - REPAIR: owner sign-in, missing profiles, RLS back on
--  Run this block on its own in the SQL Editor. Safe to run any number of times.
--  Replaces STEP 10, which could fail silently (invalid ON CONFLICT on
--  auth.users and an incomplete auth.identities row).
-- ============================================================================

-- 13a. everything the app expects ----------------------------------------------
alter table public.profiles   add column if not exists is_blocked     boolean not null default false;
alter table public.profiles   add column if not exists blocked_reason text;
alter table public.profiles   add column if not exists blocked_at     timestamptz;
alter table public.watchlists add column if not exists status         text not null default 'plan';

create table if not exists public.watch_history (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  tmdb_id     bigint not null check (tmdb_id > 0),
  media_type  text not null check (media_type in ('movie','tv')),
  title       text not null,
  poster_path text,
  season      integer,
  episode     integer,
  watched_at  timestamptz not null default now()
);
create index if not exists watch_history_user_idx on public.watch_history (user_id, watched_at desc);

-- 13b. owner login: same password as index.html, email confirmed, not banned --
do $$
declare
  v_id   uuid;
  v_mail constant text := 'wanidawar03@gmail.com';
  v_pass constant text := 'dawar@123';
begin
  select id into v_id from auth.users where lower(email) = v_mail limit 1;
  if v_id is null then
    v_id := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_mail,
            crypt(v_pass, gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}', '{"display_name":"Dawar Tariq"}',
            now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, provider, identity_data,
                                 last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_id, v_id::text, 'email',
            jsonb_build_object('sub', v_id::text, 'email', v_mail, 'email_verified', true),
            now(), now(), now());
    raise notice 'Owner account created';
  else
    update auth.users
       set encrypted_password = crypt(v_pass, gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()),
           banned_until       = null,
           updated_at         = now()
     where id = v_id;
    raise notice 'Owner password reset and email confirmed';
  end if;
exception when others then
  raise notice 'Owner repair skipped (%) - fix it in Dashboard > Authentication > Users', sqlerrm;
end $$;

-- 13c. allowlist + a profile for every account ---------------------------------
insert into public.admin_allowlist (email) values ('wanidawar03@gmail.com')
on conflict (email) do nothing;

insert into public.profiles (id, email, display_name, role)
select u.id, u.email,
       coalesce(nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''), split_part(u.email, '@', 1)),
       case when exists (select 1 from public.admin_allowlist a where lower(a.email) = lower(u.email))
            then 'admin' else 'user' end
  from auth.users u
 where u.email is not null
on conflict do nothing;

update public.profiles
   set role = 'admin', is_blocked = false
 where lower(email) in (select lower(email) from public.admin_allowlist);

-- 13d. helper functions -----------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = (select auth.uid()) and not p.is_blocked
       and (p.role = 'admin'
            or exists (select 1 from public.admin_allowlist a where lower(a.email) = lower(p.email)))
  );
$$;

create or replace function public.is_active()
returns boolean language sql stable security definer set search_path = ''
as $$
  select not exists (select 1 from public.profiles p
                      where p.id = (select auth.uid()) and p.is_blocked);
$$;

-- 13e. turn RLS back on, with the policies the app needs ---------------------
alter table public.profiles        enable row level security;
alter table public.watchlists      enable row level security;
alter table public.watch_history   enable row level security;
alter table public.custom_streams  enable row level security;
alter table public.custom_content  enable row level security;
alter table public.admin_allowlist enable row level security;

-- profiles: members see themselves, admins see everyone
drop policy if exists profiles_select_self_or_admin on public.profiles;
create policy profiles_select_self_or_admin on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_admin());
drop policy if exists profiles_insert_self_as_user on public.profiles;
create policy profiles_insert_self_as_user on public.profiles for insert to authenticated
  with check (id = (select auth.uid()) and role = 'user');
drop policy if exists profiles_update_self_or_admin on public.profiles;
create policy profiles_update_self_or_admin on public.profiles for update to authenticated
  using (id = (select auth.uid()) or public.is_admin())
  with check (id = (select auth.uid()) or public.is_admin());
drop policy if exists profiles_delete_admin on public.profiles;
create policy profiles_delete_admin on public.profiles for delete to authenticated
  using (public.is_admin());

-- watchlists: private per member, admins can read and remove
drop policy if exists watchlists_select_admin on public.watchlists;
drop policy if exists watchlists_delete_admin on public.watchlists;
drop policy if exists watchlists_select_own on public.watchlists;
create policy watchlists_select_own on public.watchlists for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());
drop policy if exists watchlists_insert_own on public.watchlists;
create policy watchlists_insert_own on public.watchlists for insert to authenticated
  with check (user_id = (select auth.uid()) and public.is_active());
drop policy if exists watchlists_update_own on public.watchlists;
create policy watchlists_update_own on public.watchlists for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and public.is_active());
drop policy if exists watchlists_delete_own on public.watchlists;
create policy watchlists_delete_own on public.watchlists for delete to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());

-- watch_history: members see and clear their own, admins see all
drop policy if exists watch_history_select_admin on public.watch_history;
drop policy if exists watch_history_delete_admin on public.watch_history;
drop policy if exists watch_history_select_own on public.watch_history;
create policy watch_history_select_own on public.watch_history for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());
drop policy if exists watch_history_insert_own on public.watch_history;
create policy watch_history_insert_own on public.watch_history for insert to authenticated
  with check (user_id = (select auth.uid()) and public.is_active());
drop policy if exists watch_history_delete_own on public.watch_history;
create policy watch_history_delete_own on public.watch_history for delete to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());

-- custom_streams / custom_content: everyone reads, admins write
drop policy if exists custom_streams_select_public on public.custom_streams;
create policy custom_streams_select_public on public.custom_streams for select to anon, authenticated
  using (true);
drop policy if exists custom_streams_write_admin on public.custom_streams;
create policy custom_streams_write_admin on public.custom_streams for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists custom_content_select_public on public.custom_content;
create policy custom_content_select_public on public.custom_content for select to anon, authenticated
  using (true);
drop policy if exists custom_content_write_admin on public.custom_content;
create policy custom_content_write_admin on public.custom_content for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- admin_allowlist: admins only
drop policy if exists admin_allowlist_select on public.admin_allowlist;
create policy admin_allowlist_select on public.admin_allowlist for select to authenticated
  using (public.is_admin());

-- 13f. grants ------------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.profiles, public.watchlists to authenticated;
grant select, insert, delete on public.watch_history to authenticated;
grant select on public.custom_streams, public.custom_content to anon, authenticated;
grant insert, update, delete on public.custom_streams, public.custom_content to authenticated;
grant select on public.admin_allowlist to authenticated;
grant execute on function public.is_admin(), public.is_active() to anon, authenticated;

-- 13g. realtime (live list updates + instant suspension) -------------------------
do $$
declare t text;
begin
  foreach t in array array['watchlists', 'profiles', 'watch_history'] loop
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
       and not exists (select 1 from pg_publication_tables
                        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
exception when others then
  raise notice 'Realtime step skipped: %', sqlerrm;
end $$;

-- 13h. check - every column should look healthy -----------------------------------
select
  (select count(*) from public.profiles)      as profiles,
  (select count(*) from public.watchlists)    as watchlist_rows,
  (select count(*) from public.watch_history) as history_rows,
  (select role from public.profiles where lower(email) = 'wanidawar03@gmail.com')                  as owner_role,
  (select email_confirmed_at is not null from auth.users where lower(email) = 'wanidawar03@gmail.com') as owner_confirmed,
  (select bool_and(relrowsecurity) from pg_class
    where oid in ('public.profiles'::regclass, 'public.watchlists'::regclass, 'public.watch_history'::regclass)) as rls_on;


-- ============================================================================
--  STEP 14 - (optional) custom stream links for signed-in members only
--  Matches the site's sign-in-to-watch rule: guests can no longer read your
--  custom stream URLs through the API. Safe to run again.
-- ============================================================================
drop policy if exists custom_streams_select_public  on public.custom_streams;
drop policy if exists custom_streams_select_members on public.custom_streams;
create policy custom_streams_select_members
  on public.custom_streams for select to authenticated
  using ( public.is_active() );
revoke select on public.custom_streams from anon;


--  STEP 15 - TV pairing codes (sign in on a TV without typing a password)
--  The signed-in phone/desktop stores a short-lived one-time code plus its
--  session; the TV reads it, signs itself in and the code is destroyed.
--  Safe to run again.
-- ============================================================================
begin;

create table if not exists public.tv_codes (
  code          text primary key,
  user_id       uuid not null references auth.users (id) on delete cascade,
  access_token  text not null,
  refresh_token text not null,
  expires_at    timestamptz not null default (now() + interval '3 minutes'),
  used_at       timestamptz,
  created_at    timestamptz not null default now()
);

alter table public.tv_codes enable row level security;

drop policy if exists tv_codes_insert_own on public.tv_codes;
create policy tv_codes_insert_own
  on public.tv_codes for insert to authenticated
  with check ( user_id = (select auth.uid()) );

drop policy if exists tv_codes_select_claim on public.tv_codes;
create policy tv_codes_select_claim
  on public.tv_codes for select to anon, authenticated
  using ( used_at is null and expires_at > now() );

drop policy if exists tv_codes_select_own on public.tv_codes;
create policy tv_codes_select_own
  on public.tv_codes for select to authenticated
  using ( user_id = (select auth.uid()) or public.is_admin() );

drop policy if exists tv_codes_delete_claim on public.tv_codes;
create policy tv_codes_delete_claim
  on public.tv_codes for delete to anon, authenticated
  using ( true );

revoke all on table public.tv_codes from public, anon, authenticated;
grant select, insert, delete on table public.tv_codes to anon, authenticated;

commit;

-- maintenance: remove codes that expired more than a day ago
-- delete from public.tv_codes where expires_at < now() - interval '1 day';


-- ============================================================================
--  EMERGENCY REPAIR - run this block on its own if Members / Watchlists are
--  empty in the admin panel. It is safe to run any number of times.
-- ============================================================================

-- 1) guarantee the owner is on the allowlist
insert into public.admin_allowlist (email)
values ('wanidawar03@gmail.com')
on conflict (email) do nothing;

-- 2) promote every allowlisted email that already has a profile
update public.profiles p
   set role = 'admin'
 where lower(p.email) in (select lower(email) from public.admin_allowlist);

-- 3) create the profile if the auth user exists but no profile row does
insert into public.profiles (id, email, display_name, role)
select u.id,
       u.email,
       coalesce(nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                split_part(u.email, '@', 1)),
       'admin'
  from auth.users u
 where lower(u.email) = 'wanidawar03@gmail.com'
on conflict (id) do update set role = 'admin';

-- 4) reinstall the admin check (suspended accounts never count as admin)
alter table public.profiles add column if not exists is_blocked boolean not null default false;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = (select auth.uid())
       and not p.is_blocked
       and ( p.role = 'admin'
             or exists (select 1 from public.admin_allowlist a
                        where lower(a.email) = lower(p.email)) )
  );
$$;

-- 5) DIAGNOSE - paste the results of these three if it still fails
-- select id, email, role, created_at from public.profiles order by created_at desc;
-- select count(*) as allowlist_rows from public.admin_allowlist;
-- select count(*) as member_lists from public.watchlists;


-- ============================================================================
--  STEP 11 - VERIFICATION  (uncomment any block and press Run to check)
-- ============================================================================

-- 11a. every table exists -----------------------------------------------------
-- select table_name
--   from information_schema.tables
--  where table_schema = 'public'
--    and table_name in ('profiles','watchlists','custom_streams','custom_content','admin_allowlist')
--  order by table_name;

-- 11b. RLS is on for every table ---------------------------------------------
-- select relname as table_name, relrowsecurity as rls_enabled
--   from pg_class
--  where relnamespace = 'public'::regnamespace
--    and relkind = 'r'
--  order by relname;

-- 11c. policy count per table -------------------------------------------------
-- select tablename, count(*) as policies
--   from pg_policies
--  where schemaname = 'public'
--  group by tablename
--  order by tablename;

-- 11d. the owner is allowlisted and is an admin -------------------------------
-- select a.email as allowlisted,
--        p.email as profile_email,
--        p.role,
--        p.display_name,
--        p.created_at
--   from public.admin_allowlist a
--   left join public.profiles p on lower(p.email) = lower(a.email);

-- 11e. realtime is attached ---------------------------------------------------
-- select * from pg_publication_tables
--  where pubname = 'supabase_realtime' and tablename = 'watchlists';

-- 11f. total row counts -------------------------------------------------------
-- select (select count(*) from public.profiles)        as members,
--        (select count(*) from public.watchlists)      as saved_titles,
--        (select count(*) from public.custom_streams)  as overrides,
--        (select count(*) from public.custom_content)  as published;


-- ============================================================================
--  WHAT TO DO NEXT
--
--  1. Open the app and go to      index.html#admin
--     (or press Ctrl/Cmd + Shift + A)
--     Sign in with:
--         wanidawar03@gmail.com   /   dawar@123
--
--  2. Nothing else to configure. The TMDB key and Supabase credentials are
--     already baked into index.html, so the live catalog and member accounts
--     work for every visitor straight away. The "API keys" tab in the admin
--     panel is only for temporary per-browser overrides.
--
--  3. Confirm it worked: Admin > Overview should show Supabase "connected" and
--     TMDB "live". Admin > Members should list you with an owner badge.
--
--  4. Members can now sign up from the site and their watchlists sync live.
--     If you keep "Confirm email" ON in Authentication settings, new members
--     must click the link in their inbox before their first sign-in.
--
-- ============================================================================
--  SECURITY NOTES - please read before going public
--
--  * The anon key in index.html is meant to be public. It only carries the
--    "anon" role, and every admin write above requires public.is_admin(), so a
--    leaked anon key still cannot modify your data. RLS is the real boundary.
--
--  * Never paste a service_role key into index.html. That key bypasses RLS.
--
--  * The owner password lives in index.html as a convenience gate for the
--    admin UI. Treat it as UI access control, not as data protection - the
--    policies above are what actually protect the tables.
--
--  * To change the owner password, update BOTH places:
--        a) Supabase Dashboard > Authentication > Users > your user > Reset
--        b) index.html  ->  const OWNER = { password: "..." }
--    Then rotate it, since it has been shared outside your machine.
--
--  * Useful maintenance SQL:
--
--    promote someone manually:
--      update public.profiles set role = 'admin' where email = 'someone@mail.com';
--
--    demote someone:
--      update public.profiles set role = 'user' where email = 'someone@mail.com';
--
--    allowlist a new admin (auto-promotes them on next profile touch):
--      insert into public.admin_allowlist (email) values ('someone@mail.com');
--
--    delete a member's whole watchlist:
--      delete from public.watchlists where user_id = (select id from public.profiles where email = 'someone@mail.com');
--
--    remove a stream override:
--      delete from public.custom_streams where tmdb_id = 693134;
--
--    see every saved title across all members:
--      select p.email, w.title, w.media_type, w.added_at
--        from public.watchlists w
--        join public.profiles p on p.id = w.user_id
--       order by w.added_at desc;
-- ============================================================================
