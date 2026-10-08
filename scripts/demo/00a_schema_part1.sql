-- =====================================================================
-- TAMS database schema — part 1 of 3
-- Generated from supabase/migrations (do not edit by hand).
-- Paste into the Supabase SQL Editor and run. Run the three parts in
-- order: 00a, 00b, 00c — then 01_create_accounts.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 20260919090000_tams_foundation.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — Traditional Authority Management System
-- Foundation migration: roles, staff, user accounts, authentication.
--
-- Scope of this migration (nothing else is created):
--   * roles            — the four staff roles
--   * staff            — the staff record
--   * user_accounts    — the sign-in account linked to auth.users
--
-- Everything is written on the assumption that the browser can never be
-- trusted: the client holds no secrets, performs no writes, and every
-- privileged decision is re-made in the database from auth.uid().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

create table if not exists public.roles (
  id          uuid primary key default gen_random_uuid(),
  role_name   text not null unique,
  description text,
  created_at  timestamptz not null default now()
);

comment on table public.roles is
  'The fixed set of staff roles. Rows are seeded by migration and are not created through the application.';

create table if not exists public.staff (
  id              uuid primary key default gen_random_uuid(),
  employee_number text not null unique,
  first_name      text not null,
  last_name       text not null,
  email           text not null unique,
  contact_number  text not null,
  role_id         uuid not null references public.roles (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint staff_employee_number_not_blank check (btrim(employee_number) <> ''),
  constraint staff_first_name_not_blank      check (btrim(first_name) <> ''),
  constraint staff_last_name_not_blank       check (btrim(last_name) <> ''),
  constraint staff_email_format              check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  constraint staff_contact_number_format     check (contact_number ~ '^[0-9+][0-9 ()+-]{8,19}$')
);

comment on table public.staff is
  'One row per staff member. A staff member holds exactly one role (staff.role_id).';

create index if not exists staff_role_id_idx on public.staff (role_id);

create table if not exists public.user_accounts (
  id             uuid primary key default gen_random_uuid(),
  auth_user_id   uuid not null unique references auth.users (id) on delete cascade,
  email          text not null unique,
  account_type   text not null,
  account_status text not null,
  staff_id       uuid unique references public.staff (id) on delete restrict,
  resident_id    uuid,                                   -- reserved for a later function; unused for now
  created_at     timestamptz not null default now(),
  last_login     timestamptz,
  constraint user_accounts_account_type_allowed   check (account_type in ('staff')),
  constraint user_accounts_account_status_allowed check (account_status in ('active', 'deactivated')),
  constraint user_accounts_email_format           check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  -- a staff account must point at a staff record and never at a resident
  constraint user_accounts_staff_shape check (
    account_type <> 'staff' or (staff_id is not null and resident_id is null)
  )
);

comment on table public.user_accounts is
  'Sign-in account linked to auth.users. For staff, account_status is the single source of truth for system access.';
comment on column public.user_accounts.resident_id is
  'Reserved for a future resident function. Not used by any current code path.';

create index if not exists user_accounts_staff_id_idx on public.user_accounts (staff_id);

-- ---------------------------------------------------------------------
-- 2. Seed the roles
-- ---------------------------------------------------------------------

insert into public.roles (role_name, description) values
  ('Registry Clerk',        'Handles registry intake and record keeping.'),
  ('Land Officer',          'Handles land related administration.'),
  ('Council Secretary',     'Handles council administration and meetings.'),
  ('Council Administrator', 'Administers the system and manages staff accounts.')
on conflict (role_name) do nothing;

-- ---------------------------------------------------------------------
-- 3. Normalisation and integrity triggers
-- ---------------------------------------------------------------------

create or replace function public.tg_staff_normalise()
returns trigger
language plpgsql
as $$
begin
  new.employee_number := btrim(new.employee_number);
  new.first_name      := btrim(new.first_name);
  new.last_name       := btrim(new.last_name);
  new.email           := lower(btrim(new.email));
  new.contact_number  := btrim(new.contact_number);
  new.updated_at      := now();
  return new;
end;
$$;

drop trigger if exists staff_normalise on public.staff;
create trigger staff_normalise
  before insert or update on public.staff
  for each row execute function public.tg_staff_normalise();

create or replace function public.tg_user_accounts_normalise()
returns trigger
language plpgsql
as $$
begin
  new.email := lower(btrim(new.email));
  return new;
end;
$$;

drop trigger if exists user_accounts_normalise on public.user_accounts;
create trigger user_accounts_normalise
  before insert or update on public.user_accounts
  for each row execute function public.tg_user_accounts_normalise();

-- Case-insensitive uniqueness for the employee number.
create unique index if not exists staff_employee_number_ci_idx
  on public.staff (upper(employee_number));

-- The id of the Council Administrator role, used by the guards below.
create or replace function public.council_administrator_role_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from public.roles where role_name = 'Council Administrator';
$$;

-- During normal operation there is exactly ONE Council Administrator.
-- Enforced in the database so that no code path — application, edge
-- function or direct SQL — can quietly create a second one.
create or replace function public.tg_enforce_single_council_administrator()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_role_id uuid := public.council_administrator_role_id();
begin
  if new.role_id = v_admin_role_id
     and exists (
       select 1 from public.staff s
       where s.role_id = v_admin_role_id
         and s.id <> new.id
     )
  then
    raise exception 'A Council Administrator already exists.'
      using errcode = 'TA001';
  end if;
  return new;
end;
$$;

drop trigger if exists staff_single_council_administrator on public.staff;
create trigger staff_single_council_administrator
  before insert or update of role_id on public.staff
  for each row execute function public.tg_enforce_single_council_administrator();

-- A staff record must never exist without its user account. The check is
-- deferred to the end of the transaction, so the trusted creation path
-- can insert the staff record first and the account immediately after,
-- while a staff record inserted on its own can never be committed.
create or replace function public.tg_staff_requires_user_account()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- The row may have been removed again inside the same transaction.
  if not exists (select 1 from public.staff s where s.id = new.id) then
    return null;
  end if;

  if not exists (select 1 from public.user_accounts ua where ua.staff_id = new.id) then
    raise exception 'A staff record cannot exist without its user account.'
      using errcode = 'TA005';
  end if;

  return null;
end;
$$;

drop trigger if exists staff_requires_user_account on public.staff;
create constraint trigger staff_requires_user_account
  after insert on public.staff
  deferrable initially deferred
  for each row execute function public.tg_staff_requires_user_account();

-- ---------------------------------------------------------------------
-- 4. Authorisation helpers
--
--    These read the CURRENT database state for the CURRENT auth user.
--    Nothing is ever taken from the browser.
-- ---------------------------------------------------------------------

-- True only when the caller is an authenticated, active, staff user whose
-- staff record currently carries the Council Administrator role.
create or replace function public.is_active_council_administrator()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Council Administrator'
  );
$$;

-- True when the caller is any active staff member.
create or replace function public.is_active_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
  );
$$;

-- Everything the signed-in user is allowed to know about themselves.
-- Returns null when the auth user has no account record at all.
-- `access_granted` is the one flag the application trusts.
create or replace function public.current_staff_context()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'account_id',      ua.id,
    'email',           ua.email,
    'account_type',    ua.account_type,
    'account_status',  ua.account_status,
    'last_login',      ua.last_login,
    'staff_id',        s.id,
    'employee_number', s.employee_number,
    'first_name',      s.first_name,
    'last_name',       s.last_name,
    'full_name',       s.first_name || ' ' || s.last_name,
    'contact_number',  s.contact_number,
    'role_name',       r.role_name,
    'is_council_administrator', coalesce(r.role_name = 'Council Administrator', false),
    'access_granted', (
      ua.account_type = 'staff'
      and ua.account_status = 'active'
      and s.id is not null
      and r.id is not null
    )
  )
  from public.user_accounts ua
  left join public.staff s on s.id = ua.staff_id
  left join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid();
$$;

-- Stamp a successful sign-in. Only ever touches the caller's own row.
create or replace function public.record_login()
returns timestamptz
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  update public.user_accounts
     set last_login = now()
   where auth_user_id = auth.uid()
     and account_type = 'staff'
     and account_status = 'active'
  returning last_login;
$$;

-- The roles a Council Administrator may hand out. The Council
-- Administrator role is deliberately absent.
create or replace function public.assignable_staff_roles()
returns table (id uuid, role_name text, description text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select r.id, r.role_name, r.description
  from public.roles r
  where r.role_name <> 'Council Administrator'
    and public.is_active_council_administrator()
  order by r.role_name;
$$;

-- Every staff account, for the Council Administrator's staff list.
-- Row Level Security would already limit an ordinary staff member to
-- their own row; this refuses them outright and keeps the list in one
-- tested place.
create or replace function public.admin_staff_accounts()
returns table (
  account_id            uuid,
  email                 text,
  account_status        text,
  account_created_at    timestamptz,
  last_login            timestamptz,
  staff_id              uuid,
  employee_number       text,
  first_name            text,
  last_name             text,
  contact_number        text,
  role_name             text,
  invitation_completed  boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the Council Administrator may list staff accounts.'
      using errcode = '42501';
  end if;

  return query
    select ua.id, ua.email, ua.account_status, ua.created_at, ua.last_login,
           s.id, s.employee_number, s.first_name, s.last_name, s.contact_number,
           r.role_name, (u.last_sign_in_at is not null)
    from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    join auth.users u on u.id = ua.auth_user_id
    order by ua.created_at desc;
end;
$$;

-- Counts for the Council Administrator dashboard.
create or replace function public.admin_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_stats jsonb;
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the Council Administrator may read these statistics.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'staff_records',   (select count(*) from public.staff),
    'active_staff',    (select count(*) from public.user_accounts where account_type = 'staff' and account_status = 'active'),
    'deactivated',     (select count(*) from public.user_accounts where account_type = 'staff' and account_status = 'deactivated'),
    'awaiting_setup',  (
                         select count(*)
                         from public.user_accounts ua
                         join auth.users u on u.id = ua.auth_user_id
                         where ua.account_type = 'staff'
                           and u.last_sign_in_at is null
                       ),
    'active_by_role',  coalesce((
                         select jsonb_agg(x order by x->>'role_name')
                         from (
                           select jsonb_build_object('role_name', r.role_name, 'count', count(*)) as x
                           from public.user_accounts ua
                           join public.staff s on s.id = ua.staff_id
                           join public.roles r on r.id = s.role_id
                           where ua.account_status = 'active'
                           group by r.role_name
                         ) t
                       ), '[]'::jsonb)
  ) into v_stats;

  return v_stats;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Trusted write paths
--
--    Both functions below are SECURITY DEFINER and are executable by
--    service_role ONLY. They are called from edge functions that run on
--    the server; the browser can never reach them.
--    Each performs all of its inserts in a single transaction, so a
--    failure can never leave a staff record without its user account.
-- ---------------------------------------------------------------------

-- One-time bootstrap of the first Council Administrator.
-- The auth user must already exist (created by hand in Supabase Auth).
create or replace function public.bootstrap_council_administrator(
  p_auth_user_id    uuid,
  p_employee_number text,
  p_first_name      text,
  p_last_name       text,
  p_email           text,
  p_contact_number  text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_role_id uuid := public.council_administrator_role_id();
  v_staff         public.staff;
  v_account       public.user_accounts;
begin
  if v_admin_role_id is null then
    raise exception 'The Council Administrator role is missing from the roles table.'
      using errcode = 'TA003';
  end if;

  -- Refuse outright if a Council Administrator already exists.
  if exists (select 1 from public.staff s where s.role_id = v_admin_role_id) then
    raise exception 'A Council Administrator already exists. The bootstrap process may only be used once.'
      using errcode = 'TA001';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_auth_user_id) then
    raise exception 'No authentication user exists for the supplied identifier.'
      using errcode = 'TA004';
  end if;

  insert into public.staff (employee_number, first_name, last_name, email, contact_number, role_id)
  values (p_employee_number, p_first_name, p_last_name, p_email, p_contact_number, v_admin_role_id)
  returning * into v_staff;

  insert into public.user_accounts (auth_user_id, email, account_type, account_status, staff_id)
  values (p_auth_user_id, p_email, 'staff', 'active', v_staff.id)
  returning * into v_account;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'account_id',      v_account.id,
    'employee_number', v_staff.employee_number,
    'email',           v_account.email,
    'role_name',       'Council Administrator',
    'account_status',  v_account.account_status
  );
end;
$$;

-- Create a staff record together with its user account, atomically.
-- The Council Administrator role can never be assigned through here.
create or replace function public.create_staff_with_account(
  p_auth_user_id    uuid,
  p_employee_number text,
  p_first_name      text,
  p_last_name       text,
  p_email           text,
  p_contact_number  text,
  p_role_id         uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_role    public.roles;
  v_staff   public.staff;
  v_account public.user_accounts;
begin
  select * into v_role from public.roles where id = p_role_id;
  if not found then
    raise exception 'The selected role does not exist.'
      using errcode = 'TA003';
  end if;

  -- Backend enforcement: a hand-crafted request carrying the Council
  -- Administrator role id is rejected here, not just hidden in the UI.
  if v_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be assigned through staff creation.'
      using errcode = 'TA002';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_auth_user_id) then
    raise exception 'No authentication user exists for the supplied identifier.'
      using errcode = 'TA004';
  end if;

  insert into public.staff (employee_number, first_name, last_name, email, contact_number, role_id)
  values (p_employee_number, p_first_name, p_last_name, p_email, p_contact_number, p_role_id)
  returning * into v_staff;

  insert into public.user_accounts (auth_user_id, email, account_type, account_status, staff_id)
  values (p_auth_user_id, p_email, 'staff', 'active', v_staff.id)
  returning * into v_account;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'account_id',      v_account.id,
    'employee_number', v_staff.employee_number,
    'email',           v_account.email,
    'role_name',       v_role.role_name,
    'account_status',  v_account.account_status
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Row Level Security
--
--    Reads are allowed for the owner of the record and for the active
--    Council Administrator. There is NO insert, update or delete policy
--    on any table: writes are only possible through the trusted
--    service_role paths above, which bypass RLS.
-- ---------------------------------------------------------------------

alter table public.roles         enable row level security;
alter table public.staff         enable row level security;
alter table public.user_accounts enable row level security;

alter table public.roles         force row level security;
alter table public.staff         force row level security;
alter table public.user_accounts force row level security;

drop policy if exists roles_readable_by_active_staff on public.roles;
create policy roles_readable_by_active_staff
  on public.roles for select
  to authenticated
  using (public.is_active_staff());

drop policy if exists staff_select_own_or_administrator on public.staff;
create policy staff_select_own_or_administrator
  on public.staff for select
  to authenticated
  using (
    public.is_active_council_administrator()
    or exists (
      select 1 from public.user_accounts ua
      where ua.staff_id = staff.id
        and ua.auth_user_id = auth.uid()
        and ua.account_status = 'active'
    )
  );

drop policy if exists user_accounts_select_own_or_administrator on public.user_accounts;
create policy user_accounts_select_own_or_administrator
  on public.user_accounts for select
  to authenticated
  using (
    auth_user_id = auth.uid()
    or public.is_active_council_administrator()
  );

-- ---------------------------------------------------------------------
-- 7. Grants
--
--    anon (a signed-out visitor) gets nothing at all.
-- ---------------------------------------------------------------------

revoke all on public.roles         from anon, authenticated;
revoke all on public.staff         from anon, authenticated;
revoke all on public.user_accounts from anon, authenticated;

grant select on public.roles         to authenticated;
grant select on public.staff         to authenticated;
grant select on public.user_accounts to authenticated;

-- The trusted server side. service_role bypasses Row Level Security and
-- is only ever used by the edge functions, never by the browser.
grant all on public.roles         to service_role;
grant all on public.staff         to service_role;
grant all on public.user_accounts to service_role;

-- Functions: default execute-for-everyone is removed, then handed back
-- only to the roles that legitimately need each function.
revoke all on function public.council_administrator_role_id()        from public, anon, authenticated;
revoke all on function public.is_active_council_administrator()      from public, anon, authenticated;
revoke all on function public.is_active_staff()                      from public, anon, authenticated;
revoke all on function public.current_staff_context()                from public, anon, authenticated;
revoke all on function public.record_login()                         from public, anon, authenticated;
revoke all on function public.assignable_staff_roles()               from public, anon, authenticated;
revoke all on function public.admin_dashboard_stats()                from public, anon, authenticated;
revoke all on function public.admin_staff_accounts()                 from public, anon, authenticated;
revoke all on function public.bootstrap_council_administrator(uuid, text, text, text, text, text)        from public, anon, authenticated;
revoke all on function public.create_staff_with_account(uuid, text, text, text, text, text, uuid)        from public, anon, authenticated;

grant execute on function public.is_active_council_administrator() to authenticated;
grant execute on function public.is_active_staff()                 to authenticated;
grant execute on function public.current_staff_context()           to authenticated;
grant execute on function public.record_login()                    to authenticated;
grant execute on function public.assignable_staff_roles()          to authenticated;
grant execute on function public.admin_dashboard_stats()           to authenticated;
grant execute on function public.admin_staff_accounts()            to authenticated;

-- Trusted server-side paths only.
grant execute on function public.bootstrap_council_administrator(uuid, text, text, text, text, text) to service_role;
grant execute on function public.create_staff_with_account(uuid, text, text, text, text, text, uuid) to service_role;


-- ---------------------------------------------------------------------
-- 20260920100000_staff_role_and_status_management.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — Council Administrator staff management
--
--   US-CA02  Change Staff Role
--   US-CA03  Deactivate Staff Account
--            Reactivate Staff Account
--
-- Builds on the foundation migration. It adds no new table: a staff
-- member still holds exactly one role through staff.role_id, and
-- user_accounts.account_status is still the only thing that decides
-- whether a staff member may use the system.
--
-- Every function below is security definer and re-establishes the
-- caller from auth.uid(), so nothing the browser sends can stand in for
-- authorisation. They are safe to call directly; the edge function in
-- front of them is a second layer, not the only one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who deactivated or reactivated an account, when, and why
--
--    Recorded on the staff record itself. No status column is added:
--    account_status remains the single source of truth for access.
-- ---------------------------------------------------------------------

alter table public.staff
  add column if not exists last_deactivated_at           timestamptz,
  add column if not exists last_deactivated_by_staff_id  uuid references public.staff (id),
  add column if not exists last_deactivation_reason      text,
  add column if not exists last_reactivated_at           timestamptz,
  add column if not exists last_reactivated_by_staff_id  uuid references public.staff (id),
  add column if not exists last_reactivation_reason      text;

comment on column public.staff.last_deactivated_at is
  'When this staff member''s account was last deactivated. Not a status — account_status decides access.';
comment on column public.staff.last_reactivated_at is
  'When this staff member''s account was last reactivated. Not a status — account_status decides access.';

-- ---------------------------------------------------------------------
-- 2. Shared guard
--
--    Resolves the caller to the acting Council Administrator's staff id,
--    or refuses. Used by all three operations so the rule is written
--    once: authenticated, linked account, account_type = staff,
--    account_status = active, linked staff record, current role =
--    Council Administrator.
-- ---------------------------------------------------------------------

create or replace function public.acting_council_administrator_staff_id()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid;
begin
  select s.id into v_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Administrator';

  if v_staff_id is null then
    raise exception 'Only the active Council Administrator may manage staff accounts.'
      using errcode = '42501';
  end if;

  return v_staff_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Change Staff Role (US-CA02)
--
--    Updates staff.role_id and nothing else. The staff record, the user
--    account, the Supabase Auth user, the password, the employee number
--    and the email address are all left exactly as they are.
-- ---------------------------------------------------------------------

create or replace function public.change_staff_role(
  p_staff_id    uuid,
  p_new_role_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
  v_staff          public.staff;
  v_account        public.user_accounts;
  v_current_role   public.roles;
  v_new_role       public.roles;
begin
  -- ---- the target -------------------------------------------------
  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA010';
  end if;

  select * into v_current_role from public.roles where id = v_staff.role_id;

  if v_current_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be changed here.'
      using errcode = 'TA011';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found or v_account.account_status <> 'active' then
    raise exception 'That staff member''s account is not active, so their role cannot be changed.'
      using errcode = 'TA012';
  end if;

  -- ---- the requested role -----------------------------------------
  select * into v_new_role from public.roles where id = p_new_role_id;
  if not found then
    raise exception 'The selected role does not exist.' using errcode = 'TA013';
  end if;

  -- Refused here even when the administrator role id is submitted by
  -- hand, exactly as staff creation refuses it.
  if v_new_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be assigned to a staff member.'
      using errcode = 'TA014';
  end if;

  if v_new_role.id = v_staff.role_id then
    raise exception 'That staff member already holds the % role.', v_new_role.role_name
      using errcode = 'TA015';
  end if;

  -- ---- the one change ---------------------------------------------
  update public.staff set role_id = v_new_role.id where id = v_staff.id;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name',       v_staff.first_name || ' ' || v_staff.last_name,
    'email',           v_staff.email,
    'previous_role',   v_current_role.role_name,
    'new_role',        v_new_role.role_name,
    'account_status',  v_account.account_status,
    'changed_by',      v_admin_staff_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Deactivate Staff Account (US-CA03)
--
--    Flips account_status to 'deactivated'. Nothing is deleted: the
--    staff record, the user account, the Supabase Auth user and the
--    staff member's role all stay exactly as they are, so the account
--    can be reactivated later with the same identity.
-- ---------------------------------------------------------------------

create or replace function public.deactivate_staff_account(
  p_staff_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
  v_reason         text := btrim(coalesce(p_reason, ''));
  v_staff          public.staff;
  v_account        public.user_accounts;
  v_role           public.roles;
begin
  if v_reason = '' then
    raise exception 'A reason for deactivating the account is required.' using errcode = 'TA018';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA018';
  end if;

  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA010';
  end if;

  select * into v_role from public.roles where id = v_staff.role_id;
  if v_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator account cannot be deactivated here.'
      using errcode = 'TA011';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found then
    raise exception 'That staff member has no user account.' using errcode = 'TA010';
  end if;
  if v_account.account_status = 'deactivated' then
    raise exception 'That account is already deactivated.' using errcode = 'TA016';
  end if;

  update public.user_accounts
     set account_status = 'deactivated'
   where id = v_account.id;

  -- Who did it, when, and why. The role is deliberately untouched.
  update public.staff
     set last_deactivated_at          = now(),
         last_deactivated_by_staff_id = v_admin_staff_id,
         last_deactivation_reason     = v_reason
   where id = v_staff.id;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name',       v_staff.first_name || ' ' || v_staff.last_name,
    'email',           v_staff.email,
    'role_name',       v_role.role_name,
    'account_status',  'deactivated',
    'reason',          v_reason,
    'deactivated_by',  v_admin_staff_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Reactivate Staff Account
--
--    Flips account_status back to 'active'. Creates nothing: the same
--    staff record, user account, Auth identity, employee number, email
--    address and role are simply usable again.
-- ---------------------------------------------------------------------

create or replace function public.reactivate_staff_account(
  p_staff_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
  v_reason         text := btrim(coalesce(p_reason, ''));
  v_staff          public.staff;
  v_account        public.user_accounts;
  v_role           public.roles;
begin
  if v_reason = '' then
    raise exception 'A reason for reactivating the account is required.' using errcode = 'TA018';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA018';
  end if;

  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA010';
  end if;

  select * into v_role from public.roles where id = v_staff.role_id;
  if v_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator account is not managed here.'
      using errcode = 'TA011';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found then
    raise exception 'That staff member has no user account.' using errcode = 'TA010';
  end if;
  if v_account.account_status = 'active' then
    raise exception 'That account is already active.' using errcode = 'TA017';
  end if;

  update public.user_accounts
     set account_status = 'active'
   where id = v_account.id;

  update public.staff
     set last_reactivated_at          = now(),
         last_reactivated_by_staff_id = v_admin_staff_id,
         last_reactivation_reason     = v_reason
   where id = v_staff.id;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name',       v_staff.first_name || ' ' || v_staff.last_name,
    'email',           v_staff.email,
    'role_name',       v_role.role_name,
    'account_status',  'active',
    'reason',          v_reason,
    'reactivated_by',  v_admin_staff_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. The staff list gains the deactivation history the actions need
-- ---------------------------------------------------------------------

drop function if exists public.admin_staff_accounts();

create function public.admin_staff_accounts()
returns table (
  account_id                uuid,
  email                     text,
  account_status            text,
  account_created_at        timestamptz,
  last_login                timestamptz,
  staff_id                  uuid,
  employee_number           text,
  first_name                text,
  last_name                 text,
  contact_number            text,
  role_id                   uuid,
  role_name                 text,
  invitation_completed      boolean,
  is_council_administrator  boolean,
  last_deactivated_at       timestamptz,
  last_deactivation_reason  text,
  last_deactivated_by       text,
  last_reactivated_at       timestamptz,
  last_reactivation_reason  text,
  last_reactivated_by       text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the Council Administrator may list staff accounts.'
      using errcode = '42501';
  end if;

  return query
    select ua.id, ua.email, ua.account_status, ua.created_at, ua.last_login,
           s.id, s.employee_number, s.first_name, s.last_name, s.contact_number,
           r.id, r.role_name,
           (u.last_sign_in_at is not null),
           (r.role_name = 'Council Administrator'),
           s.last_deactivated_at, s.last_deactivation_reason,
           (select d.first_name || ' ' || d.last_name from public.staff d
             where d.id = s.last_deactivated_by_staff_id),
           s.last_reactivated_at, s.last_reactivation_reason,
           (select a.first_name || ' ' || a.last_name from public.staff a
             where a.id = s.last_reactivated_by_staff_id)
    from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    join auth.users u on u.id = ua.auth_user_id
    order by ua.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Grants
--
--    Each function refuses anyone who is not the active Council
--    Administrator, so granting execute to authenticated is safe: an
--    ordinary staff member calling one directly is turned away by the
--    function itself.
-- ---------------------------------------------------------------------

revoke all on function public.acting_council_administrator_staff_id()           from public, anon, authenticated;
revoke all on function public.change_staff_role(uuid, uuid)                     from public, anon, authenticated;
revoke all on function public.deactivate_staff_account(uuid, text)              from public, anon, authenticated;
revoke all on function public.reactivate_staff_account(uuid, text)              from public, anon, authenticated;
revoke all on function public.admin_staff_accounts()                            from public, anon, authenticated;

grant execute on function public.change_staff_role(uuid, uuid)        to authenticated;
grant execute on function public.deactivate_staff_account(uuid, text) to authenticated;
grant execute on function public.reactivate_staff_account(uuid, text) to authenticated;
grant execute on function public.admin_staff_accounts()               to authenticated;


-- ---------------------------------------------------------------------
-- 20260921090000_village_records.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — village records, and the one-time legacy import
--
-- Adds the tables the village's existing records live in:
--
--     land_sites ──< households ──< residents ──< family_relationships
--          └──< land_allocations >── residents
--
-- A household is identified by its household_code, never by surname:
-- different households legitimately share one. A household's site and a
-- site's allocation are related but separate facts — the head of the
-- household is not necessarily the person the land was allocated to.
--
-- Nothing here builds Registry Clerk or Land Officer functionality. Row
-- Level Security is on with no policies at all, so these tables are
-- reachable only by trusted server-side code until those functions are
-- built and bring their own access rules.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Land sites
-- ---------------------------------------------------------------------

create table if not exists public.land_sites (
  id              uuid primary key default gen_random_uuid(),
  site_code       text not null unique,
  site_type       text not null,
  stand_number    text,
  street_address  text not null,
  village_section text,
  village_name    text,
  site_status     text not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint land_sites_site_code_not_blank      check (btrim(site_code) <> ''),
  constraint land_sites_street_address_not_blank check (btrim(street_address) <> ''),
  constraint land_sites_site_type_allowed        check (site_type in ('residential', 'grazing', 'burial')),
  -- Only the status the legacy records carry. Land application work will
  -- widen this when it needs to.
  constraint land_sites_site_status_allowed      check (site_status in ('allocated'))
);

comment on table public.land_sites is
  'A site in the village. Identified by site_code.';

create index if not exists land_sites_stand_number_idx on public.land_sites (stand_number);

-- ---------------------------------------------------------------------
-- 2. Residents
--
--    resident_code from the import files is deliberately absent: it is
--    an import key, resolved to this table's id while the import runs.
-- ---------------------------------------------------------------------

create table if not exists public.residents (
  id              uuid primary key default gen_random_uuid(),
  id_number       text not null unique,
  first_name      text not null,
  last_name       text not null,
  date_of_birth   date not null,
  gender          text not null,
  contact_number  text,
  email           text,
  resident_status text not null,
  household_id    uuid,                        -- foreign key added below
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint residents_id_number_not_blank  check (btrim(id_number) <> ''),
  constraint residents_first_name_not_blank check (btrim(first_name) <> ''),
  constraint residents_last_name_not_blank  check (btrim(last_name) <> ''),
  constraint residents_gender_not_blank     check (btrim(gender) <> ''),
  constraint residents_status_allowed       check (resident_status in ('active', 'inactive', 'deceased')),
  constraint residents_email_format         check (email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

comment on table public.residents is
  'A person on the village register. A resident belongs to at most one household (household_id).';

create index if not exists residents_last_name_idx    on public.residents (last_name);
create index if not exists residents_household_id_idx on public.residents (household_id);

-- ---------------------------------------------------------------------
-- 3. Households
--
--    Identified by household_code. There is no household_memberships
--    table: membership is residents.household_id, so a resident can
--    only ever be in one household.
-- ---------------------------------------------------------------------

create table if not exists public.households (
  id                  uuid primary key default gen_random_uuid(),
  household_code      text not null unique,
  residential_site_id uuid not null references public.land_sites (id),
  head_resident_id    uuid references public.residents (id),
  household_status    text not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint households_code_not_blank check (btrim(household_code) <> ''),
  constraint households_status_allowed check (household_status in ('active', 'inactive'))
);

comment on table public.households is
  'A household, identified by household_code — never by surname, which households legitimately share.';

create index if not exists households_residential_site_id_idx on public.households (residential_site_id);
create index if not exists households_head_resident_id_idx    on public.households (head_resident_id);

-- One site is the primary residential site of at most one current household.
create unique index if not exists households_one_active_per_site_idx
  on public.households (residential_site_id)
  where household_status = 'active';

-- The membership link, added now that both tables exist.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'residents_household_id_fkey'
  ) then
    alter table public.residents
      add constraint residents_household_id_fkey
      foreign key (household_id) references public.households (id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. The head of a household must live in that household
--
--    Deferred to the end of the transaction, because an import creates
--    the household before the members are linked to it.
-- ---------------------------------------------------------------------

create or replace function public.tg_household_head_belongs_to_household()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.head_resident_id is null then return null; end if;
  -- The row may have been removed again inside the same transaction.
  if not exists (select 1 from public.households h where h.id = new.id) then return null; end if;

  if not exists (
    select 1 from public.residents r
    where r.id = new.head_resident_id and r.household_id = new.id
  ) then
    raise exception 'The head of household % must be a resident of that household.', new.household_code
      using errcode = 'TA021';
  end if;
  return null;
end;
$$;

drop trigger if exists household_head_belongs_to_household on public.households;
create constraint trigger household_head_belongs_to_household
  after insert or update of head_resident_id on public.households
  deferrable initially deferred
  for each row execute function public.tg_household_head_belongs_to_household();

-- The same rule seen from the other side: a head cannot be moved out of
-- the household they head.
create or replace function public.tg_resident_move_keeps_head_valid()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  if not exists (select 1 from public.residents r where r.id = new.id) then return null; end if;

  select h.household_code into v_code
  from public.households h
  where h.head_resident_id = new.id
    and h.id is distinct from new.household_id;

  if found then
    raise exception 'That resident is the head of household % and cannot be moved out of it.', v_code
      using errcode = 'TA021';
  end if;
  return null;
end;
$$;

drop trigger if exists resident_move_keeps_head_valid on public.residents;
create constraint trigger resident_move_keeps_head_valid
  after update of household_id on public.residents
  deferrable initially deferred
  for each row execute function public.tg_resident_move_keeps_head_valid();

-- ---------------------------------------------------------------------
-- 5. Family relationships
-- ---------------------------------------------------------------------

create table if not exists public.family_relationships (
  id                  uuid primary key default gen_random_uuid(),
  resident_id         uuid not null references public.residents (id),
  related_resident_id uuid not null references public.residents (id),
  relationship_type   text not null,
  relationship_status text not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint family_relationships_not_self check (resident_id <> related_resident_id),
  constraint family_relationships_type_allowed check (
    relationship_type in ('parent', 'child', 'spouse', 'sibling',
                          'grandparent', 'grandchild', 'guardian', 'dependant')
  ),
  constraint family_relationships_status_allowed check (relationship_status in ('active', 'inactive')),
  constraint family_relationships_unique unique (resident_id, related_resident_id, relationship_type)
);

comment on table public.family_relationships is
  'How two residents are related, recorded from one resident''s point of view. The reverse is a row of its own.';

create index if not exists family_relationships_resident_id_idx on public.family_relationships (resident_id);
create index if not exists family_relationships_related_resident_id_idx on public.family_relationships (related_resident_id);

-- ---------------------------------------------------------------------
-- 6. Land allocations
--
--    Who a site was allocated to. Separate from the household living
--    there: the head of that household may be someone else entirely.
-- ---------------------------------------------------------------------

create table if not exists public.land_allocations (
  id                   uuid primary key default gen_random_uuid(),
  allocation_reference text not null unique,
  land_site_id         uuid not null references public.land_sites (id),
  resident_id          uuid not null references public.residents (id),
  allocation_date      date not null,
  allocation_status    text not null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint land_allocations_reference_not_blank check (btrim(allocation_reference) <> ''),
  -- Only the status the legacy records carry; historical statuses come
  -- with the allocation workflow later.
  constraint land_allocations_status_allowed check (allocation_status in ('active'))
);

comment on table public.land_allocations is
  'An allocation of a site to a resident. The allocation holder is not necessarily the head of the household on that site.';

create index if not exists land_allocations_land_site_id_idx on public.land_allocations (land_site_id);
create index if not exists land_allocations_resident_id_idx  on public.land_allocations (resident_id);

-- A site can only be under one active allocation at a time.
create unique index if not exists land_allocations_one_active_per_site_idx
  on public.land_allocations (land_site_id)
  where allocation_status = 'active';

-- ---------------------------------------------------------------------
-- 7. Keep updated_at honest
-- ---------------------------------------------------------------------

create or replace function public.tg_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array['land_sites', 'residents', 'households',
                                 'family_relationships', 'land_allocations']
  loop
    execute format('drop trigger if exists touch_updated_at on public.%I', v_table);
    execute format(
      'create trigger touch_updated_at before update on public.%I
       for each row execute function public.tg_touch_updated_at()', v_table);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Row Level Security
--
--    On, with no policies. Nothing the browser holds can read or write
--    these tables. Registry Clerk and Land Officer access will be added
--    with those functions.
-- ---------------------------------------------------------------------

alter table public.land_sites           enable row level security;
alter table public.residents            enable row level security;
alter table public.households           enable row level security;
alter table public.family_relationships enable row level security;
alter table public.land_allocations     enable row level security;

alter table public.land_sites           force row level security;
alter table public.residents            force row level security;
alter table public.households           force row level security;
alter table public.family_relationships force row level security;
alter table public.land_allocations     force row level security;

revoke all on public.land_sites           from anon, authenticated;
revoke all on public.residents            from anon, authenticated;
revoke all on public.households           from anon, authenticated;
revoke all on public.family_relationships from anon, authenticated;
revoke all on public.land_allocations     from anon, authenticated;

grant all on public.land_sites           to service_role;
grant all on public.residents            to service_role;
grant all on public.households           to service_role;
grant all on public.family_relationships to service_role;
grant all on public.land_allocations     to service_role;

-- =====================================================================
-- 9. The one-time legacy import
--
-- The whole village dataset arrives as one JSON document, is checked in
-- full, and is then written in a single transaction. If anything at all
-- is wrong, nothing is written and every problem found is reported at
-- once — so a broken file can be fixed in one pass rather than one
-- error at a time.
--
-- The import keys (RES-0001, R-0001, HH-0001) live only in temporary
-- tables that disappear when the transaction ends. Nothing in the
-- permanent schema stores them.
--
-- Executable by service_role only: there is no page, and no signed-in
-- user, that can reach this.
-- =====================================================================

create or replace function public.is_importable_date(p_value text)
returns boolean
language plpgsql
immutable
as $$
begin
  perform p_value::date;
  return true;
exception when others then
  return false;
end;
$$;

create or replace function public.import_legacy_village_data(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_problems text[] := '{}';
  v_counts   jsonb;
begin
  -- ---- This is a one-time import ------------------------------------
  if exists (select 1 from public.land_sites)
     or exists (select 1 from public.residents)
     or exists (select 1 from public.households)
     or exists (select 1 from public.land_allocations)
     or exists (select 1 from public.family_relationships)
  then
    raise exception 'The village records are not empty. The legacy import is a one-time process and will not run again.'
      using errcode = 'TA022';
  end if;

  -- ---- Stage the files ----------------------------------------------
  --      The ids are generated here, which is what turns each import
  --      code into a real UUID for everything that references it.
  drop table if exists _import_sites;
  create temp table _import_sites on commit drop as
    select gen_random_uuid() as id, row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'land_sites', '[]'::jsonb)) as x(
      site_code text, site_type text, stand_number text, street_address text,
      village_section text, village_name text, site_status text);

  drop table if exists _import_residents;
  create temp table _import_residents on commit drop as
    select gen_random_uuid() as id, row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'residents', '[]'::jsonb)) as x(
      resident_code text, id_number text, first_name text, last_name text,
      date_of_birth text, gender text, contact_number text, email text, resident_status text);

  drop table if exists _import_households;
  create temp table _import_households on commit drop as
    select gen_random_uuid() as id, row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'households', '[]'::jsonb)) as x(
      household_code text, primary_site_code text, head_resident_code text, household_status text);

  drop table if exists _import_memberships;
  create temp table _import_memberships on commit drop as
    select row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'household_memberships', '[]'::jsonb)) as x(
      household_code text, resident_code text);

  drop table if exists _import_relationships;
  create temp table _import_relationships on commit drop as
    select row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'family_relationships', '[]'::jsonb)) as x(
      resident_code text, related_resident_code text,
      relationship_type text, relationship_status text);

  drop table if exists _import_allocations;
  create temp table _import_allocations on commit drop as
    select row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'land_allocations', '[]'::jsonb)) as x(
      allocation_code text, site_code text, allocated_to_resident_code text,
      allocation_date text, allocation_status text);

  -- ---- Land sites ----------------------------------------------------
  v_problems := v_problems || array(
    select format('land_sites line %s: site_code, street_address, site_type and site_status are all required', line)
    from _import_sites
    where coalesce(btrim(site_code), '') = '' or coalesce(btrim(street_address), '') = ''
       or coalesce(btrim(site_type), '') = '' or coalesce(btrim(site_status), '') = '');

  v_problems := v_problems || array(
    select format('land_sites: site_code %L appears %s times', site_code, count(*))
    from _import_sites where site_code is not null group by site_code having count(*) > 1);

  v_problems := v_problems || array(
    select format('land_sites: stand_number %L appears %s times', stand_number, count(*))
    from _import_sites where coalesce(btrim(stand_number), '') <> ''
    group by stand_number having count(*) > 1);

  v_problems := v_problems || array(
    select format('land_sites line %s: site_type %L must be residential, grazing or burial', line, site_type)
    from _import_sites where site_type is not null and site_type not in ('residential', 'grazing', 'burial'));

  v_problems := v_problems || array(
    select format('land_sites line %s: site_status %L is not one this system accepts yet', line, site_status)
    from _import_sites where site_status is not null and site_status not in ('allocated'));

  -- ---- Residents ------------------------------------------------------
  v_problems := v_problems || array(
    select format('residents line %s: resident_code, id_number, first_name, last_name, date_of_birth and gender are all required', line)
    from _import_residents
    where coalesce(btrim(resident_code), '') = '' or coalesce(btrim(id_number), '') = ''
       or coalesce(btrim(first_name), '') = '' or coalesce(btrim(last_name), '') = ''
       or coalesce(btrim(date_of_birth), '') = '' or coalesce(btrim(gender), '') = '');

  v_problems := v_problems || array(
    select format('residents: resident_code %L appears %s times', resident_code, count(*))
    from _import_residents where resident_code is not null group by resident_code having count(*) > 1);

  v_problems := v_problems || array(
    select format('residents: id_number %L appears %s times', id_number, count(*))
    from _import_residents where id_number is not null group by id_number having count(*) > 1);

  v_problems := v_problems || array(
    select format('residents line %s: resident_status %L must be active, inactive or deceased', line, resident_status)
    from _import_residents where resident_status is not null
      and resident_status not in ('active', 'inactive', 'deceased'));

  v_problems := v_problems || array(
    select format('residents line %s: date_of_birth %L is not a valid date', line, date_of_birth)
    from _import_residents where coalesce(btrim(date_of_birth), '') <> ''
      and not public.is_importable_date(date_of_birth));

  v_problems := v_problems || array(
    select format('residents line %s: email %L is not a valid email address', line, email)
    from _import_residents where coalesce(btrim(email), '') <> ''
      and email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

  -- ---- Households ------------------------------------------------------
  v_problems := v_problems || array(
    select format('households line %s: household_code, primary_site_code and household_status are all required', line)
    from _import_households
    where coalesce(btrim(household_code), '') = '' or coalesce(btrim(primary_site_code), '') = ''
       or coalesce(btrim(household_status), '') = '');

  v_problems := v_problems || array(
    select format('households: household_code %L appears %s times', household_code, count(*))
    from _import_households where household_code is not null group by household_code having count(*) > 1);

  v_problems := v_problems || array(
    select format('households line %s: household_status %L must be active or inactive', line, household_status)
    from _import_households where household_status is not null
      and household_status not in ('active', 'inactive'));

  v_problems := v_problems || array(
    select format('households line %s (%s): no land site has site_code %L', h.line, h.household_code, h.primary_site_code)
    from _import_households h
    where h.primary_site_code is not null
      and not exists (select 1 from _import_sites s where s.site_code = h.primary_site_code));

  v_problems := v_problems || array(
    select format('households line %s (%s): no resident has resident_code %L', h.line, h.household_code, h.head_resident_code)
    from _import_households h
    where coalesce(btrim(h.head_resident_code), '') <> ''
      and not exists (select 1 from _import_residents r where r.resident_code = h.head_resident_code));

  v_problems := v_problems || array(
    select format('households: site %L is the primary site of %s current households (%s)',
                  primary_site_code, count(*), string_agg(household_code, ', ' order by household_code))
    from _import_households where household_status = 'active'
    group by primary_site_code having count(*) > 1);

  -- ---- Household membership --------------------------------------------
  v_problems := v_problems || array(
    select format('household_memberships line %s: no household has household_code %L', m.line, m.household_code)
    from _import_memberships m
    where not exists (select 1 from _import_households h where h.household_code = m.household_code));

  v_problems := v_problems || array(
    select format('household_memberships line %s: no resident has resident_code %L', m.line, m.resident_code)
    from _import_memberships m
    where not exists (select 1 from _import_residents r where r.resident_code = m.resident_code));

  v_problems := v_problems || array(
    select format('household_memberships: resident %L is listed in %s households (%s)',
                  resident_code, count(*), string_agg(household_code, ', ' order by household_code))
    from _import_memberships group by resident_code having count(*) > 1);

  -- The head of a household must be one of that household's members.
  v_problems := v_problems || array(
    select format('households line %s (%s): head %L is not a member of that household',
                  h.line, h.household_code, h.head_resident_code)
    from _import_households h
    where coalesce(btrim(h.head_resident_code), '') <> ''
      and exists (select 1 from _import_residents r where r.resident_code = h.head_resident_code)
      and not exists (
        select 1 from _import_memberships m
        where m.household_code = h.household_code and m.resident_code = h.head_resident_code));

  -- ---- Family relationships ---------------------------------------------
  v_problems := v_problems || array(
    select format('family_relationships line %s: no resident has resident_code %L', f.line, f.resident_code)
    from _import_relationships f
    where not exists (select 1 from _import_residents r where r.resident_code = f.resident_code));

  v_problems := v_problems || array(
    select format('family_relationships line %s: no resident has related_resident_code %L', f.line, f.related_resident_code)
    from _import_relationships f
    where not exists (select 1 from _import_residents r where r.resident_code = f.related_resident_code));

  v_problems := v_problems || array(
    select format('family_relationships line %s: %L cannot be related to themselves', line, resident_code)
    from _import_relationships where resident_code = related_resident_code);

  v_problems := v_problems || array(
    select format('family_relationships line %s: relationship_type %L is not one this system recognises', line, relationship_type)
    from _import_relationships where relationship_type is null
       or relationship_type not in ('parent', 'child', 'spouse', 'sibling',
                                    'grandparent', 'grandchild', 'guardian', 'dependant'));

  v_problems := v_problems || array(
    select format('family_relationships line %s: relationship_status %L must be active or inactive', line, relationship_status)
    from _import_relationships where relationship_status is null
       or relationship_status not in ('active', 'inactive'));

  v_problems := v_problems || array(
    select format('family_relationships: %L → %L as %L appears %s times',
                  resident_code, related_resident_code, relationship_type, count(*))
    from _import_relationships
    group by resident_code, related_resident_code, relationship_type having count(*) > 1);

  -- ---- Land allocations ---------------------------------------------------
  v_problems := v_problems || array(
    select format('land_allocations line %s: allocation_code, site_code, allocated_to_resident_code, allocation_date and allocation_status are all required', line)
    from _import_allocations
    where coalesce(btrim(allocation_code), '') = '' or coalesce(btrim(site_code), '') = ''
       or coalesce(btrim(allocated_to_resident_code), '') = ''
       or coalesce(btrim(allocation_date), '') = '' or coalesce(btrim(allocation_status), '') = '');

  v_problems := v_problems || array(
    select format('land_allocations: allocation_code %L appears %s times', allocation_code, count(*))
    from _import_allocations where allocation_code is not null
    group by allocation_code having count(*) > 1);

  v_problems := v_problems || array(
    select format('land_allocations line %s (%s): no land site has site_code %L', a.line, a.allocation_code, a.site_code)
    from _import_allocations a
    where not exists (select 1 from _import_sites s where s.site_code = a.site_code));

  v_problems := v_problems || array(
    select format('land_allocations line %s (%s): no resident has resident_code %L',
                  a.line, a.allocation_code, a.allocated_to_resident_code)
    from _import_allocations a
    where not exists (select 1 from _import_residents r where r.resident_code = a.allocated_to_resident_code));

  v_problems := v_problems || array(
    select format('land_allocations line %s: allocation_date %L is not a valid date', line, allocation_date)
    from _import_allocations where coalesce(btrim(allocation_date), '') <> ''
      and not public.is_importable_date(allocation_date));

  v_problems := v_problems || array(
    select format('land_allocations line %s: allocation_status %L is not one this system accepts yet', line, allocation_status)
    from _import_allocations where allocation_status is not null and allocation_status not in ('active'));

  v_problems := v_problems || array(
    select format('land_allocations: site %L has %s active allocations (%s)',
                  site_code, count(*), string_agg(allocation_code, ', ' order by allocation_code))
    from _import_allocations where allocation_status = 'active'
    group by site_code having count(*) > 1);

  -- ---- Stop here if anything is wrong -------------------------------------
  if array_length(v_problems, 1) > 0 then
    raise exception E'The import was stopped and nothing was written. % problem(s) found:\n%',
      array_length(v_problems, 1),
      array_to_string((select array_agg(p) from unnest(v_problems) with ordinality as t(p, n) where n <= 50), E'\n')
      using errcode = 'TA020';
  end if;

  -- ---- Write, in dependency order ------------------------------------------
  insert into public.land_sites (id, site_code, site_type, stand_number, street_address,
                                 village_section, village_name, site_status)
  select id, btrim(site_code), site_type, nullif(btrim(stand_number), ''), btrim(street_address),
         nullif(btrim(village_section), ''), nullif(btrim(village_name), ''), site_status
  from _import_sites;

  insert into public.residents (id, id_number, first_name, last_name, date_of_birth, gender,
                                contact_number, email, resident_status)
  select id, btrim(id_number), btrim(first_name), btrim(last_name), date_of_birth::date, btrim(gender),
         nullif(btrim(contact_number), ''), lower(nullif(btrim(email), '')), resident_status
  from _import_residents;

  insert into public.households (id, household_code, residential_site_id, head_resident_id, household_status)
  select h.id, btrim(h.household_code), s.id, r.id, h.household_status
  from _import_households h
  join _import_sites s on s.site_code = h.primary_site_code
  left join _import_residents r on r.resident_code = h.head_resident_code;

  -- Membership is a column on the resident, not a table of its own.
  update public.residents r
     set household_id = h.id
  from _import_memberships m
  join _import_residents ir on ir.resident_code = m.resident_code
  join _import_households h on h.household_code = m.household_code
  where r.id = ir.id;

  insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
  select a.id, b.id, f.relationship_type, f.relationship_status
  from _import_relationships f
  join _import_residents a on a.resident_code = f.resident_code
  join _import_residents b on b.resident_code = f.related_resident_code;

  insert into public.land_allocations (allocation_reference, land_site_id, resident_id,
                                       allocation_date, allocation_status)
  select btrim(a.allocation_code), s.id, r.id, a.allocation_date::date, a.allocation_status
  from _import_allocations a
  join _import_sites s on s.site_code = a.site_code
  join _import_residents r on r.resident_code = a.allocated_to_resident_code;

  select jsonb_build_object(
    'land_sites',                 (select count(*) from public.land_sites),
    'residents',                  (select count(*) from public.residents),
    'households',                 (select count(*) from public.households),
    'residents_linked_to_household', (select count(*) from public.residents where household_id is not null),
    'family_relationships',       (select count(*) from public.family_relationships),
    'land_allocations',           (select count(*) from public.land_allocations)
  ) into v_counts;

  return v_counts;
end;
$$;

-- Trusted server-side only. No signed-in user can reach this.
revoke all on function public.import_legacy_village_data(jsonb) from public, anon, authenticated;
revoke all on function public.is_importable_date(text)          from public, anon, authenticated;
grant execute on function public.import_legacy_village_data(jsonb) to service_role;


-- ---------------------------------------------------------------------
-- 20260922090000_registry_clerk.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — Registry Clerk functions
--
-- Reading and maintaining the village register: residents, households,
-- who lives where, who heads a household, and how people are related.
--
-- No new table. Household membership stays residents.household_id, a
-- household is still identified by household_code, and family lineage
-- still comes from family_relationships alone.
--
-- Reads go through Row Level Security. Writes go through the functions
-- below and nowhere else: there is no insert, update or delete policy
-- on any village table, so a Registry Clerk cannot write a row the
-- rules here did not agree to.
--
-- Every function re-establishes the caller from auth.uid(). Nothing the
-- browser sends stands in for authorisation.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who is a Registry Clerk
-- ---------------------------------------------------------------------

create or replace function public.is_active_registry_clerk()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Registry Clerk'
  );
$$;

-- Raises unless the caller is one. Used by every function below, so the
-- rule is written once.
create or replace function public.require_registry_clerk()
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_active_registry_clerk() then
    raise exception 'Only an active Registry Clerk may use the village register.'
      using errcode = '42501';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Reading the register
--
--    A Registry Clerk may read the whole register. Land sites and land
--    allocations are readable too, because a household is meaningless
--    without its address and the clerk needs to see who holds the
--    allocation — but there is no write policy on either, so they
--    remain the Land Officer's to change.
-- ---------------------------------------------------------------------

drop policy if exists residents_readable_by_registry_clerk on public.residents;
create policy residents_readable_by_registry_clerk
  on public.residents for select to authenticated
  using (public.is_active_registry_clerk());

drop policy if exists households_readable_by_registry_clerk on public.households;
create policy households_readable_by_registry_clerk
  on public.households for select to authenticated
  using (public.is_active_registry_clerk());

drop policy if exists family_relationships_readable_by_registry_clerk on public.family_relationships;
create policy family_relationships_readable_by_registry_clerk
  on public.family_relationships for select to authenticated
  using (public.is_active_registry_clerk());

drop policy if exists land_sites_readable_by_registry_clerk on public.land_sites;
create policy land_sites_readable_by_registry_clerk
  on public.land_sites for select to authenticated
  using (public.is_active_registry_clerk());

drop policy if exists land_allocations_readable_by_registry_clerk on public.land_allocations;
create policy land_allocations_readable_by_registry_clerk
  on public.land_allocations for select to authenticated
  using (public.is_active_registry_clerk());

grant select on public.residents            to authenticated;
grant select on public.households           to authenticated;
grant select on public.family_relationships to authenticated;
grant select on public.land_sites           to authenticated;
grant select on public.land_allocations     to authenticated;

-- ---------------------------------------------------------------------
-- 3. Searching and viewing
-- ---------------------------------------------------------------------

-- Anything typed into a search box is text to match, never a pattern.
create or replace function public.like_pattern(p_search text)
returns text
language sql
immutable
as $$
  select '%' || replace(replace(replace(coalesce(btrim(p_search), ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
$$;

create or replace function public.registry_search_residents(p_search text default null)
returns table (
  resident_id     uuid,
  id_number       text,
  first_name      text,
  last_name       text,
  full_name       text,
  date_of_birth   date,
  gender          text,
  contact_number  text,
  email           text,
  resident_status text,
  household_code  text,
  site_code       text,
  street_address  text,
  is_household_head boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_pattern text := public.like_pattern(p_search);
  v_empty   boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.require_registry_clerk();

  return query
    select r.id, r.id_number, r.first_name, r.last_name,
           r.first_name || ' ' || r.last_name,
           r.date_of_birth, r.gender, r.contact_number, r.email, r.resident_status,
           h.household_code, s.site_code, s.street_address,
           (h.head_resident_id = r.id)
    from public.residents r
    left join public.households h on h.id = r.household_id
    left join public.land_sites s on s.id = h.residential_site_id
    where v_empty
       or r.id_number ilike v_pattern
       or r.first_name ilike v_pattern
       or r.last_name ilike v_pattern
       or (r.first_name || ' ' || r.last_name) ilike v_pattern
       or coalesce(r.contact_number, '') ilike v_pattern
       or coalesce(r.email, '') ilike v_pattern
       or coalesce(h.household_code, '') ilike v_pattern
       or coalesce(s.site_code, '') ilike v_pattern
       or coalesce(s.street_address, '') ilike v_pattern
    order by r.last_name, r.first_name;
end;
$$;

create or replace function public.registry_resident_record(p_resident_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_record jsonb;
begin
  perform public.require_registry_clerk();

  select jsonb_build_object(
    'resident_id',     r.id,
    'id_number',       r.id_number,
    'first_name',      r.first_name,
    'last_name',       r.last_name,
    'full_name',       r.first_name || ' ' || r.last_name,
    'date_of_birth',   r.date_of_birth,
    'gender',          r.gender,
    'contact_number',  r.contact_number,
    'email',           r.email,
    'resident_status', r.resident_status,
    'household_id',    h.id,
    'household_code',  h.household_code,
    'household_status', h.household_status,
    'is_household_head', coalesce(h.head_resident_id = r.id, false),
    'household_head',  (select head.first_name || ' ' || head.last_name
                          from public.residents head where head.id = h.head_resident_id),
    'site_code',       s.site_code,
    'stand_number',    s.stand_number,
    'street_address',  s.street_address,
    'village_section', s.village_section,
    'village_name',    s.village_name,
    'relationship_count', (select count(*) from public.family_relationships f
                            where f.resident_id = r.id and f.relationship_status = 'active')
  )
  into v_record
  from public.residents r
  left join public.households h on h.id = r.household_id
  left join public.land_sites s on s.id = h.residential_site_id
  where r.id = p_resident_id;

  if v_record is null then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;
  return v_record;
end;
$$;

-- Family lineage, straight from family_relationships. There is no tree
-- table: the relationships are the tree.
create or replace function public.registry_family_lineage(p_resident_id uuid)
returns table (
  relationship_id     uuid,
  relationship_type   text,
  relationship_status text,
  related_resident_id uuid,
  related_full_name   text,
  related_id_number   text,
  related_status      text,
  related_household_code text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  if not exists (select 1 from public.residents where id = p_resident_id) then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  return query
    select f.id, f.relationship_type, f.relationship_status,
           other.id, other.first_name || ' ' || other.last_name,
           other.id_number, other.resident_status, h.household_code
    from public.family_relationships f
    join public.residents other on other.id = f.related_resident_id
    left join public.households h on h.id = other.household_id
    where f.resident_id = p_resident_id
    -- A row says "this resident is the <type> of the other person", so
    -- the reading order is the inverse: the people they are the child
    -- of are their parents, and come first.
    order by
      case f.relationship_type
        when 'child' then 1 when 'parent' then 2 when 'spouse' then 3
        when 'sibling' then 4 when 'grandchild' then 5 when 'grandparent' then 6
        when 'dependant' then 7 else 8 end,
      other.last_name, other.first_name;
end;
$$;

create or replace function public.registry_search_households(p_search text default null)
returns table (
  household_id     uuid,
  household_code   text,
  household_status text,
  site_code        text,
  stand_number     text,
  street_address   text,
  village_section  text,
  village_name     text,
  head_full_name   text,
  member_count     bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_pattern text := public.like_pattern(p_search);
  v_empty   boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.require_registry_clerk();

  return query
    select h.id, h.household_code, h.household_status,
           s.site_code, s.stand_number, s.street_address, s.village_section, s.village_name,
           (select head.first_name || ' ' || head.last_name
              from public.residents head where head.id = h.head_resident_id),
           (select count(*) from public.residents m where m.household_id = h.id)
    from public.households h
    join public.land_sites s on s.id = h.residential_site_id
    where v_empty
       or h.household_code ilike v_pattern
       or s.site_code ilike v_pattern
       or coalesce(s.stand_number, '') ilike v_pattern
       or s.street_address ilike v_pattern
       or coalesce(s.village_section, '') ilike v_pattern
       or exists (select 1 from public.residents m
                   where m.household_id = h.id
                     and ((m.first_name || ' ' || m.last_name) ilike v_pattern
                          or m.id_number ilike v_pattern))
    order by h.household_code;
end;
$$;

-- A household in full, including who currently holds the land
-- allocation for its site — which is often not the head of household.
create or replace function public.registry_household_record(p_household_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_record jsonb;
begin
  perform public.require_registry_clerk();

  select jsonb_build_object(
    'household_id',     h.id,
    'household_code',   h.household_code,
    'household_status', h.household_status,
    'site_id',          s.id,
    'site_code',        s.site_code,
    'site_type',        s.site_type,
    'stand_number',     s.stand_number,
    'street_address',   s.street_address,
    'village_section',  s.village_section,
    'village_name',     s.village_name,
    'head_resident_id', h.head_resident_id,
    'head_full_name',   (select head.first_name || ' ' || head.last_name
                           from public.residents head where head.id = h.head_resident_id),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'resident_id',   m.id,
               'full_name',     m.first_name || ' ' || m.last_name,
               'id_number',     m.id_number,
               'date_of_birth', m.date_of_birth,
               'gender',        m.gender,
               'resident_status', m.resident_status,
               'is_head',       (h.head_resident_id = m.id))
             order by (h.head_resident_id = m.id) desc, m.date_of_birth)
      from public.residents m where m.household_id = h.id), '[]'::jsonb),
    -- Context only. Land allocations belong to the Land Officer.
    'allocation', (
      select jsonb_build_object(
               'allocation_reference', a.allocation_reference,
               'allocation_date',      a.allocation_date,
               'allocation_status',    a.allocation_status,
               'holder_full_name',     holder.first_name || ' ' || holder.last_name,
               'holder_is_household_head', (a.resident_id = h.head_resident_id))
      from public.land_allocations a
      join public.residents holder on holder.id = a.resident_id
      where a.land_site_id = s.id and a.allocation_status = 'active'
      limit 1)
  )
  into v_record
  from public.households h
  join public.land_sites s on s.id = h.residential_site_id
  where h.id = p_household_id;

  if v_record is null then
    raise exception 'That household could not be found.' using errcode = 'TA032';
  end if;
  return v_record;
end;
$$;

create or replace function public.registry_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  return jsonb_build_object(
    'residents',              (select count(*) from public.residents),
    'active_residents',       (select count(*) from public.residents where resident_status = 'active'),
    'households',             (select count(*) from public.households),
    'residents_without_household', (select count(*) from public.residents where household_id is null),
    'households_without_head',(select count(*) from public.households where head_resident_id is null),
    'family_relationships',   (select count(*) from public.family_relationships where relationship_status = 'active')
  );
end;
$$;

-- Residential sites a new household could be placed on: residential,
-- and not already the site of a current household.
create or replace function public.registry_available_residential_sites()
returns table (site_id uuid, site_code text, stand_number text, street_address text,
               village_section text, village_name text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  return query
    select s.id, s.site_code, s.stand_number, s.street_address, s.village_section, s.village_name
    from public.land_sites s
    where s.site_type = 'residential'
      and not exists (select 1 from public.households h
                       where h.residential_site_id = s.id and h.household_status = 'active')
    order by s.site_code;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Creating and updating a resident record
--
--    This is the village's record of a person. It is not a sign-in
--    account: no Supabase Auth user and no user_accounts row is created
--    here, and resident accounts are not built yet.
-- ---------------------------------------------------------------------

create or replace function public.registry_create_resident(
  p_id_number       text,
  p_first_name      text,
  p_last_name       text,
  p_date_of_birth   text,
  p_gender          text,
  p_resident_status text default 'active',
  p_contact_number  text default null,
  p_email           text default null,
  p_household_id    uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_id_number text := btrim(coalesce(p_id_number, ''));
  v_resident  public.residents;
begin
  perform public.require_registry_clerk();

  if v_id_number = '' or btrim(coalesce(p_first_name, '')) = ''
     or btrim(coalesce(p_last_name, '')) = '' or btrim(coalesce(p_gender, '')) = ''
     or btrim(coalesce(p_date_of_birth, '')) = '' then
    raise exception 'Identity number, first name, surname, date of birth and gender are all required.'
      using errcode = 'TA034';
  end if;

  if not public.is_importable_date(p_date_of_birth) then
    raise exception 'That date of birth is not a valid date.' using errcode = 'TA034';
  end if;

  if p_resident_status not in ('active', 'inactive', 'deceased') then
    raise exception 'Resident status must be active, inactive or deceased.' using errcode = 'TA034';
  end if;

  if exists (select 1 from public.residents r where lower(r.id_number) = lower(v_id_number)) then
    raise exception 'A resident with identity number % is already on the register.', v_id_number
      using errcode = 'TA033';
  end if;

  if p_household_id is not null
     and not exists (select 1 from public.households h where h.id = p_household_id) then
    raise exception 'That household could not be found.' using errcode = 'TA032';
  end if;

  insert into public.residents (id_number, first_name, last_name, date_of_birth, gender,
                                contact_number, email, resident_status, household_id)
  values (v_id_number, btrim(p_first_name), btrim(p_last_name), p_date_of_birth::date,
          btrim(p_gender), nullif(btrim(coalesce(p_contact_number, '')), ''),
          lower(nullif(btrim(coalesce(p_email, '')), '')), p_resident_status, p_household_id)
  returning * into v_resident;

  return jsonb_build_object(
    'resident_id', v_resident.id,
    'id_number',   v_resident.id_number,
    'full_name',   v_resident.first_name || ' ' || v_resident.last_name,
    'resident_status', v_resident.resident_status);
end;
$$;

-- Updates the record in place. The resident's id never changes, and
-- household membership is deliberately not touched here — that is
-- registry_link_resident_to_household()'s job, which has its own rules.
create or replace function public.registry_update_resident(
  p_resident_id     uuid,
  p_id_number       text,
  p_first_name      text,
  p_last_name       text,
  p_date_of_birth   text,
  p_gender          text,
  p_resident_status text,
  p_contact_number  text default null,
  p_email           text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_id_number text := btrim(coalesce(p_id_number, ''));
  v_resident  public.residents;
begin
  perform public.require_registry_clerk();

  select * into v_resident from public.residents where id = p_resident_id for update;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  if v_id_number = '' or btrim(coalesce(p_first_name, '')) = ''
     or btrim(coalesce(p_last_name, '')) = '' or btrim(coalesce(p_gender, '')) = ''
     or btrim(coalesce(p_date_of_birth, '')) = '' then
    raise exception 'Identity number, first name, surname, date of birth and gender are all required.'
      using errcode = 'TA034';
  end if;

  if not public.is_importable_date(p_date_of_birth) then
    raise exception 'That date of birth is not a valid date.' using errcode = 'TA034';
  end if;

  if p_resident_status not in ('active', 'inactive', 'deceased') then
    raise exception 'Resident status must be active, inactive or deceased.' using errcode = 'TA034';
  end if;

  if exists (select 1 from public.residents r
              where lower(r.id_number) = lower(v_id_number) and r.id <> p_resident_id) then
    raise exception 'A resident with identity number % is already on the register.', v_id_number
      using errcode = 'TA033';
  end if;

  update public.residents
     set id_number       = v_id_number,
         first_name      = btrim(p_first_name),
         last_name       = btrim(p_last_name),
         date_of_birth   = p_date_of_birth::date,
         gender          = btrim(p_gender),
         contact_number  = nullif(btrim(coalesce(p_contact_number, '')), ''),
         email           = lower(nullif(btrim(coalesce(p_email, '')), '')),
         resident_status = p_resident_status
   where id = p_resident_id
  returning * into v_resident;

  return jsonb_build_object(
    'resident_id', v_resident.id,
    'id_number',   v_resident.id_number,
    'full_name',   v_resident.first_name || ' ' || v_resident.last_name,
    'resident_status', v_resident.resident_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Households
-- ---------------------------------------------------------------------

-- The next free HH-#### code, worked out from what is actually in the
-- database rather than assumed.
create or replace function public.registry_next_household_code()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_highest int;
begin
  perform public.require_registry_clerk();

  select coalesce(max((regexp_match(household_code, '^HH-(\d+)$'))[1]::int), 0)
    into v_highest
  from public.households
  where household_code ~ '^HH-\d+$';

  return 'HH-' || lpad((v_highest + 1)::text, 4, '0');
end;
$$;

create or replace function public.registry_create_household(
  p_household_code   text,
  p_site_id          uuid,
  p_household_status text default 'active'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_code      text := btrim(coalesce(p_household_code, ''));
  v_site      public.land_sites;
  v_household public.households;
begin
  perform public.require_registry_clerk();

  if v_code = '' then
    raise exception 'A household code is required.' using errcode = 'TA034';
  end if;
  if p_household_status not in ('active', 'inactive') then
    raise exception 'Household status must be active or inactive.' using errcode = 'TA034';
  end if;
  if exists (select 1 from public.households h where upper(h.household_code) = upper(v_code)) then
    raise exception 'Household code % is already in use.', v_code using errcode = 'TA035';
  end if;

  select * into v_site from public.land_sites where id = p_site_id;
  if not found then
    raise exception 'That land site could not be found. A Registry Clerk cannot create land sites.'
      using errcode = 'TA036';
  end if;
  if v_site.site_type <> 'residential' then
    raise exception 'Site % is a % site, so a household cannot live on it.', v_site.site_code, v_site.site_type
      using errcode = 'TA036';
  end if;
  if p_household_status = 'active'
     and exists (select 1 from public.households h
                  where h.residential_site_id = v_site.id and h.household_status = 'active') then
    raise exception 'Site % is already the residential site of another current household.', v_site.site_code
      using errcode = 'TA037';
  end if;

  -- The head is designated once the household has members.
  insert into public.households (household_code, residential_site_id, household_status)
  values (v_code, v_site.id, p_household_status)
  returning * into v_household;

  return jsonb_build_object(
    'household_id',   v_household.id,
    'household_code', v_household.household_code,
    'household_status', v_household.household_status,
    'site_code',      v_site.site_code,
    'street_address', v_site.street_address);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Household membership
--
--    A resident belongs to one household, so linking them to a new one
--    moves them. That is never done silently: moving someone who
--    already has a household has to be confirmed.
-- ---------------------------------------------------------------------

create or replace function public.registry_link_resident_to_household(
  p_resident_id  uuid,
  p_household_id uuid,
  p_confirm_reassignment boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_resident  public.residents;
  v_household public.households;
  v_previous  public.households;
begin
  perform public.require_registry_clerk();

  select * into v_resident from public.residents where id = p_resident_id for update;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  select * into v_household from public.households where id = p_household_id;
  if not found then
    raise exception 'That household could not be found.' using errcode = 'TA032';
  end if;
  if v_household.household_status <> 'active' then
    raise exception 'Household % is not current, so residents cannot be linked to it.', v_household.household_code
      using errcode = 'TA032';
  end if;

  if v_resident.household_id = v_household.id then
    raise exception '% is already a member of household %.',
      v_resident.first_name || ' ' || v_resident.last_name, v_household.household_code
      using errcode = 'TA038';
  end if;

  if v_resident.household_id is not null then
    select * into v_previous from public.households where id = v_resident.household_id;

    if not coalesce(p_confirm_reassignment, false) then
      raise exception '% already belongs to household %. Confirm the move before it is made.',
        v_resident.first_name || ' ' || v_resident.last_name, v_previous.household_code
        using errcode = 'TA038';
    end if;

    -- Moving the head out would leave that household headed by someone
    -- who no longer lives there.
    if v_previous.head_resident_id = v_resident.id then
      raise exception '% is the head of household %. Designate another head before moving them.',
        v_resident.first_name || ' ' || v_resident.last_name, v_previous.household_code
        using errcode = 'TA045';
    end if;
  end if;

  update public.residents set household_id = v_household.id where id = v_resident.id;

  return jsonb_build_object(
    'resident_id',    v_resident.id,
    'full_name',      v_resident.first_name || ' ' || v_resident.last_name,
    'household_id',   v_household.id,
    'household_code', v_household.household_code,
    'moved_from',     v_previous.household_code);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Head of household
-- ---------------------------------------------------------------------

create or replace function public.registry_designate_household_head(
  p_household_id uuid,
  p_resident_id  uuid,
  p_confirm_replacement boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_household public.households;
  v_resident  public.residents;
  v_current   public.residents;
begin
  perform public.require_registry_clerk();

  select * into v_household from public.households where id = p_household_id for update;
  if not found then
    raise exception 'That household could not be found.' using errcode = 'TA032';
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  -- The head must live in the household they head.
  if v_resident.household_id is distinct from v_household.id then
    raise exception '% is not a member of household %, so cannot be its head.',
      v_resident.first_name || ' ' || v_resident.last_name, v_household.household_code
      using errcode = 'TA039';
  end if;

  if v_resident.resident_status = 'deceased' then
    raise exception '% is recorded as deceased and cannot be made head of a household.',
      v_resident.first_name || ' ' || v_resident.last_name
      using errcode = 'TA040';
  end if;

  if v_household.head_resident_id = v_resident.id then
    raise exception '% already heads household %.',
      v_resident.first_name || ' ' || v_resident.last_name, v_household.household_code
      using errcode = 'TA041';
  end if;

  if v_household.head_resident_id is not null then
    select * into v_current from public.residents where id = v_household.head_resident_id;
    if not coalesce(p_confirm_replacement, false) then
      raise exception 'Household % is currently headed by %. Confirm the replacement before it is made.',
        v_household.household_code, v_current.first_name || ' ' || v_current.last_name
        using errcode = 'TA041';
    end if;
  end if;

  -- One household, one head: this replaces, it never adds.
  update public.households set head_resident_id = v_resident.id where id = v_household.id;

  return jsonb_build_object(
    'household_id',   v_household.id,
    'household_code', v_household.household_code,
    'head_resident_id', v_resident.id,
    'head_full_name', v_resident.first_name || ' ' || v_resident.last_name,
    'replaced',       (v_current.first_name || ' ' || v_current.last_name));
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Family relationships, and their inverses
--
--    Recording that A is B's parent also records that B is A's child.
--    Relatives need not share a household.
-- ---------------------------------------------------------------------

create or replace function public.inverse_relationship_type(p_type text)
returns text
language sql
immutable
as $$
  select case p_type
    when 'parent'      then 'child'
    when 'child'       then 'parent'
    when 'grandparent' then 'grandchild'
    when 'grandchild'  then 'grandparent'
    when 'guardian'    then 'dependant'
    when 'dependant'   then 'guardian'
    when 'spouse'      then 'spouse'
    when 'sibling'     then 'sibling'
  end;
$$;

create or replace function public.registry_record_family_relationship(
  p_resident_id         uuid,
  p_related_resident_id uuid,
  p_relationship_type   text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_resident public.residents;
  v_related  public.residents;
  v_inverse  text := public.inverse_relationship_type(p_relationship_type);
  v_added    int := 0;
  v_inverse_added int := 0;
begin
  perform public.require_registry_clerk();

  if v_inverse is null then
    raise exception 'Relationship type % is not one this system recognises.', coalesce(p_relationship_type, '(none)')
      using errcode = 'TA044';
  end if;

  if p_resident_id = p_related_resident_id then
    raise exception 'A resident cannot be related to themselves.' using errcode = 'TA042';
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  select * into v_related from public.residents where id = p_related_resident_id;
  if not found then
    raise exception 'The related resident could not be found.' using errcode = 'TA031';
  end if;

  if exists (select 1 from public.family_relationships f
              where f.resident_id = p_resident_id
                and f.related_resident_id = p_related_resident_id
                and f.relationship_type = p_relationship_type) then
    raise exception '% is already recorded as the % of %.',
      v_resident.first_name || ' ' || v_resident.last_name, p_relationship_type,
      v_related.first_name || ' ' || v_related.last_name
      using errcode = 'TA043';
  end if;

  insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
  values (p_resident_id, p_related_resident_id, p_relationship_type, 'active');
  get diagnostics v_added = row_count;

  -- The other side of the same fact. Already there (as in the imported
  -- data) means nothing to do.
  insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
  values (p_related_resident_id, p_resident_id, v_inverse, 'active')
  on conflict (resident_id, related_resident_id, relationship_type) do nothing;
  get diagnostics v_inverse_added = row_count;

  return jsonb_build_object(
    'resident',          v_resident.first_name || ' ' || v_resident.last_name,
    'related_resident',  v_related.first_name || ' ' || v_related.last_name,
    'relationship_type', p_relationship_type,
    'inverse_type',      v_inverse,
    'recorded',          v_added,
    'inverse_recorded',  v_inverse_added);
end;
$$;

-- Relationships are never deleted. A relationship that is no longer
-- current is marked inactive, and its inverse follows it.
create or replace function public.registry_set_relationship_status(
  p_relationship_id uuid,
  p_status          text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_relationship public.family_relationships;
begin
  perform public.require_registry_clerk();

  if p_status not in ('active', 'inactive') then
    raise exception 'A relationship status must be active or inactive.' using errcode = 'TA034';
  end if;

  select * into v_relationship from public.family_relationships where id = p_relationship_id for update;
  if not found then
    raise exception 'That relationship could not be found.' using errcode = 'TA031';
  end if;

  update public.family_relationships set relationship_status = p_status where id = v_relationship.id;

  update public.family_relationships
     set relationship_status = p_status
   where resident_id = v_relationship.related_resident_id
     and related_resident_id = v_relationship.resident_id
     and relationship_type = public.inverse_relationship_type(v_relationship.relationship_type);

  return jsonb_build_object('relationship_id', v_relationship.id, 'relationship_status', p_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Grants
--
--    Each function turns away anyone who is not an active Registry
--    Clerk, so granting execute to authenticated is safe.
-- ---------------------------------------------------------------------

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.is_active_registry_clerk()',
    'public.require_registry_clerk()',
    'public.like_pattern(text)',
    'public.inverse_relationship_type(text)',
    'public.registry_search_residents(text)',
    'public.registry_resident_record(uuid)',
    'public.registry_family_lineage(uuid)',
    'public.registry_search_households(text)',
    'public.registry_household_record(uuid)',
    'public.registry_dashboard_stats()',
    'public.registry_available_residential_sites()',
    'public.registry_next_household_code()',
    'public.registry_create_resident(text, text, text, text, text, text, text, text, uuid)',
    'public.registry_update_resident(uuid, text, text, text, text, text, text, text, text)',
    'public.registry_create_household(text, uuid, text)',
    'public.registry_link_resident_to_household(uuid, uuid, boolean)',
    'public.registry_designate_household_head(uuid, uuid, boolean)',
    'public.registry_record_family_relationship(uuid, uuid, text)',
    'public.registry_set_relationship_status(uuid, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

-- These two are internal guards; nothing should call them directly.
revoke execute on function public.require_registry_clerk() from authenticated;


-- ---------------------------------------------------------------------
-- 20260923090000_relationship_history.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — family relationships that have a history
--
-- Some relationships are permanent lineage and some are episodes in a
-- life. A father who dies is still his child's father; a marriage can
-- end, and the same two people can marry again years later.
--
--   PERMANENT   parent ↔ child, sibling ↔ sibling,
--               grandparent ↔ grandchild
--               These are never ended through the application.
--
--   TIME-BASED  spouse ↔ spouse, guardian ↔ dependant
--               These begin, end, and may begin again as a NEW episode.
--               The earlier episode is kept exactly as it was.
--
-- The 200 imported relationships are untouched: they keep their rows,
-- their types and their active status, and simply have no dates,
-- because the historical dates are not known.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. When a relationship began and ended
-- ---------------------------------------------------------------------

alter table public.family_relationships
  add column if not exists relationship_started_at date,
  add column if not exists relationship_ended_at   date;

comment on column public.family_relationships.relationship_started_at is
  'When this episode began. Null on the imported relationships, whose dates are not known.';
comment on column public.family_relationships.relationship_ended_at is
  'When this episode ended. Only ever set on an inactive, time-based relationship.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'family_relationships_dates_ordered') then
    alter table public.family_relationships
      add constraint family_relationships_dates_ordered check (
        relationship_ended_at is null
        or relationship_started_at is null
        or relationship_ended_at >= relationship_started_at
      );
  end if;

  -- A relationship that is still current cannot have ended.
  if not exists (select 1 from pg_constraint where conname = 'family_relationships_active_has_not_ended') then
    alter table public.family_relationships
      add constraint family_relationships_active_has_not_ended check (
        relationship_status <> 'active' or relationship_ended_at is null
      );
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Uniqueness now applies to CURRENT relationships only
--
--    The old rule forbade the same triple outright, which would have
--    made a remarriage impossible to record. What must never happen is
--    two simultaneous current relationships of the same kind between
--    the same two people, in the same direction.
-- ---------------------------------------------------------------------

alter table public.family_relationships
  drop constraint if exists family_relationships_unique;

create unique index if not exists family_relationships_one_current_idx
  on public.family_relationships (resident_id, related_resident_id, relationship_type)
  where relationship_status = 'active';

-- ---------------------------------------------------------------------
-- 3. Which relationships have episodes
-- ---------------------------------------------------------------------

create or replace function public.is_time_based_relationship(p_type text)
returns boolean
language sql
immutable
as $$
  select p_type in ('spouse', 'guardian', 'dependant');
$$;

comment on function public.is_time_based_relationship(text) is
  'True for relationships that begin and end. The rest are permanent lineage.';

-- ---------------------------------------------------------------------
-- 4. Recording a relationship
--
--    Replaces the earlier version. A time-based relationship must say
--    when it began; permanent lineage need not.
-- ---------------------------------------------------------------------

create or replace function public.registry_record_family_relationship(
  p_resident_id         uuid,
  p_related_resident_id uuid,
  p_relationship_type   text,
  p_started_at          date default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_resident public.residents;
  v_related  public.residents;
  v_inverse  text := public.inverse_relationship_type(p_relationship_type);
  v_added    int := 0;
  v_inverse_added int := 0;
begin
  perform public.require_registry_clerk();

  if v_inverse is null then
    raise exception 'Relationship type % is not one this system recognises.', coalesce(p_relationship_type, '(none)')
      using errcode = 'TA044';
  end if;

  if p_resident_id = p_related_resident_id then
    raise exception 'A resident cannot be related to themselves.' using errcode = 'TA042';
  end if;

  -- A marriage or a guardianship is an episode, so it has to say when
  -- it started. Lineage simply is.
  if public.is_time_based_relationship(p_relationship_type) and p_started_at is null then
    raise exception 'A % relationship must say when it began.', p_relationship_type
      using errcode = 'TA049';
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  select * into v_related from public.residents where id = p_related_resident_id;
  if not found then
    raise exception 'The related resident could not be found.' using errcode = 'TA031';
  end if;

  -- Only a CURRENT one of the same kind is a duplicate. An earlier
  -- episode that has ended is history, and history is allowed to repeat.
  if exists (select 1 from public.family_relationships f
              where f.resident_id = p_resident_id
                and f.related_resident_id = p_related_resident_id
                and f.relationship_type = p_relationship_type
                and f.relationship_status = 'active') then
    raise exception '% is already recorded as the current % of %.',
      v_resident.first_name || ' ' || v_resident.last_name, p_relationship_type,
      v_related.first_name || ' ' || v_related.last_name
      using errcode = 'TA043';
  end if;

  insert into public.family_relationships
    (resident_id, related_resident_id, relationship_type, relationship_status, relationship_started_at)
  values (p_resident_id, p_related_resident_id, p_relationship_type, 'active', p_started_at);
  get diagnostics v_added = row_count;

  -- The other side of the same fact, with the same starting date.
  insert into public.family_relationships
    (resident_id, related_resident_id, relationship_type, relationship_status, relationship_started_at)
  values (p_related_resident_id, p_resident_id, v_inverse, 'active', p_started_at)
  on conflict (resident_id, related_resident_id, relationship_type)
    where relationship_status = 'active'
  do nothing;
  get diagnostics v_inverse_added = row_count;

  return jsonb_build_object(
    'resident',          v_resident.first_name || ' ' || v_resident.last_name,
    'related_resident',  v_related.first_name || ' ' || v_related.last_name,
    'relationship_type', p_relationship_type,
    'inverse_type',      v_inverse,
    'started_at',        p_started_at,
    'time_based',        public.is_time_based_relationship(p_relationship_type),
    'recorded',          v_added,
    'inverse_recorded',  v_inverse_added);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Ending a time-based relationship
--
--    Ends this episode and the matching one the other way round. The
--    rows stay exactly where they are: a divorce is recorded, never
--    erased. Permanent lineage cannot be ended here at all.
-- ---------------------------------------------------------------------

create or replace function public.registry_end_family_relationship(
  p_relationship_id uuid,
  p_ended_at        date
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_relationship public.family_relationships;
  v_inverse      text;
  v_ended        int := 0;
begin
  perform public.require_registry_clerk();

  select * into v_relationship
  from public.family_relationships where id = p_relationship_id for update;
  if not found then
    raise exception 'That relationship could not be found.' using errcode = 'TA031';
  end if;

  if not public.is_time_based_relationship(v_relationship.relationship_type) then
    raise exception 'A % relationship is permanent and is not ended. A parent remains a parent.',
      v_relationship.relationship_type
      using errcode = 'TA046';
  end if;

  if v_relationship.relationship_status <> 'active' then
    raise exception 'That relationship has already ended.' using errcode = 'TA047';
  end if;

  if p_ended_at is null then
    raise exception 'An end date is required.' using errcode = 'TA048';
  end if;

  if v_relationship.relationship_started_at is not null
     and p_ended_at < v_relationship.relationship_started_at then
    raise exception 'The relationship cannot end on % because it began on %.',
      p_ended_at, v_relationship.relationship_started_at
      using errcode = 'TA048';
  end if;

  v_inverse := public.inverse_relationship_type(v_relationship.relationship_type);

  update public.family_relationships
     set relationship_status = 'inactive',
         relationship_ended_at = p_ended_at
   where id = v_relationship.id;
  get diagnostics v_ended = row_count;

  -- The same episode seen from the other side.
  update public.family_relationships
     set relationship_status = 'inactive',
         relationship_ended_at = p_ended_at
   where resident_id = v_relationship.related_resident_id
     and related_resident_id = v_relationship.resident_id
     and relationship_type = v_inverse
     and relationship_status = 'active';

  return jsonb_build_object(
    'relationship_id',   v_relationship.id,
    'relationship_type', v_relationship.relationship_type,
    'ended_at',          p_ended_at,
    'ended',             v_ended);
end;
$$;

-- The old catch-all is gone: it let permanent lineage be retired, which
-- is exactly what must not happen.
drop function if exists public.registry_set_relationship_status(uuid, text);

-- ---------------------------------------------------------------------
-- 6. Lineage, now with its dates
-- ---------------------------------------------------------------------

drop function if exists public.registry_family_lineage(uuid);

create function public.registry_family_lineage(p_resident_id uuid)
returns table (
  relationship_id         uuid,
  relationship_type       text,
  relationship_status     text,
  relationship_started_at date,
  relationship_ended_at   date,
  time_based              boolean,
  related_resident_id     uuid,
  related_full_name       text,
  related_id_number       text,
  related_status          text,
  related_household_code  text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  if not exists (select 1 from public.residents where id = p_resident_id) then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  return query
    select f.id, f.relationship_type, f.relationship_status,
           f.relationship_started_at, f.relationship_ended_at,
           public.is_time_based_relationship(f.relationship_type),
           other.id, other.first_name || ' ' || other.last_name,
           other.id_number, other.resident_status, h.household_code
    from public.family_relationships f
    join public.residents other on other.id = f.related_resident_id
    left join public.households h on h.id = other.household_id
    where f.resident_id = p_resident_id
    -- A row says "this resident is the <type> of the other person", so
    -- the reading order is the inverse: the people they are the child
    -- of are their parents, and come first.
    order by
      case f.relationship_type
        when 'child' then 1 when 'parent' then 2 when 'sibling' then 3
        when 'grandchild' then 4 when 'grandparent' then 5
        when 'spouse' then 6 when 'dependant' then 7 else 8 end,
      f.relationship_status,
      f.relationship_started_at desc nulls last,
      other.last_name, other.first_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.is_time_based_relationship(text)',
    'public.registry_family_lineage(uuid)',
    'public.registry_record_family_relationship(uuid, uuid, text, date)',
    'public.registry_end_family_relationship(uuid, date)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

-- The three-argument form was replaced by the one that takes a date.
drop function if exists public.registry_record_family_relationship(uuid, uuid, text);


-- ---------------------------------------------------------------------
-- 20260924090000_resident_accounts.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — resident accounts and verification requests
--
-- The principle this is built on: creating an online account does not
-- make anyone a resident of the village. The residents table remains
-- the authoritative register, and an applicant only becomes linked to
-- it when a Registry Clerk matches them to a record that was already
-- there. Registration never writes to residents.
--
--   auth.users  →  user_accounts (resident, pending)
--                        │
--                        └─< resident_account_requests  (one per attempt)
--                                    │
--                                    └─< resident_request_documents
--
-- A declined applicant keeps their account and applies again; the
-- earlier attempt is kept exactly as it was.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. user_accounts learns about residents
-- ---------------------------------------------------------------------

alter table public.user_accounts
  drop constraint if exists user_accounts_account_type_allowed;
alter table public.user_accounts
  add constraint user_accounts_account_type_allowed
  check (account_type in ('staff', 'resident'));

alter table public.user_accounts
  drop constraint if exists user_accounts_account_status_allowed;
alter table public.user_accounts
  add constraint user_accounts_account_status_allowed
  check (account_status in ('active', 'deactivated', 'pending', 'declined'));

-- A resident account never points at a staff record, and only a
-- resident account may be linked to a resident.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_accounts_resident_shape') then
    alter table public.user_accounts
      add constraint user_accounts_resident_shape check (
        account_type <> 'resident' or staff_id is null
      );
  end if;

  if not exists (select 1 from pg_constraint where conname = 'user_accounts_resident_id_fkey') then
    alter table public.user_accounts
      add constraint user_accounts_resident_id_fkey
      foreign key (resident_id) references public.residents (id);
  end if;
end;
$$;

comment on column public.user_accounts.resident_id is
  'The official resident this account was matched to, set only by a Registry Clerk approving a verification request.';

-- One resident record, at most one resident account.
create unique index if not exists user_accounts_one_account_per_resident_idx
  on public.user_accounts (resident_id)
  where resident_id is not null;

create index if not exists user_accounts_account_type_idx on public.user_accounts (account_type);

-- ---------------------------------------------------------------------
-- 2. One row per application attempt
-- ---------------------------------------------------------------------

create table if not exists public.resident_account_requests (
  id                       uuid primary key default gen_random_uuid(),
  user_account_id          uuid not null references public.user_accounts (id) on delete cascade,

  -- What the applicant claims about themselves. Evidence for matching,
  -- never authoritative: it is not copied into residents.
  first_name               text not null,
  middle_names             text,
  last_name                text not null,
  previous_surname         text,
  id_number                text not null,
  date_of_birth            date not null,
  gender                   text not null,

  cellphone_number         text not null,

  house_number             text not null,
  street_address           text not null,

  household_head_name             text not null,
  relationship_to_household_head  text not null,

  request_status           text not null default 'pending',

  submitted_at             timestamptz not null default now(),
  reviewed_at              timestamptz,
  reviewed_by_staff_id     uuid references public.staff (id),
  decline_reason           text,
  matched_resident_id      uuid references public.residents (id),

  constraint resident_account_requests_status_allowed
    check (request_status in ('pending', 'approved', 'declined')),
  constraint resident_account_requests_names_present
    check (btrim(first_name) <> '' and btrim(last_name) <> ''),
  constraint resident_account_requests_identity_present
    check (btrim(id_number) <> '' and btrim(gender) <> ''),
  constraint resident_account_requests_contact_present
    check (btrim(cellphone_number) <> ''),
  constraint resident_account_requests_address_present
    check (btrim(house_number) <> '' and btrim(street_address) <> ''),
  constraint resident_account_requests_household_claim_present
    check (btrim(household_head_name) <> '' and btrim(relationship_to_household_head) <> ''),
  -- A decision has a reviewer and a time; a decline also has a reason.
  constraint resident_account_requests_review_shape check (
    (request_status = 'pending'  and reviewed_at is null and reviewed_by_staff_id is null
      and decline_reason is null and matched_resident_id is null)
    or (request_status = 'approved' and reviewed_at is not null and reviewed_by_staff_id is not null
      and matched_resident_id is not null and decline_reason is null)
    or (request_status = 'declined' and reviewed_at is not null and reviewed_by_staff_id is not null
      and btrim(coalesce(decline_reason, '')) <> '' and matched_resident_id is null)
  )
);

comment on table public.resident_account_requests is
  'One application attempt. Declined attempts are kept: the applicant reapplies with a new row, not a new account.';

create index if not exists resident_account_requests_user_account_idx
  on public.resident_account_requests (user_account_id);
create index if not exists resident_account_requests_status_idx
  on public.resident_account_requests (request_status);
create index if not exists resident_account_requests_id_number_idx
  on public.resident_account_requests (id_number);

-- An account may have many attempts behind it, but only one waiting.
create unique index if not exists resident_account_requests_one_pending_idx
  on public.resident_account_requests (user_account_id)
  where request_status = 'pending';

-- ---------------------------------------------------------------------
-- 3. The documents attached to an attempt
--
--    Only where the file lives, never the file itself.
-- ---------------------------------------------------------------------

create table if not exists public.resident_request_documents (
  id              uuid primary key default gen_random_uuid(),
  request_id      uuid not null references public.resident_account_requests (id) on delete cascade,
  document_type   text not null,
  storage_path    text not null,
  file_name       text not null,
  mime_type       text not null,
  file_size_bytes bigint not null,
  uploaded_at     timestamptz not null default now(),

  constraint resident_request_documents_type_allowed
    check (document_type in ('certified_id_copy', 'proof_of_residence')),
  constraint resident_request_documents_mime_allowed
    check (mime_type in ('application/pdf', 'image/jpeg', 'image/png')),
  constraint resident_request_documents_size_allowed
    check (file_size_bytes > 0 and file_size_bytes <= 2097152),
  constraint resident_request_documents_path_present
    check (btrim(storage_path) <> '' and btrim(file_name) <> ''),
  -- One certified ID copy and one proof of residence per attempt.
  constraint resident_request_documents_one_of_each unique (request_id, document_type)
);

comment on table public.resident_request_documents is
  'Where an uploaded document lives in the private storage bucket. The bytes are never in PostgreSQL.';

create index if not exists resident_request_documents_request_idx
  on public.resident_request_documents (request_id);

-- ---------------------------------------------------------------------
-- 4. The private bucket
--
--    Created here so the limits travel with the migration. Supabase
--    enforces the size and the accepted types on upload itself, which
--    no browser can talk its way around.
-- ---------------------------------------------------------------------

do $$
begin
  if to_regclass('storage.buckets') is null then
    return;  -- not a Supabase database; the local test harness stubs this
  end if;

  begin
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('resident-verification-documents', 'resident-verification-documents', false,
            2097152, array['application/pdf', 'image/jpeg', 'image/png'])
    on conflict (id) do update
      set public = false,
          file_size_limit = 2097152,
          allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png'];
  exception when undefined_column then
    -- An older storage schema without the limit columns.
    insert into storage.buckets (id, name, public)
    values ('resident-verification-documents', 'resident-verification-documents', false)
    on conflict (id) do update set public = false;
  end;
end;
$$;

-- Applicants reach only their own folder; Registry Clerks may read the
-- whole bucket to review what was submitted. Nobody else gets in, and
-- there is no update or delete policy at all.
do $$
begin
  if to_regclass('storage.objects') is null then
    return;
  end if;

  execute $policy$
    drop policy if exists resident_documents_insert_own on storage.objects;
    create policy resident_documents_insert_own on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'resident-verification-documents'
        and split_part(name, '/', 1) = auth.uid()::text
      );
  $policy$;

  execute $policy$
    drop policy if exists resident_documents_read_own on storage.objects;
    create policy resident_documents_read_own on storage.objects
      for select to authenticated
      using (
        bucket_id = 'resident-verification-documents'
        and split_part(name, '/', 1) = auth.uid()::text
      );
  $policy$;

  execute $policy$
    drop policy if exists resident_documents_read_by_registry_clerk on storage.objects;
    create policy resident_documents_read_by_registry_clerk on storage.objects
      for select to authenticated
      using (
        bucket_id = 'resident-verification-documents'
        and public.is_active_registry_clerk()
      );
  $policy$;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Row Level Security on the new tables
--
--    Applicants read their own attempts and their own documents. An
--    active Registry Clerk reads all of them. There is no insert,
--    update or delete policy: every change goes through the functions
--    below.
-- ---------------------------------------------------------------------

alter table public.resident_account_requests  enable row level security;
alter table public.resident_request_documents enable row level security;
alter table public.resident_account_requests  force row level security;
alter table public.resident_request_documents force row level security;

drop policy if exists resident_requests_readable_by_owner_or_clerk on public.resident_account_requests;
create policy resident_requests_readable_by_owner_or_clerk
  on public.resident_account_requests for select to authenticated
  using (
    public.is_active_registry_clerk()
    or exists (select 1 from public.user_accounts ua
                where ua.id = resident_account_requests.user_account_id
                  and ua.auth_user_id = auth.uid())
  );

drop policy if exists resident_documents_readable_by_owner_or_clerk on public.resident_request_documents;
create policy resident_documents_readable_by_owner_or_clerk
  on public.resident_request_documents for select to authenticated
  using (
    public.is_active_registry_clerk()
    or exists (select 1 from public.resident_account_requests r
                join public.user_accounts ua on ua.id = r.user_account_id
               where r.id = resident_request_documents.request_id
                 and ua.auth_user_id = auth.uid())
  );

revoke all on public.resident_account_requests  from anon, authenticated;
revoke all on public.resident_request_documents from anon, authenticated;
grant select on public.resident_account_requests  to authenticated;
grant select on public.resident_request_documents to authenticated;
grant all on public.resident_account_requests  to service_role;
grant all on public.resident_request_documents to service_role;

-- ---------------------------------------------------------------------
-- 6. Becoming a resident account
--
--    Called once, by the person who has just signed up and confirmed
--    their email. It only ever creates a RESIDENT account: staff
--    accounts are made by the invitation process and nothing here can
--    produce one. If an account already exists it is returned
--    untouched, so signing in again changes nothing.
-- ---------------------------------------------------------------------

create or replace function public.resident_ensure_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user    auth.users;
  v_account public.user_accounts;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.' using errcode = '42501';
  end if;

  select * into v_account from public.user_accounts where auth_user_id = auth.uid();
  if found then
    -- Already has an account of some kind. Never changed here.
    return jsonb_build_object(
      'account_id', v_account.id, 'account_type', v_account.account_type,
      'account_status', v_account.account_status, 'created', false);
  end if;

  select * into v_user from auth.users where id = auth.uid();
  if not found or coalesce(btrim(v_user.email), '') = '' then
    raise exception 'That sign-in has no email address.' using errcode = 'TA050';
  end if;

  -- A staff member's account is created by the invitation process. If
  -- one is somehow missing, it is not this function's job to invent it.
  if exists (select 1 from public.staff s where lower(s.email) = lower(v_user.email)) then
    raise exception 'That email address belongs to a staff member. Staff accounts are created by the Council Administrator.'
      using errcode = 'TA050';
  end if;

  insert into public.user_accounts (auth_user_id, email, account_type, account_status, resident_id)
  values (auth.uid(), lower(btrim(v_user.email)), 'resident', 'pending', null)
  returning * into v_account;

  return jsonb_build_object(
    'account_id', v_account.id, 'account_type', v_account.account_type,
    'account_status', v_account.account_status, 'created', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. What a resident sees of their own account
-- ---------------------------------------------------------------------

create or replace function public.resident_portal()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_account public.user_accounts;
  v_result  jsonb;
begin
  select * into v_account from public.user_accounts
  where auth_user_id = auth.uid() and account_type = 'resident';
  if not found then
    raise exception 'You do not have a resident account.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'account_id',     v_account.id,
    'email',          v_account.email,
    'account_status', v_account.account_status,
    'resident_id',    v_account.resident_id,
    -- Only ever their own official record, and only once matched.
    'resident', (select jsonb_build_object(
                          'full_name', r.first_name || ' ' || r.last_name,
                          'id_number', r.id_number,
                          'household_code', h.household_code,
                          'street_address', s.street_address)
                 from public.residents r
                 left join public.households h on h.id = r.household_id
                 left join public.land_sites s on s.id = h.residential_site_id
                 where r.id = v_account.resident_id),
    'latest_request', (
      select jsonb_build_object(
               'request_id',     q.id,
               'request_status', q.request_status,
               'submitted_at',   q.submitted_at,
               'reviewed_at',    q.reviewed_at,
               'decline_reason', q.decline_reason,
               'first_name',     q.first_name,
               'last_name',      q.last_name,
               'id_number',      q.id_number)
      from public.resident_account_requests q
      where q.user_account_id = v_account.id
      order by q.submitted_at desc limit 1),
    'attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'request_status', q.request_status,
               'submitted_at',   q.submitted_at,
               'reviewed_at',    q.reviewed_at,
               'decline_reason', q.decline_reason)
             order by q.submitted_at desc)
      from public.resident_account_requests q
      where q.user_account_id = v_account.id), '[]'::jsonb),
    'may_submit', (
      v_account.account_status in ('pending', 'declined')
      and not exists (select 1 from public.resident_account_requests q
                       where q.user_account_id = v_account.id and q.request_status = 'pending'))
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Submitting a verification request
--
--    One call: the claimed details and both documents together, so a
--    request can never exist without the documents that support it.
--    The documents have already been uploaded to the applicant's own
--    folder in the private bucket; what arrives here is where they are.
-- ---------------------------------------------------------------------

create or replace function public.resident_submit_verification_request(
  p_details   jsonb,
  p_documents jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_account  public.user_accounts;
  v_request  public.resident_account_requests;
  v_document jsonb;
  v_types    text[] := '{}';
  v_path     text;
  v_exists   boolean;
  v_real_size bigint;
begin
  select * into v_account from public.user_accounts
  where auth_user_id = auth.uid() and account_type = 'resident' for update;
  if not found then
    raise exception 'You do not have a resident account.' using errcode = '42501';
  end if;

  if v_account.account_status not in ('pending', 'declined') then
    raise exception 'This account is % and cannot submit a verification request.', v_account.account_status
      using errcode = 'TA051';
  end if;

  if exists (select 1 from public.resident_account_requests q
              where q.user_account_id = v_account.id and q.request_status = 'pending') then
    raise exception 'A verification request is already waiting to be reviewed.'
      using errcode = 'TA051';
  end if;

  -- ---- the two documents -------------------------------------------
  if jsonb_typeof(p_documents) <> 'array' or jsonb_array_length(p_documents) <> 2 then
    raise exception 'A certified copy of your ID and a proof of residence are both required.'
      using errcode = 'TA057';
  end if;

  for v_document in select * from jsonb_array_elements(p_documents)
  loop
    if (v_document ->> 'document_type') not in ('certified_id_copy', 'proof_of_residence') then
      raise exception 'Unknown document type %.', coalesce(v_document ->> 'document_type', '(none)')
        using errcode = 'TA057';
    end if;
    v_types := v_types || (v_document ->> 'document_type');

    if (v_document ->> 'mime_type') not in ('application/pdf', 'image/jpeg', 'image/png') then
      raise exception 'A document must be a PDF, a JPG or a PNG. % is not accepted.',
        coalesce(v_document ->> 'mime_type', '(none)')
        using errcode = 'TA058';
    end if;

    v_path := coalesce(btrim(v_document ->> 'storage_path'), '');
    -- The file has to be in the applicant's own folder, so nobody can
    -- attach somebody else's document to their application.
    if v_path = '' or split_part(v_path, '/', 1) <> auth.uid()::text then
      raise exception 'That document does not belong to this account.' using errcode = 'TA059';
    end if;

    v_real_size := nullif(v_document ->> 'file_size_bytes', '')::bigint;

    -- On a real Supabase database the uploaded object is the authority
    -- on its own size, so a declared size cannot be talked down.
    if to_regclass('storage.objects') is not null then
      execute format(
        'select exists (select 1 from storage.objects where bucket_id = %L and name = %L),
                (select (metadata ->> ''size'')::bigint from storage.objects
                  where bucket_id = %L and name = %L)',
        'resident-verification-documents', v_path,
        'resident-verification-documents', v_path)
      into v_exists, v_real_size;

      if not coalesce(v_exists, false) then
        raise exception 'That document was not uploaded.' using errcode = 'TA059';
      end if;
      v_real_size := coalesce(v_real_size, nullif(v_document ->> 'file_size_bytes', '')::bigint);
    end if;

    if v_real_size is null or v_real_size <= 0 then
      raise exception 'That document appears to be empty.' using errcode = 'TA058';
    end if;
    if v_real_size > 2097152 then
      raise exception 'Each document must be 2 MB or smaller. % is %.',
        coalesce(v_document ->> 'file_name', 'that file'),
        pg_size_pretty(v_real_size)
        using errcode = 'TA058';
    end if;
  end loop;

  if not ('certified_id_copy' = any (v_types) and 'proof_of_residence' = any (v_types)) then
    raise exception 'A certified copy of your ID and a proof of residence are both required.'
      using errcode = 'TA057';
  end if;

  -- ---- the claimed details -------------------------------------------
  insert into public.resident_account_requests (
    user_account_id, first_name, middle_names, last_name, previous_surname,
    id_number, date_of_birth, gender, cellphone_number,
    house_number, street_address, household_head_name, relationship_to_household_head,
    request_status)
  values (
    v_account.id,
    btrim(p_details ->> 'first_name'),
    nullif(btrim(coalesce(p_details ->> 'middle_names', '')), ''),
    btrim(p_details ->> 'last_name'),
    nullif(btrim(coalesce(p_details ->> 'previous_surname', '')), ''),
    btrim(p_details ->> 'id_number'),
    (p_details ->> 'date_of_birth')::date,
    btrim(p_details ->> 'gender'),
    btrim(p_details ->> 'cellphone_number'),
    btrim(p_details ->> 'house_number'),
    btrim(p_details ->> 'street_address'),
    btrim(p_details ->> 'household_head_name'),
    btrim(p_details ->> 'relationship_to_household_head'),
    'pending')
  returning * into v_request;

  for v_document in select * from jsonb_array_elements(p_documents)
  loop
    insert into public.resident_request_documents (
      request_id, document_type, storage_path, file_name, mime_type, file_size_bytes)
    values (
      v_request.id,
      v_document ->> 'document_type',
      btrim(v_document ->> 'storage_path'),
      btrim(v_document ->> 'file_name'),
      v_document ->> 'mime_type',
      (v_document ->> 'file_size_bytes')::bigint);
  end loop;

  -- Waiting on the Registry Clerk from here.
  update public.user_accounts set account_status = 'pending' where id = v_account.id;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'request_status', v_request.request_status,
    'submitted_at',   v_request.submitted_at,
    'account_status', 'pending');
end;
$$;

-- ---------------------------------------------------------------------
-- 9. The Registry Clerk's queue
-- ---------------------------------------------------------------------

create or replace function public.registry_pending_resident_requests()
returns table (
  request_id      uuid,
  full_name       text,
  id_number       text,
  date_of_birth   date,
  gender          text,
  email           text,
  cellphone_number text,
  house_number    text,
  street_address  text,
  household_head_name text,
  relationship_to_household_head text,
  submitted_at    timestamptz,
  previous_attempts bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  return query
    select q.id,
           q.first_name || coalesce(' ' || q.middle_names, '') || ' ' || q.last_name,
           q.id_number, q.date_of_birth, q.gender, ua.email, q.cellphone_number,
           q.house_number, q.street_address,
           q.household_head_name, q.relationship_to_household_head,
           q.submitted_at,
           (select count(*) from public.resident_account_requests earlier
             where earlier.user_account_id = q.user_account_id
               and earlier.submitted_at < q.submitted_at)
    from public.resident_account_requests q
    join public.user_accounts ua on ua.id = q.user_account_id
    where q.request_status = 'pending'
    order by q.submitted_at;
end;
$$;

-- Everything needed to judge one request: what was claimed, the
-- documents, and what this account has tried before.
create or replace function public.registry_resident_request(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
begin
  perform public.require_registry_clerk();

  select jsonb_build_object(
    'request_id',      q.id,
    'request_status',  q.request_status,
    'submitted_at',    q.submitted_at,
    'reviewed_at',     q.reviewed_at,
    'decline_reason',  q.decline_reason,
    'account_email',   ua.email,
    'account_status',  ua.account_status,
    'claimed', jsonb_build_object(
      'first_name',       q.first_name,
      'middle_names',     q.middle_names,
      'last_name',        q.last_name,
      'previous_surname', q.previous_surname,
      'full_name',        q.first_name || coalesce(' ' || q.middle_names, '') || ' ' || q.last_name,
      'id_number',        q.id_number,
      'date_of_birth',    q.date_of_birth,
      'gender',           q.gender,
      'cellphone_number', q.cellphone_number,
      'house_number',     q.house_number,
      'street_address',   q.street_address,
      'household_head_name', q.household_head_name,
      'relationship_to_household_head', q.relationship_to_household_head),
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'document_type',   d.document_type,
               'storage_path',    d.storage_path,
               'file_name',       d.file_name,
               'mime_type',       d.mime_type,
               'file_size_bytes', d.file_size_bytes)
             order by d.document_type)
      from public.resident_request_documents d where d.request_id = q.id), '[]'::jsonb),
    'earlier_attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'request_status', e.request_status,
               'submitted_at',   e.submitted_at,
               'reviewed_at',    e.reviewed_at,
               'decline_reason', e.decline_reason)
             order by e.submitted_at desc)
      from public.resident_account_requests e
      where e.user_account_id = q.user_account_id and e.id <> q.id), '[]'::jsonb),
    'matched_resident_id', q.matched_resident_id
  ) into v_result
  from public.resident_account_requests q
  join public.user_accounts ua on ua.id = q.user_account_id
  where q.id = p_request_id;

  if v_result is null then
    raise exception 'That verification request could not be found.' using errcode = 'TA052';
  end if;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Finding the official resident this applicant claims to be
--
--     Suggestions only, in the order a clerk would look: the identity
--     number first, then name and birth date, then where they say they
--     live, then who they say heads the household. Nothing here
--     approves anything — the clerk chooses.
-- ---------------------------------------------------------------------

create or replace function public.registry_resident_candidates(p_request_id uuid)
returns table (
  resident_id     uuid,
  full_name       text,
  id_number       text,
  date_of_birth   date,
  gender          text,
  resident_status text,
  household_code  text,
  household_head  text,
  street_address  text,
  already_linked  boolean,
  match_rank      int,
  match_reason    text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.resident_account_requests;
begin
  perform public.require_registry_clerk();

  select * into v_request from public.resident_account_requests where id = p_request_id;
  if not found then
    raise exception 'That verification request could not be found.' using errcode = 'TA052';
  end if;

  return query
    with scored as (
      select r.id,
             case
               when lower(btrim(r.id_number)) = lower(btrim(v_request.id_number)) then 1
               when lower(r.first_name) = lower(v_request.first_name)
                    and lower(r.last_name) = lower(v_request.last_name)
                    and r.date_of_birth = v_request.date_of_birth then 2
               when s.street_address ilike public.like_pattern(v_request.street_address) then 3
               when head.first_name || ' ' || head.last_name
                    ilike public.like_pattern(v_request.household_head_name) then 4
               when lower(r.last_name) = lower(v_request.last_name)
                    or lower(r.last_name) = lower(coalesce(v_request.previous_surname, '~none~')) then 5
             end as rank,
             r, h, s, head
      from public.residents r
      left join public.households h on h.id = r.household_id
      left join public.land_sites s on s.id = h.residential_site_id
      left join public.residents head on head.id = h.head_resident_id
    )
    select (scored.r).id,
           (scored.r).first_name || ' ' || (scored.r).last_name,
           (scored.r).id_number, (scored.r).date_of_birth, (scored.r).gender,
           (scored.r).resident_status,
           (scored.h).household_code,
           (scored.head).first_name || ' ' || (scored.head).last_name,
           (scored.s).street_address,
           exists (select 1 from public.user_accounts ua where ua.resident_id = (scored.r).id),
           scored.rank,
           case scored.rank
             when 1 then 'Identity number matches exactly'
             when 2 then 'Name and date of birth match'
             when 3 then 'Lives at the address given'
             when 4 then 'Household head matches the name given'
             else 'Surname matches'
           end
    from scored
    where scored.rank is not null
    order by scored.rank, (scored.r).last_name, (scored.r).first_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Approving
--
--     Links the account to a resident record that was already on the
--     register. The register itself is not touched: nothing the
--     applicant typed is copied into it. If their official details are
--     wrong, that is a separate correction the clerk makes with the
--     resident functions.
-- ---------------------------------------------------------------------

create or replace function public.registry_approve_resident_request(
  p_request_id uuid,
  p_resident_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id  uuid := public.acting_registry_clerk_staff_id();
  v_request   public.resident_account_requests;
  v_account   public.user_accounts;
  v_resident  public.residents;
  v_household public.households;
begin
  select * into v_request from public.resident_account_requests where id = p_request_id for update;
  if not found then
    raise exception 'That verification request could not be found.' using errcode = 'TA052';
  end if;
  if v_request.request_status <> 'pending' then
    raise exception 'That request has already been %.', v_request.request_status using errcode = 'TA052';
  end if;

  select * into v_account from public.user_accounts where id = v_request.user_account_id for update;
  if v_account.account_status <> 'pending' then
    raise exception 'That applicant''s account is % and is no longer awaiting verification.',
      v_account.account_status using errcode = 'TA056';
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    raise exception 'Choose the official resident record this applicant matches.' using errcode = 'TA031';
  end if;
  if v_resident.resident_status <> 'active' then
    raise exception '% is recorded as % on the register and cannot be given an account.',
      v_resident.first_name || ' ' || v_resident.last_name, v_resident.resident_status
      using errcode = 'TA053';
  end if;

  -- An account is an account for someone who lives somewhere. If the
  -- register does not yet say where, that is fixed first.
  if v_resident.household_id is null then
    raise exception '% is not linked to a household yet. Link them to their household first, then approve.',
      v_resident.first_name || ' ' || v_resident.last_name
      using errcode = 'TA054';
  end if;

  select * into v_household from public.households where id = v_resident.household_id;
  if not found or v_household.household_status <> 'active' then
    raise exception 'The household % belongs to is not current. Correct that first, then approve.',
      v_resident.first_name || ' ' || v_resident.last_name
      using errcode = 'TA054';
  end if;

  if exists (select 1 from public.user_accounts ua
              where ua.resident_id = v_resident.id and ua.id <> v_account.id) then
    raise exception '% already has a resident account.',
      v_resident.first_name || ' ' || v_resident.last_name
      using errcode = 'TA055';
  end if;

  update public.user_accounts
     set resident_id = v_resident.id,
         account_status = 'active'
   where id = v_account.id;

  update public.resident_account_requests
     set request_status = 'approved',
         matched_resident_id = v_resident.id,
         reviewed_by_staff_id = v_staff_id,
         reviewed_at = now()
   where id = v_request.id;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'request_status', 'approved',
    'account_status', 'active',
    'resident_id',    v_resident.id,
    'resident_name',  v_resident.first_name || ' ' || v_resident.last_name,
    'household_code', v_household.household_code);
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Declining
--
--     Nothing is deleted. The applicant keeps their sign-in, sees why,
--     and applies again with the same account.
-- ---------------------------------------------------------------------

create or replace function public.registry_decline_resident_request(
  p_request_id uuid,
  p_reason     text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_registry_clerk_staff_id();
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_request  public.resident_account_requests;
begin
  if v_reason = '' then
    raise exception 'A reason is required, so the applicant knows what to correct.' using errcode = 'TA018';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA018';
  end if;

  select * into v_request from public.resident_account_requests where id = p_request_id for update;
  if not found then
    raise exception 'That verification request could not be found.' using errcode = 'TA052';
  end if;
  if v_request.request_status <> 'pending' then
    raise exception 'That request has already been %.', v_request.request_status using errcode = 'TA052';
  end if;

  update public.resident_account_requests
     set request_status = 'declined',
         decline_reason = v_reason,
         reviewed_by_staff_id = v_staff_id,
         reviewed_at = now()
   where id = v_request.id;

  -- The account stays, unlinked, so they can put it right and reapply.
  update public.user_accounts
     set account_status = 'declined'
   where id = v_request.user_account_id;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'request_status', 'declined',
    'account_status', 'declined',
    'decline_reason', v_reason);
end;
$$;

-- The acting clerk's staff id, for the review record.
create or replace function public.acting_registry_clerk_staff_id()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid;
begin
  select s.id into v_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Registry Clerk';

  if v_staff_id is null then
    raise exception 'Only an active Registry Clerk may review verification requests.'
      using errcode = '42501';
  end if;
  return v_staff_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.resident_ensure_account()',
    'public.resident_portal()',
    'public.resident_submit_verification_request(jsonb, jsonb)',
    'public.registry_pending_resident_requests()',
    'public.registry_resident_request(uuid)',
    'public.registry_resident_candidates(uuid)',
    'public.registry_approve_resident_request(uuid, uuid)',
    'public.registry_decline_resident_request(uuid, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

revoke all on function public.acting_registry_clerk_staff_id() from public, anon, authenticated;

