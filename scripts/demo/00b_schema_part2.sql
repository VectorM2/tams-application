-- =====================================================================
-- TAMS database schema — part 2 of 3
-- Generated from supabase/migrations (do not edit by hand).
-- Paste into the Supabase SQL Editor and run. Run the three parts in
-- order: 00a, 00b, 00c — then 01_create_accounts.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 20260925090000_land_model.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — the land model
--
-- Four land types, and only four:
--
--   residential  one per resident, perpetual permission
--   farming      one per household, five year term
--   business     one per resident, two year term
--   burial       to a household, perpetual, another only once full
--
-- Grazing is not among them. There is communal grazing in the village,
-- but it is not allocated, needs no permission to occupy, and nobody
-- applies for it, so it has no place in this system.
--
-- The Traditional Authority decides who gets land. That happens off the
-- system, in the way it always has. TAMS records the administrative
-- outcome: there is no digital approval by the Chief, the Headman or
-- the Headwoman, and no Council Administrator countersignature.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Land types
--
--    Grazing is removed if nothing uses it. If any grazing site exists
--    it is kept exactly as it is — historical records are not deleted —
--    but it is marked unavailable and excluded from every workflow
--    below, which all work from the four allocatable types.
-- ---------------------------------------------------------------------

create or replace function public.allocatable_land_types()
returns text[]
language sql
immutable
as $$
  select array['residential', 'farming', 'business', 'burial'];
$$;

do $$
declare
  v_grazing_sites int;
begin
  select count(*) into v_grazing_sites from public.land_sites where site_type = 'grazing';

  alter table public.land_sites drop constraint if exists land_sites_site_type_allowed;

  if v_grazing_sites = 0 then
    alter table public.land_sites
      add constraint land_sites_site_type_allowed
      check (site_type in ('residential', 'farming', 'business', 'burial'));
    raise notice 'No grazing sites existed; grazing removed as a land type.';
  else
    -- Kept only so the existing rows remain valid. Nothing can create a
    -- new one: registration and every workflow use the four types above.
    alter table public.land_sites
      add constraint land_sites_site_type_allowed
      check (site_type in ('residential', 'farming', 'business', 'burial', 'grazing'));
    raise notice
      '% grazing site(s) exist and were preserved as legacy records, marked unavailable and excluded from allocation.',
      v_grazing_sites;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. What state a site is in
-- ---------------------------------------------------------------------

alter table public.land_sites drop constraint if exists land_sites_site_status_allowed;
alter table public.land_sites
  add constraint land_sites_site_status_allowed
  check (site_status in ('available', 'allocated', 'unavailable'));

-- Burial plots fill up. That is a property of the plot, not of whether
-- it is allocated, so it lives in its own column.
alter table public.land_sites
  add column if not exists burial_status text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'land_sites_burial_status_shape') then
    alter table public.land_sites
      add constraint land_sites_burial_status_shape check (
        (site_type = 'burial' and burial_status in ('usable', 'full', 'closed'))
        or (site_type <> 'burial' and burial_status is null)
      );
  end if;
end;
$$;

comment on column public.land_sites.burial_status is
  'Only for burial plots: whether the plot can still take burials. A full or closed plot stays with its household for ever.';

-- Existing burial plots start usable; any legacy grazing is shut out.
update public.land_sites set burial_status = 'usable'
 where site_type = 'burial' and burial_status is null;
update public.land_sites set site_status = 'unavailable'
 where site_type = 'grazing';

create index if not exists land_sites_site_type_status_idx on public.land_sites (site_type, site_status);

-- ---------------------------------------------------------------------
-- 3. Land applications
-- ---------------------------------------------------------------------

create table if not exists public.land_applications (
  id                       uuid primary key default gen_random_uuid(),
  application_reference    text not null unique,
  applicant_resident_id    uuid not null references public.residents (id),
  applicant_user_account_id uuid references public.user_accounts (id),
  household_id             uuid not null references public.households (id),
  land_type                text not null,
  application_status       text not null default 'pending',

  reason_for_application   text not null,
  intended_use             text,
  -- Residential
  lives_with_household     boolean,
  -- Farming
  farming_type             text,
  farming_activity         text,
  -- Business
  business_name            text,
  business_type            text,
  business_description     text,

  submitted_at             timestamptz not null default now(),
  reviewed_at              timestamptz,
  reviewed_by_staff_id     uuid references public.staff (id),
  decline_reason           text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint land_applications_type_allowed
    check (land_type in ('residential', 'farming', 'business', 'burial')),
  constraint land_applications_status_allowed
    check (application_status in ('pending', 'approved', 'declined', 'allocated')),
  constraint land_applications_reason_present
    check (btrim(reason_for_application) <> ''),
  constraint land_applications_farming_type_allowed
    check (farming_type is null or farming_type in ('crop', 'livestock', 'mixed', 'other')),
  constraint land_applications_business_type_allowed
    check (business_type is null or business_type in ('shop', 'restaurant', 'salon', 'workshop', 'office', 'other')),
  constraint land_applications_review_shape check (
    (application_status = 'pending' and reviewed_at is null and reviewed_by_staff_id is null and decline_reason is null)
    or (application_status = 'declined' and reviewed_at is not null and reviewed_by_staff_id is not null
        and btrim(coalesce(decline_reason, '')) <> '')
    or (application_status in ('approved', 'allocated') and reviewed_at is not null
        and reviewed_by_staff_id is not null and decline_reason is null)
  )
);

comment on table public.land_applications is
  'One application for land. The applicant never chooses a site: the Land Officer allocates one after approval.';

create index if not exists land_applications_applicant_idx on public.land_applications (applicant_resident_id);
create index if not exists land_applications_household_idx on public.land_applications (household_id);
create index if not exists land_applications_status_idx on public.land_applications (application_status, land_type);

-- An applicant may not have two residential or business applications in
-- flight, and a household may not have two farming or burial ones.
create unique index if not exists land_applications_one_open_per_resident_idx
  on public.land_applications (applicant_resident_id, land_type)
  where application_status in ('pending', 'approved') and land_type in ('residential', 'business');

create unique index if not exists land_applications_one_open_per_household_idx
  on public.land_applications (household_id, land_type)
  where application_status in ('pending', 'approved') and land_type in ('farming', 'burial');

-- ---------------------------------------------------------------------
-- 4. Allocations gain what the four types need
--
--    The imported allocations are untouched: they keep their references,
--    their sites, their residents and their dates.
-- ---------------------------------------------------------------------

alter table public.land_allocations
  add column if not exists household_id            uuid references public.households (id),
  add column if not exists land_application_id     uuid references public.land_applications (id),
  add column if not exists land_type               text,
  add column if not exists ended_at                date,
  add column if not exists end_reason              text,
  add column if not exists ended_by_staff_id       uuid references public.staff (id),
  add column if not exists superseded_by_allocation_id uuid references public.land_allocations (id),
  add column if not exists succeeds_allocation_id  uuid references public.land_allocations (id);

-- Farming and burial land is held by a household, so there is not
-- always a resident to name.
alter table public.land_allocations alter column resident_id drop not null;

-- The imported allocations are all residential; fill in what the new
-- columns need from the records that already exist.
update public.land_allocations a
   set land_type = coalesce(a.land_type, s.site_type)
  from public.land_sites s
 where s.id = a.land_site_id and a.land_type is null;

update public.land_allocations a
   set household_id = r.household_id
  from public.residents r
 where r.id = a.resident_id and a.household_id is null;

alter table public.land_allocations alter column land_type set not null;

alter table public.land_allocations drop constraint if exists land_allocations_status_allowed;
alter table public.land_allocations
  add constraint land_allocations_status_allowed
  check (allocation_status in ('active', 'succession_pending', 'superseded', 'released'));

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'land_allocations_type_allowed') then
    alter table public.land_allocations
      add constraint land_allocations_type_allowed
      check (land_type in ('residential', 'farming', 'business', 'burial'));
  end if;

  -- Who holds it: residential and business name a resident, farming and
  -- burial name a household. Residential keeps the household too, which
  -- is what makes succession possible later.
  if not exists (select 1 from pg_constraint where conname = 'land_allocations_holder_shape') then
    alter table public.land_allocations
      add constraint land_allocations_holder_shape check (
        (land_type in ('residential', 'business') and resident_id is not null)
        or (land_type in ('farming', 'burial') and household_id is not null)
      );
  end if;
end;
$$;

create index if not exists land_allocations_household_idx on public.land_allocations (household_id);
create index if not exists land_allocations_type_status_idx on public.land_allocations (land_type, allocation_status);

-- Anything that writes an allocation without saying which kind of land
-- it is, or which household, can work it out from the site and the
-- resident. This is what keeps the legacy importer — written before
-- these columns existed — working exactly as it did.
create or replace function public.tg_land_allocation_defaults()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.land_type is null then
    select s.site_type into new.land_type from public.land_sites s where s.id = new.land_site_id;
  end if;
  if new.household_id is null and new.resident_id is not null then
    select r.household_id into new.household_id from public.residents r where r.id = new.resident_id;
  end if;
  return new;
end;
$$;

drop trigger if exists land_allocation_defaults on public.land_allocations;
create trigger land_allocation_defaults
  before insert on public.land_allocations
  for each row execute function public.tg_land_allocation_defaults();

-- A burial plot is usable unless somebody says otherwise.
create or replace function public.tg_land_site_defaults()
returns trigger
language plpgsql
as $$
begin
  if new.site_type = 'burial' and new.burial_status is null then
    new.burial_status := 'usable';
  elsif new.site_type <> 'burial' then
    new.burial_status := null;
  end if;
  return new;
end;
$$;

drop trigger if exists land_site_defaults on public.land_sites;
create trigger land_site_defaults
  before insert or update of site_type on public.land_sites
  for each row execute function public.tg_land_site_defaults();

-- ---- The hard limits, in the database itself -------------------------

-- A site carries one allocation that is not finished. succession_pending
-- counts: the site is not free while a succession is undecided.
drop index if exists public.land_allocations_one_active_per_site_idx;
create unique index if not exists land_allocations_one_open_per_site_idx
  on public.land_allocations (land_site_id)
  where allocation_status in ('active', 'succession_pending');

-- One residential stand and one business site per resident.
create unique index if not exists land_allocations_one_residential_per_resident_idx
  on public.land_allocations (resident_id)
  where land_type = 'residential' and allocation_status in ('active', 'succession_pending');

create unique index if not exists land_allocations_one_business_per_resident_idx
  on public.land_allocations (resident_id)
  where land_type = 'business' and allocation_status = 'active';

-- One farming allocation per household. Burial is deliberately absent:
-- a household may hold several plots over time, governed by whether any
-- is still usable.
create unique index if not exists land_allocations_one_farming_per_household_idx
  on public.land_allocations (household_id)
  where land_type = 'farming' and allocation_status = 'active';

-- ---------------------------------------------------------------------
-- 5. Permission to occupy
-- ---------------------------------------------------------------------

create table if not exists public.ptos (
  id                   uuid primary key default gen_random_uuid(),
  pto_number           text not null unique,
  land_allocation_id   uuid not null references public.land_allocations (id),
  land_type            text not null,
  holder_resident_id   uuid references public.residents (id),
  holder_household_id  uuid references public.households (id),
  issue_date           date not null default current_date,
  -- Null means perpetual. There is no fake far-future date anywhere.
  expiry_date          date,
  pto_status           text not null default 'active',
  superseded_by_pto_id uuid references public.ptos (id),
  renewed_from_pto_id  uuid references public.ptos (id),
  revoked_at           timestamptz,
  revocation_reason    text,
  revoked_by_staff_id  uuid references public.staff (id),
  issued_by_staff_id   uuid references public.staff (id),
  verification_token   text not null unique,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint ptos_type_allowed check (land_type in ('residential', 'farming', 'business', 'burial')),
  constraint ptos_status_allowed
    check (pto_status in ('active', 'expired', 'renewed', 'revoked', 'superseded')),
  -- Residential and burial are perpetual; farming and business are not.
  constraint ptos_term_shape check (
    (land_type in ('residential', 'burial') and expiry_date is null)
    or (land_type in ('farming', 'business') and expiry_date is not null and expiry_date > issue_date)
  ),
  constraint ptos_holder_shape check (
    (land_type in ('residential', 'business') and holder_resident_id is not null)
    or (land_type in ('farming', 'burial') and holder_household_id is not null)
  ),
  constraint ptos_revocation_shape check (
    pto_status <> 'revoked'
    or (revoked_at is not null and btrim(coalesce(revocation_reason, '')) <> '' and revoked_by_staff_id is not null)
  )
);

comment on table public.ptos is
  'A permission to occupy. Never edited into another: renewal and succession create a new one and leave the old on record.';

create index if not exists ptos_allocation_idx on public.ptos (land_allocation_id);
create index if not exists ptos_holder_resident_idx on public.ptos (holder_resident_id);
create index if not exists ptos_holder_household_idx on public.ptos (holder_household_id);
create index if not exists ptos_status_idx on public.ptos (pto_status);

-- One live permission per allocation.
create unique index if not exists ptos_one_active_per_allocation_idx
  on public.ptos (land_allocation_id)
  where pto_status = 'active';

-- ---------------------------------------------------------------------
-- 6. Renewal requests
-- ---------------------------------------------------------------------

create table if not exists public.pto_renewal_requests (
  id                    uuid primary key default gen_random_uuid(),
  pto_id                uuid not null references public.ptos (id),
  requested_by_resident_id uuid not null references public.residents (id),
  request_status        text not null default 'pending',
  reason                text,
  requested_at          timestamptz not null default now(),
  reviewed_at           timestamptz,
  reviewed_by_staff_id  uuid references public.staff (id),
  decline_reason        text,
  resulting_pto_id      uuid references public.ptos (id),
  created_at            timestamptz not null default now(),

  constraint pto_renewal_requests_status_allowed
    check (request_status in ('pending', 'approved', 'declined')),
  constraint pto_renewal_requests_review_shape check (
    (request_status = 'pending' and reviewed_at is null and decline_reason is null and resulting_pto_id is null)
    or (request_status = 'approved' and reviewed_at is not null and reviewed_by_staff_id is not null
        and resulting_pto_id is not null and decline_reason is null)
    or (request_status = 'declined' and reviewed_at is not null and reviewed_by_staff_id is not null
        and btrim(coalesce(decline_reason, '')) <> '')
  )
);

create index if not exists pto_renewal_requests_pto_idx on public.pto_renewal_requests (pto_id);

-- One open request per permission.
create unique index if not exists pto_renewal_requests_one_open_idx
  on public.pto_renewal_requests (pto_id)
  where request_status = 'pending';

-- ---------------------------------------------------------------------
-- 7. Row Level Security
--
--    Reads are policy-driven; every write goes through the functions in
--    the next migration, which establish the caller for themselves.
-- ---------------------------------------------------------------------

alter table public.land_applications     enable row level security;
alter table public.ptos                  enable row level security;
alter table public.pto_renewal_requests  enable row level security;
alter table public.land_applications     force row level security;
alter table public.ptos                  force row level security;
alter table public.pto_renewal_requests  force row level security;

revoke all on public.land_applications    from anon, authenticated;
revoke all on public.ptos                 from anon, authenticated;
revoke all on public.pto_renewal_requests from anon, authenticated;
grant select on public.land_applications    to authenticated;
grant select on public.ptos                 to authenticated;
grant select on public.pto_renewal_requests to authenticated;
grant all on public.land_applications    to service_role;
grant all on public.ptos                 to service_role;
grant all on public.pto_renewal_requests to service_role;


-- ---------------------------------------------------------------------
-- 20260926090000_land_functions.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — land applications, allocation, permission to occupy
--
-- Every privileged operation establishes its caller from auth.uid() and
-- rechecks eligibility for itself. An eligibility answer worked out
-- earlier — when the form was shown, or when the application was
-- approved — is never taken as still true at the next step.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who is a Land Officer
-- ---------------------------------------------------------------------

create or replace function public.is_active_land_officer()
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Land Officer');
$$;

create or replace function public.acting_land_officer_staff_id()
returns uuid
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff_id uuid;
begin
  select s.id into v_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Land Officer';

  if v_staff_id is null then
    raise exception 'Only an active Land Officer may do that.' using errcode = '42501';
  end if;
  return v_staff_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Age, counted properly
--
--    From the official date of birth on the register, never from
--    anything typed into a form, and by adding years to the birth date
--    rather than subtracting numbers — so leap years look after
--    themselves.
-- ---------------------------------------------------------------------

create or replace function public.is_at_least_age(p_date_of_birth date, p_years int)
returns boolean
language sql immutable
as $$
  select p_date_of_birth is not null
     and (p_date_of_birth + make_interval(years => p_years)) <= current_date;
$$;

comment on function public.is_at_least_age(date, int) is
  'True on the birthday itself. Uses date arithmetic, not a subtraction of year numbers.';

-- ---------------------------------------------------------------------
-- 3. What a permission is actually worth today
--
--    A fixed term runs out whether or not anybody has refreshed a
--    stored status, so every rights decision asks this, not the column.
-- ---------------------------------------------------------------------

create or replace function public.pto_effective_status(p_stored_status text, p_expiry_date date)
returns text
language sql immutable
as $$
  select case
    when p_stored_status <> 'active' then p_stored_status
    when p_expiry_date is not null and p_expiry_date < current_date then 'expired'
    else 'active'
  end;
$$;

-- ---------------------------------------------------------------------
-- 4. The resident behind the signed-in account
-- ---------------------------------------------------------------------

create or replace function public.current_resident_id()
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select ua.resident_id
  from public.user_accounts ua
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'resident'
    and ua.account_status = 'active'
    and ua.resident_id is not null;
$$;

-- The households this resident heads.
--
-- A policy that asked `select id from households where head_resident_id = …`
-- inline would read households under Row Level Security, which gives a
-- resident nothing — so the household-head half of every policy below
-- would quietly match nothing. This looks for them as the definer, and
-- can only ever return households the caller actually heads.
create or replace function public.current_resident_headed_household_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select h.id from public.households h
  where h.head_resident_id = public.current_resident_id();
$$;

-- ---------------------------------------------------------------------
-- 5. May this person have this kind of land?
--
--    One answer, asked at every stage: showing the form, submitting,
--    approving and allocating.
-- ---------------------------------------------------------------------

create or replace function public.land_eligibility(p_resident_id uuid, p_land_type text)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_resident  public.residents;
  v_household public.households;
  v_account   public.user_accounts;
  v_problems  text[] := '{}';
  v_is_head   boolean := false;
begin
  if p_land_type is null or not (p_land_type = any (public.allocatable_land_types())) then
    return jsonb_build_object('eligible', false, 'problems', array['That is not a kind of land TAMS allocates.']);
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    return jsonb_build_object('eligible', false, 'problems', array['That person is not on the village register.']);
  end if;

  if v_resident.resident_status <> 'active' then
    v_problems := array_append(v_problems, format('The register records this person as %s.', v_resident.resident_status));
  end if;

  -- Age comes from the register, not from the application.
  if not public.is_at_least_age(v_resident.date_of_birth, 21) then
    v_problems := array_append(v_problems, 'An applicant must be at least 21 years old.');
  end if;

  select * into v_account from public.user_accounts
  where resident_id = p_resident_id and account_type = 'resident';
  if not found or v_account.account_status <> 'active' then
    v_problems := array_append(v_problems, 'A verified, active resident account is needed to apply.');
  end if;

  if v_resident.household_id is null then
    v_problems := array_append(v_problems, 'This person is not linked to a household.');
  else
    select * into v_household from public.households where id = v_resident.household_id;
    if not found or v_household.household_status <> 'active' then
      v_problems := array_append(v_problems, 'This person''s household is not current.');
    else
      v_is_head := (v_household.head_resident_id = v_resident.id);
    end if;
  end if;

  -- ---- what each kind of land asks on top ---------------------------
  if p_land_type = 'residential' then
    if exists (select 1 from public.land_allocations a
                where a.resident_id = p_resident_id and a.land_type = 'residential'
                  and a.allocation_status in ('active', 'succession_pending')) then
      v_problems := array_append(v_problems, 'This person already holds a residential stand.');
    end if;

  elsif p_land_type = 'business' then
    -- An expired permission does not free the site. The allocation has
    -- to be released by the Land Officer first.
    if exists (select 1 from public.land_allocations a
                where a.resident_id = p_resident_id and a.land_type = 'business'
                  and a.allocation_status = 'active') then
      v_problems := array_append(v_problems, 'This person already holds a business site. It has to be released before another is given.');
    end if;

  elsif p_land_type = 'farming' then
    if not v_is_head then
      v_problems := array_append(v_problems, 'Only the current head of the household may apply for farming land.');
    end if;
    if v_resident.household_id is not null
       and exists (select 1 from public.land_allocations a
                    where a.household_id = v_resident.household_id and a.land_type = 'farming'
                      and a.allocation_status = 'active') then
      v_problems := array_append(v_problems, 'This household already holds farming land.');
    end if;

  elsif p_land_type = 'burial' then
    if not v_is_head then
      v_problems := array_append(v_problems, 'Only the current head of the household may apply for a burial plot.');
    end if;
    -- Another plot only once every plot the household holds is full or
    -- closed. A usable plot means there is nowhere else to be.
    if v_resident.household_id is not null
       and exists (select 1 from public.land_allocations a
                    join public.land_sites s on s.id = a.land_site_id
                    where a.household_id = v_resident.household_id
                      and a.land_type = 'burial'
                      and a.allocation_status = 'active'
                      and s.burial_status = 'usable') then
      v_problems := array_append(v_problems, 'This household still has a burial plot with space in it.');
    end if;
  end if;

  return jsonb_build_object(
    'eligible',          array_length(v_problems, 1) is null,
    'problems',          to_jsonb(v_problems),
    'resident_id',       p_resident_id,
    'household_id',      v_resident.household_id,
    'is_household_head', v_is_head,
    'land_type',         p_land_type);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Reference numbers, worked out from what is in the database
-- ---------------------------------------------------------------------

create or replace function public.next_reference(p_prefix text, p_column text, p_table text, p_width int default 4)
returns text
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_highest int;
begin
  execute format(
    'select coalesce(max((regexp_match(%I, %L))[1]::int), 0) from public.%I where %I ~ %L',
    p_column, '^' || p_prefix || '(\d+)$', p_table, p_column, '^' || p_prefix || '\d+$')
  into v_highest;
  return p_prefix || lpad((v_highest + 1)::text, p_width, '0');
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Reading: what the applicant and the officer may see
-- ---------------------------------------------------------------------

-- A resident sees their own applications, and the household's farming
-- and burial ones when they are the head of it.
drop policy if exists land_applications_readable on public.land_applications;
create policy land_applications_readable
  on public.land_applications for select to authenticated
  using (
    public.is_active_land_officer()
    or public.is_active_registry_clerk()
    or applicant_resident_id = public.current_resident_id()
    or (land_type in ('farming', 'burial')
        and household_id in (select public.current_resident_headed_household_ids()))
  );

drop policy if exists ptos_readable on public.ptos;
create policy ptos_readable
  on public.ptos for select to authenticated
  using (
    public.is_active_land_officer()
    or public.is_active_registry_clerk()
    or holder_resident_id = public.current_resident_id()
    or holder_household_id in (select public.current_resident_headed_household_ids())
  );

drop policy if exists pto_renewal_requests_readable on public.pto_renewal_requests;
create policy pto_renewal_requests_readable
  on public.pto_renewal_requests for select to authenticated
  using (
    public.is_active_land_officer()
    or requested_by_resident_id = public.current_resident_id()
  );

-- The Land Officer reads the register and the sites for context, and
-- writes neither directly: every change goes through a function.
drop policy if exists land_sites_readable_by_land_officer on public.land_sites;
create policy land_sites_readable_by_land_officer
  on public.land_sites for select to authenticated
  using (public.is_active_land_officer());

drop policy if exists land_allocations_readable_by_land_officer on public.land_allocations;
create policy land_allocations_readable_by_land_officer
  on public.land_allocations for select to authenticated
  using (
    public.is_active_land_officer()
    or resident_id = public.current_resident_id()
    or household_id in (select public.current_resident_headed_household_ids())
  );

drop policy if exists residents_readable_by_land_officer on public.residents;
create policy residents_readable_by_land_officer
  on public.residents for select to authenticated
  using (public.is_active_land_officer());

drop policy if exists households_readable_by_land_officer on public.households;
create policy households_readable_by_land_officer
  on public.households for select to authenticated
  using (public.is_active_land_officer());

drop policy if exists family_relationships_readable_by_land_officer on public.family_relationships;
create policy family_relationships_readable_by_land_officer
  on public.family_relationships for select to authenticated
  using (public.is_active_land_officer());

-- ---------------------------------------------------------------------
-- 8. A resident applies
-- ---------------------------------------------------------------------

create or replace function public.resident_land_eligibility(p_land_type text)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_resident_id uuid := public.current_resident_id();
begin
  if v_resident_id is null then
    raise exception 'Only a verified resident may apply for land.' using errcode = '42501';
  end if;
  return public.land_eligibility(v_resident_id, p_land_type);
end;
$$;

create or replace function public.resident_submit_land_application(
  p_land_type text,
  p_details   jsonb
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_resident_id  uuid := public.current_resident_id();
  v_eligibility  jsonb;
  v_resident     public.residents;
  v_account_id   uuid;
  v_application  public.land_applications;
  v_reason       text := btrim(coalesce(p_details ->> 'reason_for_application', ''));
begin
  if v_resident_id is null then
    raise exception 'Only a verified resident may apply for land.' using errcode = '42501';
  end if;

  v_eligibility := public.land_eligibility(v_resident_id, p_land_type);
  if not (v_eligibility ->> 'eligible')::boolean then
    raise exception '%', (select string_agg(value, ' ') from jsonb_array_elements_text(v_eligibility -> 'problems'))
      using errcode = 'TA060';
  end if;

  if v_reason = '' then
    raise exception 'A reason for the application is required.' using errcode = 'TA061';
  end if;

  if p_land_type = 'farming'
     and coalesce(p_details ->> 'farming_type', '') not in ('crop', 'livestock', 'mixed', 'other') then
    raise exception 'Choose the kind of farming this land is for.' using errcode = 'TA061';
  end if;
  if p_land_type = 'business'
     and coalesce(p_details ->> 'business_type', '') not in ('shop', 'restaurant', 'salon', 'workshop', 'office', 'other') then
    raise exception 'Choose the kind of business this site is for.' using errcode = 'TA061';
  end if;

  select * into v_resident from public.residents where id = v_resident_id;
  select id into v_account_id from public.user_accounts where resident_id = v_resident_id;

  begin
    insert into public.land_applications (
      application_reference, applicant_resident_id, applicant_user_account_id, household_id,
      land_type, reason_for_application, intended_use, lives_with_household,
      farming_type, farming_activity, business_name, business_type, business_description)
    values (
      public.next_reference('APP-', 'application_reference', 'land_applications', 5),
      v_resident_id, v_account_id, v_resident.household_id,
      p_land_type, v_reason,
      nullif(btrim(coalesce(p_details ->> 'intended_use', '')), ''),
      case when p_land_type = 'residential' then (p_details ->> 'lives_with_household')::boolean end,
      case when p_land_type = 'farming' then p_details ->> 'farming_type' end,
      case when p_land_type = 'farming' then nullif(btrim(coalesce(p_details ->> 'farming_activity', '')), '') end,
      case when p_land_type = 'business' then nullif(btrim(coalesce(p_details ->> 'business_name', '')), '') end,
      case when p_land_type = 'business' then p_details ->> 'business_type' end,
      case when p_land_type = 'business' then nullif(btrim(coalesce(p_details ->> 'business_description', '')), '') end)
    returning * into v_application;
  exception when unique_violation then
    raise exception 'There is already an application of this kind waiting to be dealt with.'
      using errcode = 'TA062';
  end;

  return jsonb_build_object(
    'application_id',        v_application.id,
    'application_reference', v_application.application_reference,
    'land_type',             v_application.land_type,
    'application_status',    v_application.application_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Land sites
-- ---------------------------------------------------------------------

create or replace function public.land_officer_register_site(
  p_site_code       text,
  p_site_type       text,
  p_street_address  text,
  p_stand_number    text default null,
  p_village_section text default null,
  p_village_name    text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_code text := btrim(coalesce(p_site_code, ''));
  v_site public.land_sites;
begin
  perform public.acting_land_officer_staff_id();

  if v_code = '' or btrim(coalesce(p_street_address, '')) = '' then
    raise exception 'A site code and a street address are required.' using errcode = 'TA063';
  end if;

  -- Only the four. Grazing is not allocated through TAMS.
  if not (p_site_type = any (public.allocatable_land_types())) then
    raise exception '% is not a kind of land TAMS allocates.', coalesce(p_site_type, '(none)')
      using errcode = 'TA064';
  end if;

  if exists (select 1 from public.land_sites where upper(site_code) = upper(v_code)) then
    raise exception 'Site code % is already in use.', v_code using errcode = 'TA065';
  end if;

  insert into public.land_sites (site_code, site_type, stand_number, street_address,
                                 village_section, village_name, site_status, burial_status)
  values (v_code, p_site_type, nullif(btrim(coalesce(p_stand_number, '')), ''), btrim(p_street_address),
          nullif(btrim(coalesce(p_village_section, '')), ''), nullif(btrim(coalesce(p_village_name, '')), ''),
          'available', case when p_site_type = 'burial' then 'usable' end)
  returning * into v_site;

  return jsonb_build_object('site_id', v_site.id, 'site_code', v_site.site_code,
                            'site_type', v_site.site_type, 'site_status', v_site.site_status);
end;
$$;

create or replace function public.land_officer_update_site(
  p_site_id         uuid,
  p_site_type       text,
  p_street_address  text,
  p_stand_number    text default null,
  p_village_section text default null,
  p_village_name    text default null,
  p_site_status     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_site   public.land_sites;
  v_open   boolean;
  v_status text;
begin
  perform public.acting_land_officer_staff_id();

  select * into v_site from public.land_sites where id = p_site_id for update;
  if not found then
    raise exception 'That land site could not be found.' using errcode = 'TA066';
  end if;

  v_open := exists (select 1 from public.land_allocations a
                     where a.land_site_id = v_site.id
                       and a.allocation_status in ('active', 'succession_pending'));

  if p_site_type is distinct from v_site.site_type then
    if v_open then
      raise exception 'Site % is allocated, so its type cannot be changed.', v_site.site_code
        using errcode = 'TA067';
    end if;
    if exists (select 1 from public.land_allocations a where a.land_site_id = v_site.id) then
      raise exception 'Site % has allocation history, so its type cannot be changed.', v_site.site_code
        using errcode = 'TA067';
    end if;
    if not (p_site_type = any (public.allocatable_land_types())) then
      raise exception '% is not a kind of land TAMS allocates.', coalesce(p_site_type, '(none)')
        using errcode = 'TA064';
    end if;
  end if;

  v_status := coalesce(p_site_status, v_site.site_status);
  if v_status not in ('available', 'allocated', 'unavailable') then
    raise exception 'A site is available, allocated or unavailable.' using errcode = 'TA068';
  end if;
  -- An allocated site is not made free by editing it. Release the
  -- allocation instead.
  if v_open and v_status <> 'allocated' then
    raise exception 'Site % is allocated. Release the allocation before changing its status.', v_site.site_code
      using errcode = 'TA068';
  end if;

  update public.land_sites
     set site_type = p_site_type,
         street_address = btrim(p_street_address),
         stand_number = nullif(btrim(coalesce(p_stand_number, '')), ''),
         village_section = nullif(btrim(coalesce(p_village_section, '')), ''),
         village_name = nullif(btrim(coalesce(p_village_name, '')), ''),
         site_status = v_status,
         burial_status = case when p_site_type = 'burial' then coalesce(v_site.burial_status, 'usable') end
   where id = v_site.id
  returning * into v_site;

  return jsonb_build_object('site_id', v_site.id, 'site_code', v_site.site_code,
                            'site_type', v_site.site_type, 'site_status', v_site.site_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Reviewing an application
-- ---------------------------------------------------------------------

create or replace function public.land_officer_applications(
  p_status text default null,
  p_land_type text default null,
  p_search text default null
)
returns table (
  application_id        uuid,
  application_reference text,
  land_type             text,
  application_status    text,
  applicant_name        text,
  applicant_id_number   text,
  applicant_age         int,
  household_code        text,
  submitted_at          timestamptz,
  reviewed_at           timestamptz,
  decline_reason        text,
  allocated_site_code   text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_land_officer_staff_id();

  return query
    select a.id, a.application_reference, a.land_type, a.application_status,
           r.first_name || ' ' || r.last_name, r.id_number,
           extract(year from age(current_date, r.date_of_birth))::int,
           h.household_code, a.submitted_at, a.reviewed_at, a.decline_reason,
           (select s.site_code from public.land_allocations al
             join public.land_sites s on s.id = al.land_site_id
             where al.land_application_id = a.id limit 1)
    from public.land_applications a
    join public.residents r on r.id = a.applicant_resident_id
    join public.households h on h.id = a.household_id
    where (p_status is null or a.application_status = p_status)
      and (p_land_type is null or a.land_type = p_land_type)
      and (v_empty
           or a.application_reference ilike v_pattern
           or r.first_name ilike v_pattern or r.last_name ilike v_pattern
           or (r.first_name || ' ' || r.last_name) ilike v_pattern
           or r.id_number ilike v_pattern
           or h.household_code ilike v_pattern)
    order by a.submitted_at desc;
end;
$$;

-- Everything the officer needs to judge one application, all of it read
-- only. Identity, household and family are the Registry Clerk's to
-- change, not this function's.
create or replace function public.land_officer_application(p_application_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.acting_land_officer_staff_id();

  select jsonb_build_object(
    'application_id',        a.id,
    'application_reference', a.application_reference,
    'land_type',             a.land_type,
    'application_status',    a.application_status,
    'reason_for_application', a.reason_for_application,
    'intended_use',          a.intended_use,
    'lives_with_household',  a.lives_with_household,
    'farming_type',          a.farming_type,
    'farming_activity',      a.farming_activity,
    'business_name',         a.business_name,
    'business_type',         a.business_type,
    'business_description',  a.business_description,
    'submitted_at',          a.submitted_at,
    'reviewed_at',           a.reviewed_at,
    'decline_reason',        a.decline_reason,
    'applicant', jsonb_build_object(
      'resident_id',     r.id,
      'full_name',       r.first_name || ' ' || r.last_name,
      'id_number',       r.id_number,
      'date_of_birth',   r.date_of_birth,
      'age',             extract(year from age(current_date, r.date_of_birth))::int,
      'gender',          r.gender,
      'resident_status', r.resident_status,
      'account_status',  (select ua.account_status from public.user_accounts ua where ua.resident_id = r.id)),
    'household', jsonb_build_object(
      'household_id',     h.id,
      'household_code',   h.household_code,
      'household_status', h.household_status,
      'head_full_name',   (select head.first_name || ' ' || head.last_name
                             from public.residents head where head.id = h.head_resident_id),
      'is_head',          (h.head_resident_id = r.id),
      'members', coalesce((select jsonb_agg(jsonb_build_object(
                             'full_name', m.first_name || ' ' || m.last_name,
                             'resident_status', m.resident_status,
                             'age', extract(year from age(current_date, m.date_of_birth))::int)
                           order by m.date_of_birth)
                           from public.residents m where m.household_id = h.id), '[]'::jsonb)),
    'family', coalesce((select jsonb_agg(jsonb_build_object(
                          'relationship_type', f.relationship_type,
                          'related_full_name', o.first_name || ' ' || o.last_name,
                          'relationship_status', f.relationship_status)
                        order by f.relationship_type)
                        from public.family_relationships f
                        join public.residents o on o.id = f.related_resident_id
                        where f.resident_id = r.id and f.relationship_status = 'active'), '[]'::jsonb),
    'land_held', coalesce((select jsonb_agg(jsonb_build_object(
                             'allocation_reference', al.allocation_reference,
                             'land_type',  al.land_type,
                             'site_code',  s.site_code,
                             'allocation_status', al.allocation_status,
                             'burial_status', s.burial_status,
                             'held_by', case when al.resident_id is not null then 'resident' else 'household' end)
                           order by al.land_type)
                           from public.land_allocations al
                           join public.land_sites s on s.id = al.land_site_id
                           where (al.resident_id = r.id or al.household_id = h.id)
                             and al.allocation_status in ('active', 'succession_pending')), '[]'::jsonb),
    'earlier_applications', coalesce((select jsonb_agg(jsonb_build_object(
                             'application_reference', e.application_reference,
                             'land_type', e.land_type,
                             'application_status', e.application_status,
                             'submitted_at', e.submitted_at,
                             'decline_reason', e.decline_reason)
                           order by e.submitted_at desc)
                           from public.land_applications e
                           where e.applicant_resident_id = r.id and e.id <> a.id), '[]'::jsonb),
    'eligibility', public.land_eligibility(r.id, a.land_type)
  ) into v_result
  from public.land_applications a
  join public.residents r on r.id = a.applicant_resident_id
  join public.households h on h.id = a.household_id
  where a.id = p_application_id;

  if v_result is null then
    raise exception 'That application could not be found.' using errcode = 'TA069';
  end if;
  return v_result;
end;
$$;

create or replace function public.land_officer_approve_application(p_application_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id    uuid := public.acting_land_officer_staff_id();
  v_application public.land_applications;
  v_eligibility jsonb;
begin
  select * into v_application from public.land_applications where id = p_application_id for update;
  if not found then
    raise exception 'That application could not be found.' using errcode = 'TA069';
  end if;
  if v_application.application_status <> 'pending' then
    raise exception 'That application has already been %.', v_application.application_status
      using errcode = 'TA069';
  end if;

  -- Asked again, now. Circumstances move between applying and deciding.
  v_eligibility := public.land_eligibility(v_application.applicant_resident_id, v_application.land_type);
  if not (v_eligibility ->> 'eligible')::boolean then
    raise exception '%', (select string_agg(value, ' ') from jsonb_array_elements_text(v_eligibility -> 'problems'))
      using errcode = 'TA060';
  end if;

  update public.land_applications
     set application_status = 'approved', reviewed_at = now(), reviewed_by_staff_id = v_staff_id
   where id = v_application.id;

  return jsonb_build_object('application_id', v_application.id,
                            'application_reference', v_application.application_reference,
                            'application_status', 'approved');
end;
$$;

create or replace function public.land_officer_decline_application(
  p_application_id uuid,
  p_reason text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_land_officer_staff_id();
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_application public.land_applications;
begin
  if v_reason = '' then
    raise exception 'A reason is required, so the applicant knows why.' using errcode = 'TA061';
  end if;

  select * into v_application from public.land_applications where id = p_application_id for update;
  if not found then
    raise exception 'That application could not be found.' using errcode = 'TA069';
  end if;
  if v_application.application_status <> 'pending' then
    raise exception 'That application has already been %.', v_application.application_status
      using errcode = 'TA069';
  end if;

  update public.land_applications
     set application_status = 'declined', decline_reason = v_reason,
         reviewed_at = now(), reviewed_by_staff_id = v_staff_id
   where id = v_application.id;

  return jsonb_build_object('application_id', v_application.id, 'application_status', 'declined',
                            'decline_reason', v_reason);
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Allocating a site
--
--     One transaction: the site is locked, everything is rechecked, the
--     allocation is written, the site is marked and the application is
--     closed. Two officers acting at once cannot both win — the unique
--     indexes on open allocations settle it in the database.
-- ---------------------------------------------------------------------

create or replace function public.land_officer_available_sites(p_land_type text)
returns table (site_id uuid, site_code text, stand_number text, street_address text,
               village_section text, village_name text)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_land_officer_staff_id();
  return query
    select s.id, s.site_code, s.stand_number, s.street_address, s.village_section, s.village_name
    from public.land_sites s
    where s.site_type = p_land_type
      and s.site_status = 'available'
      and (s.site_type <> 'burial' or s.burial_status = 'usable')
      and not exists (select 1 from public.land_allocations a
                       where a.land_site_id = s.id
                         and a.allocation_status in ('active', 'succession_pending'))
    order by s.site_code;
end;
$$;

create or replace function public.land_officer_allocate_site(
  p_application_id uuid,
  p_site_id        uuid
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id    uuid := public.acting_land_officer_staff_id();
  v_application public.land_applications;
  v_site        public.land_sites;
  v_eligibility jsonb;
  v_allocation  public.land_allocations;
  v_resident    public.residents;
begin
  select * into v_application from public.land_applications where id = p_application_id for update;
  if not found then
    raise exception 'That application could not be found.' using errcode = 'TA069';
  end if;
  if v_application.application_status <> 'approved' then
    raise exception 'Only an approved application can be given a site. This one is %.',
      v_application.application_status using errcode = 'TA069';
  end if;

  -- Locking the site is what makes two simultaneous allocations
  -- impossible rather than merely unlikely.
  select * into v_site from public.land_sites where id = p_site_id for update;
  if not found then
    raise exception 'That land site could not be found.' using errcode = 'TA066';
  end if;
  if v_site.site_type <> v_application.land_type then
    raise exception 'Site % is % land, but this is a % application.',
      v_site.site_code, v_site.site_type, v_application.land_type using errcode = 'TA070';
  end if;
  if v_site.site_status <> 'available'
     or exists (select 1 from public.land_allocations a
                 where a.land_site_id = v_site.id
                   and a.allocation_status in ('active', 'succession_pending')) then
    raise exception 'Site % is not available.', v_site.site_code using errcode = 'TA071';
  end if;
  if v_site.site_type = 'burial' and v_site.burial_status <> 'usable' then
    raise exception 'Burial plot % is %, so it cannot be allocated.', v_site.site_code, v_site.burial_status
      using errcode = 'TA071';
  end if;

  v_eligibility := public.land_eligibility(v_application.applicant_resident_id, v_application.land_type);
  if not (v_eligibility ->> 'eligible')::boolean then
    raise exception '%', (select string_agg(value, ' ') from jsonb_array_elements_text(v_eligibility -> 'problems'))
      using errcode = 'TA060';
  end if;

  select * into v_resident from public.residents where id = v_application.applicant_resident_id;

  begin
    insert into public.land_allocations (
      allocation_reference, land_site_id, resident_id, household_id, land_application_id,
      land_type, allocation_date, allocation_status)
    values (
      public.next_reference('ALLOC-', 'allocation_reference', 'land_allocations', 4),
      v_site.id,
      -- Residential and business are held by the person; farming and
      -- burial by the household. Residential keeps the household too,
      -- which is what succession later depends on.
      case when v_application.land_type in ('residential', 'business') then v_resident.id end,
      v_application.household_id,
      v_application.id,
      v_application.land_type, current_date, 'active')
    returning * into v_allocation;
  exception when unique_violation then
    raise exception 'That site or that applicant already has a current allocation.' using errcode = 'TA071';
  end;

  update public.land_sites set site_status = 'allocated' where id = v_site.id;
  update public.land_applications set application_status = 'allocated' where id = v_application.id;

  return jsonb_build_object(
    'allocation_id',        v_allocation.id,
    'allocation_reference', v_allocation.allocation_reference,
    'site_code',            v_site.site_code,
    'land_type',            v_allocation.land_type,
    'application_status',   'allocated');
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Issuing a permission to occupy
--
--     Every field comes from the allocation and the register. The
--     officer types nothing: not the holder, not the site, not the
--     duration.
-- ---------------------------------------------------------------------

create or replace function public.pto_term_end(p_land_type text, p_from date)
returns date
language sql immutable
as $$
  select case p_land_type
    when 'farming'  then (p_from + make_interval(years => 5))::date
    when 'business' then (p_from + make_interval(years => 2))::date
    else null   -- residential and burial are perpetual
  end;
$$;

create or replace function public.land_officer_issue_pto(p_allocation_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_land_officer_staff_id();
  v_allocation public.land_allocations;
  v_prefix     text;
  v_pto        public.ptos;
begin
  select * into v_allocation from public.land_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;
  if v_allocation.allocation_status <> 'active' then
    raise exception 'That allocation is %, so no permission can be issued against it.',
      v_allocation.allocation_status using errcode = 'TA072';
  end if;
  if exists (select 1 from public.ptos p
              where p.land_allocation_id = v_allocation.id and p.pto_status = 'active') then
    raise exception 'That allocation already has a current permission to occupy.' using errcode = 'TA073';
  end if;

  v_prefix := case v_allocation.land_type
                when 'residential' then 'PTO-RES-'
                when 'farming'     then 'PTO-FRM-'
                when 'business'    then 'PTO-BUS-'
                else 'PTO-BUR-' end;

  insert into public.ptos (
    pto_number, land_allocation_id, land_type, holder_resident_id, holder_household_id,
    issue_date, expiry_date, pto_status, issued_by_staff_id, verification_token)
  values (
    public.next_reference(v_prefix, 'pto_number', 'ptos', 4),
    v_allocation.id, v_allocation.land_type,
    case when v_allocation.land_type in ('residential', 'business') then v_allocation.resident_id end,
    case when v_allocation.land_type in ('farming', 'burial') then v_allocation.household_id end,
    current_date,
    public.pto_term_end(v_allocation.land_type, current_date),
    'active', v_staff_id,
    encode(gen_random_bytes(16), 'hex'))
  returning * into v_pto;

  return jsonb_build_object(
    'pto_id',     v_pto.id,
    'pto_number', v_pto.pto_number,
    'land_type',  v_pto.land_type,
    'issue_date', v_pto.issue_date,
    'expiry_date', v_pto.expiry_date,
    'perpetual',  (v_pto.expiry_date is null),
    'verification_token', v_pto.verification_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 13. Renewal — only what has a term to renew
-- ---------------------------------------------------------------------

create or replace function public.resident_request_pto_renewal(p_pto_id uuid, p_reason text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_resident_id uuid := public.current_resident_id();
  v_pto         public.ptos;
  v_allocation  public.land_allocations;
  v_request     public.pto_renewal_requests;
begin
  if v_resident_id is null then
    raise exception 'Only a verified resident may ask for a renewal.' using errcode = '42501';
  end if;

  select * into v_pto from public.ptos where id = p_pto_id for update;
  if not found then
    raise exception 'That permission could not be found.' using errcode = 'TA074';
  end if;

  -- Perpetual permissions are not renewed; there is nothing to renew.
  if v_pto.land_type not in ('farming', 'business') then
    raise exception 'A % permission to occupy is perpetual and is not renewed.', v_pto.land_type
      using errcode = 'TA075';
  end if;
  if v_pto.pto_status in ('revoked', 'superseded') then
    raise exception 'That permission was %, so it cannot be renewed.', v_pto.pto_status
      using errcode = 'TA076';
  end if;
  if v_pto.pto_status = 'renewed' then
    raise exception 'That permission has already been renewed.' using errcode = 'TA076';
  end if;

  -- Business is the holder's own; farming belongs to the household and
  -- is asked for by whoever heads it now.
  if v_pto.land_type = 'business' then
    if v_pto.holder_resident_id <> v_resident_id then
      raise exception 'That permission is not yours.' using errcode = '42501';
    end if;
  else
    if not exists (select 1 from public.households h
                    where h.id = v_pto.holder_household_id and h.head_resident_id = v_resident_id) then
      raise exception 'Only the current head of the household may renew the household''s farming permission.'
        using errcode = '42501';
    end if;
  end if;

  select * into v_allocation from public.land_allocations where id = v_pto.land_allocation_id;
  if v_allocation.allocation_status <> 'active' then
    raise exception 'The allocation behind that permission is no longer current.' using errcode = 'TA076';
  end if;

  begin
    insert into public.pto_renewal_requests (pto_id, requested_by_resident_id, reason)
    values (v_pto.id, v_resident_id, nullif(btrim(coalesce(p_reason, '')), ''))
    returning * into v_request;
  exception when unique_violation then
    raise exception 'A renewal request for that permission is already waiting.' using errcode = 'TA077';
  end;

  return jsonb_build_object('renewal_request_id', v_request.id, 'pto_number', v_pto.pto_number,
                            'request_status', 'pending');
end;
$$;

create or replace function public.land_officer_renewal_requests(p_status text default 'pending')
returns table (
  renewal_request_id uuid, pto_number text, land_type text, site_code text,
  holder_name text, household_code text, expiry_date date, effective_status text,
  requested_at timestamptz, request_status text, reason text, decline_reason text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_land_officer_staff_id();
  return query
    select q.id, p.pto_number, p.land_type, s.site_code,
           (select r.first_name || ' ' || r.last_name from public.residents r where r.id = p.holder_resident_id),
           (select h.household_code from public.households h where h.id = p.holder_household_id),
           p.expiry_date, public.pto_effective_status(p.pto_status, p.expiry_date),
           q.requested_at, q.request_status, q.reason, q.decline_reason
    from public.pto_renewal_requests q
    join public.ptos p on p.id = q.pto_id
    join public.land_allocations a on a.id = p.land_allocation_id
    join public.land_sites s on s.id = a.land_site_id
    where (p_status is null or q.request_status = p_status)
    order by q.requested_at;
end;
$$;

-- Approving writes a NEW permission and marks the old one renewed. The
-- old one is never edited into the new one.
create or replace function public.land_officer_approve_renewal(p_request_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_land_officer_staff_id();
  v_request    public.pto_renewal_requests;
  v_old        public.ptos;
  v_allocation public.land_allocations;
  v_start      date;
  v_prefix     text;
  v_new        public.ptos;
begin
  select * into v_request from public.pto_renewal_requests where id = p_request_id for update;
  if not found then
    raise exception 'That renewal request could not be found.' using errcode = 'TA077';
  end if;
  if v_request.request_status <> 'pending' then
    raise exception 'That renewal request has already been %.', v_request.request_status using errcode = 'TA077';
  end if;

  select * into v_old from public.ptos where id = v_request.pto_id for update;
  if v_old.pto_status not in ('active', 'expired') then
    raise exception 'That permission is %, so it cannot be renewed.', v_old.pto_status using errcode = 'TA076';
  end if;

  select * into v_allocation from public.land_allocations where id = v_old.land_allocation_id for update;
  if v_allocation.allocation_status <> 'active' then
    raise exception 'The allocation behind that permission is no longer current.' using errcode = 'TA076';
  end if;

  -- Renewing early continues from the old expiry; renewing something
  -- already lapsed starts today. Either way the site does not change.
  if v_old.land_type = 'business' then
    if (select resident_status from public.residents where id = v_old.holder_resident_id) <> 'active' then
      raise exception 'The holder is no longer an active resident.' using errcode = 'TA060';
    end if;
  else
    if not exists (select 1 from public.households h
                    where h.id = v_old.holder_household_id and h.household_status = 'active') then
      raise exception 'That household is no longer current.' using errcode = 'TA060';
    end if;
    if not exists (select 1 from public.households h
                    where h.id = v_old.holder_household_id
                      and h.head_resident_id = v_request.requested_by_resident_id) then
      raise exception 'The person who asked is no longer the head of that household.' using errcode = 'TA060';
    end if;
  end if;

  v_start := greatest(current_date, coalesce(v_old.expiry_date, current_date));

  v_prefix := case v_old.land_type when 'farming' then 'PTO-FRM-' else 'PTO-BUS-' end;

  update public.ptos set pto_status = 'renewed' where id = v_old.id;

  insert into public.ptos (
    pto_number, land_allocation_id, land_type, holder_resident_id, holder_household_id,
    issue_date, expiry_date, pto_status, renewed_from_pto_id, issued_by_staff_id, verification_token)
  values (
    public.next_reference(v_prefix, 'pto_number', 'ptos', 4),
    v_old.land_allocation_id, v_old.land_type, v_old.holder_resident_id, v_old.holder_household_id,
    v_start, public.pto_term_end(v_old.land_type, v_start), 'active', v_old.id, v_staff_id,
    encode(gen_random_bytes(16), 'hex'))
  returning * into v_new;

  update public.pto_renewal_requests
     set request_status = 'approved', reviewed_at = now(),
         reviewed_by_staff_id = v_staff_id, resulting_pto_id = v_new.id
   where id = v_request.id;

  return jsonb_build_object(
    'previous_pto_number', v_old.pto_number, 'previous_status', 'renewed',
    'pto_number', v_new.pto_number, 'issue_date', v_new.issue_date, 'expiry_date', v_new.expiry_date);
end;
$$;

create or replace function public.land_officer_decline_renewal(p_request_id uuid, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_land_officer_staff_id();
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_request  public.pto_renewal_requests;
begin
  if v_reason = '' then
    raise exception 'A reason is required.' using errcode = 'TA061';
  end if;
  select * into v_request from public.pto_renewal_requests where id = p_request_id for update;
  if not found then
    raise exception 'That renewal request could not be found.' using errcode = 'TA077';
  end if;
  if v_request.request_status <> 'pending' then
    raise exception 'That renewal request has already been %.', v_request.request_status using errcode = 'TA077';
  end if;

  update public.pto_renewal_requests
     set request_status = 'declined', decline_reason = v_reason,
         reviewed_at = now(), reviewed_by_staff_id = v_staff_id
   where id = v_request.id;

  return jsonb_build_object('renewal_request_id', v_request.id, 'request_status', 'declined',
                            'decline_reason', v_reason);
end;
$$;

-- ---------------------------------------------------------------------
-- 14. Revoking, and releasing a site
-- ---------------------------------------------------------------------

create or replace function public.land_officer_revoke_pto(p_pto_id uuid, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_land_officer_staff_id();
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_pto      public.ptos;
begin
  if v_reason = '' then
    raise exception 'A reason for revoking is required.' using errcode = 'TA061';
  end if;

  select * into v_pto from public.ptos where id = p_pto_id for update;
  if not found then
    raise exception 'That permission could not be found.' using errcode = 'TA074';
  end if;
  if v_pto.pto_status = 'revoked' then
    raise exception 'That permission has already been revoked.' using errcode = 'TA076';
  end if;

  update public.ptos
     set pto_status = 'revoked', revoked_at = now(),
         revocation_reason = v_reason, revoked_by_staff_id = v_staff_id
   where id = v_pto.id;

  -- The allocation is not touched. Whether the land goes back is a
  -- separate, deliberate decision.
  return jsonb_build_object('pto_number', v_pto.pto_number, 'pto_status', 'revoked',
                            'revocation_reason', v_reason);
end;
$$;

-- Ends an allocation and puts the site back into circulation. Nothing
-- expires its way to a new holder: this is always a deliberate act.
create or replace function public.land_officer_release_allocation(
  p_allocation_id uuid,
  p_reason        text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_land_officer_staff_id();
  v_reason     text := btrim(coalesce(p_reason, ''));
  v_allocation public.land_allocations;
  v_site       public.land_sites;
begin
  if v_reason = '' then
    raise exception 'A reason for releasing the site is required.' using errcode = 'TA061';
  end if;

  select * into v_allocation from public.land_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;
  if v_allocation.allocation_status not in ('active', 'succession_pending') then
    raise exception 'That allocation is already %.', v_allocation.allocation_status using errcode = 'TA072';
  end if;

  select * into v_site from public.land_sites where id = v_allocation.land_site_id for update;

  update public.land_allocations
     set allocation_status = 'released', ended_at = current_date,
         end_reason = v_reason, ended_by_staff_id = v_staff_id
   where id = v_allocation.id;

  -- Any permission still standing on it ends with it.
  update public.ptos
     set pto_status = 'superseded'
   where land_allocation_id = v_allocation.id and pto_status in ('active', 'expired');

  -- A burial plot never goes back into circulation: it stays with the
  -- household that holds it, for ever.
  if v_site.site_type = 'burial' then
    update public.land_sites set site_status = 'unavailable' where id = v_site.id;
  else
    update public.land_sites set site_status = 'available' where id = v_site.id;
  end if;

  return jsonb_build_object('allocation_reference', v_allocation.allocation_reference,
                            'allocation_status', 'released', 'site_code', v_site.site_code,
                            'site_status', (select site_status from public.land_sites where id = v_site.id));
end;
$$;

-- ---------------------------------------------------------------------
-- 15. Burial plots fill up
-- ---------------------------------------------------------------------

create or replace function public.land_officer_set_burial_status(p_site_id uuid, p_burial_status text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_site public.land_sites;
begin
  perform public.acting_land_officer_staff_id();

  if p_burial_status not in ('usable', 'full', 'closed') then
    raise exception 'A burial plot is usable, full or closed.' using errcode = 'TA078';
  end if;

  select * into v_site from public.land_sites where id = p_site_id for update;
  if not found then
    raise exception 'That land site could not be found.' using errcode = 'TA066';
  end if;
  if v_site.site_type <> 'burial' then
    raise exception 'Site % is % land, not a burial plot.', v_site.site_code, v_site.site_type
      using errcode = 'TA078';
  end if;

  update public.land_sites set burial_status = p_burial_status where id = v_site.id;

  return jsonb_build_object('site_code', v_site.site_code, 'burial_status', p_burial_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 16. Residential succession
--
--     A perpetual permission outlives nobody. When the holder dies the
--     allocation is flagged for review and the site stays out of reach
--     of anyone else — but TAMS chooses no heir. The Traditional
--     Authority decides, off the system, and the officer records it.
-- ---------------------------------------------------------------------

create or replace function public.tg_residential_succession_on_death()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.resident_status = 'deceased' and coalesce(old.resident_status, '') <> 'deceased' then
    update public.land_allocations
       set allocation_status = 'succession_pending'
     where resident_id = new.id
       and land_type = 'residential'
       and allocation_status = 'active';
  end if;
  return null;
end;
$$;

drop trigger if exists residential_succession_on_death on public.residents;
create trigger residential_succession_on_death
  after update of resident_status on public.residents
  for each row execute function public.tg_residential_succession_on_death();

-- Who could take it on. Shown to help the officer, ranked by nothing:
-- the order is by age, and it carries no claim of entitlement.
create or replace function public.land_officer_succession_candidates(p_allocation_id uuid)
returns table (
  resident_id uuid, full_name text, id_number text, date_of_birth date, age int,
  relationship text, eligible boolean, problems jsonb
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_allocation public.land_allocations;
begin
  perform public.acting_land_officer_staff_id();

  select * into v_allocation from public.land_allocations where id = p_allocation_id;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;

  return query
    select m.id, m.first_name || ' ' || m.last_name, m.id_number, m.date_of_birth,
           extract(year from age(current_date, m.date_of_birth))::int,
           (select string_agg(distinct f.relationship_type, ', ')
              from public.family_relationships f
              where f.resident_id = v_allocation.resident_id
                and f.related_resident_id = m.id
                and f.relationship_status = 'active'),
           (public.land_eligibility(m.id, 'residential') ->> 'eligible')::boolean,
           public.land_eligibility(m.id, 'residential') -> 'problems'
    from public.residents m
    where m.household_id = v_allocation.household_id
      and m.id is distinct from v_allocation.resident_id
    order by m.date_of_birth;
end;
$$;

create or replace function public.land_officer_record_succession(
  p_allocation_id  uuid,
  p_successor_id   uuid,
  p_reason         text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id     uuid := public.acting_land_officer_staff_id();
  v_allocation   public.land_allocations;
  v_successor    public.residents;
  v_new          public.land_allocations;
  v_new_pto      public.ptos;
  v_old_pto      public.ptos;
begin
  select * into v_allocation from public.land_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;
  if v_allocation.land_type <> 'residential' then
    raise exception 'Succession applies to residential land.' using errcode = 'TA079';
  end if;
  if v_allocation.allocation_status <> 'succession_pending' then
    raise exception 'That allocation is not waiting for succession.' using errcode = 'TA079';
  end if;

  select * into v_successor from public.residents where id = p_successor_id;
  if not found then
    raise exception 'That person is not on the village register.' using errcode = 'TA031';
  end if;

  -- The successor must already be of this household. If they are not,
  -- the Registry Clerk corrects the membership first.
  if v_successor.household_id is distinct from v_allocation.household_id then
    raise exception '% is not a member of the household that holds this site. Ask the Registry Clerk to correct the membership first.',
      v_successor.first_name || ' ' || v_successor.last_name using errcode = 'TA080';
  end if;

  -- Active, 21, and without a stand of their own already.
  if v_successor.resident_status <> 'active' then
    raise exception '% is recorded as % on the register.',
      v_successor.first_name || ' ' || v_successor.last_name, v_successor.resident_status
      using errcode = 'TA060';
  end if;
  if not public.is_at_least_age(v_successor.date_of_birth, 21) then
    raise exception '% is under 21.', v_successor.first_name || ' ' || v_successor.last_name
      using errcode = 'TA060';
  end if;
  if exists (select 1 from public.land_allocations a
              where a.resident_id = v_successor.id and a.land_type = 'residential'
                and a.allocation_status in ('active', 'succession_pending')) then
    raise exception '% already holds a residential stand. Nobody gets a second one.',
      v_successor.first_name || ' ' || v_successor.last_name using errcode = 'TA060';
  end if;

  -- The old allocation is superseded, not edited. Same site, same
  -- household, new episode.
  update public.land_allocations
     set allocation_status = 'superseded', ended_at = current_date,
         end_reason = coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Succession recorded'),
         ended_by_staff_id = v_staff_id
   where id = v_allocation.id;

  insert into public.land_allocations (
    allocation_reference, land_site_id, resident_id, household_id, land_application_id,
    land_type, allocation_date, allocation_status, succeeds_allocation_id)
  values (
    public.next_reference('ALLOC-', 'allocation_reference', 'land_allocations', 4),
    v_allocation.land_site_id, v_successor.id, v_allocation.household_id,
    v_allocation.land_application_id, 'residential', current_date, 'active', v_allocation.id)
  returning * into v_new;

  update public.land_allocations
     set superseded_by_allocation_id = v_new.id where id = v_allocation.id;

  -- The old permission is superseded and kept; a new one is issued.
  select * into v_old_pto from public.ptos
   where land_allocation_id = v_allocation.id and pto_status in ('active', 'expired')
   order by issue_date desc limit 1;

  insert into public.ptos (
    pto_number, land_allocation_id, land_type, holder_resident_id,
    issue_date, expiry_date, pto_status, issued_by_staff_id, verification_token)
  values (
    public.next_reference('PTO-RES-', 'pto_number', 'ptos', 4),
    v_new.id, 'residential', v_successor.id, current_date, null, 'active', v_staff_id,
    encode(gen_random_bytes(16), 'hex'))
  returning * into v_new_pto;

  if v_old_pto.id is not null then
    update public.ptos
       set pto_status = 'superseded', superseded_by_pto_id = v_new_pto.id
     where id = v_old_pto.id;
  end if;

  -- The head of the household is the Registry Clerk's business and is
  -- deliberately left alone here.
  return jsonb_build_object(
    'previous_allocation', v_allocation.allocation_reference,
    'previous_pto_number', v_old_pto.pto_number,
    'allocation_reference', v_new.allocation_reference,
    'pto_number', v_new_pto.pto_number,
    'successor', v_successor.first_name || ' ' || v_successor.last_name,
    'site_code', (select site_code from public.land_sites where id = v_new.land_site_id),
    'household_id', v_new.household_id);
end;
$$;

-- When no successor exists and the Authority decides the land comes
-- back. Never automatic, always with a reason.
create or replace function public.land_officer_return_to_authority(
  p_allocation_id uuid,
  p_reason        text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_allocation public.land_allocations;
begin
  perform public.acting_land_officer_staff_id();

  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A reason is required to return a site to the Traditional Authority.' using errcode = 'TA061';
  end if;

  select * into v_allocation from public.land_allocations where id = p_allocation_id;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;
  if v_allocation.allocation_status <> 'succession_pending' then
    raise exception 'Only a site waiting for succession is returned this way.' using errcode = 'TA079';
  end if;

  return public.land_officer_release_allocation(p_allocation_id, p_reason);
end;
$$;

-- ---------------------------------------------------------------------
-- 17. What a resident sees of their own land
-- ---------------------------------------------------------------------

create or replace function public.resident_land_portal()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_resident_id uuid := public.current_resident_id();
  v_household_id uuid;
  v_is_head boolean;
begin
  if v_resident_id is null then
    raise exception 'Only a verified resident may see this.' using errcode = '42501';
  end if;

  select r.household_id, (h.head_resident_id = r.id)
    into v_household_id, v_is_head
  from public.residents r
  left join public.households h on h.id = r.household_id
  where r.id = v_resident_id;

  return jsonb_build_object(
    'resident_id',       v_resident_id,
    'household_id',      v_household_id,
    'is_household_head', coalesce(v_is_head, false),
    'eligibility', jsonb_build_object(
      'residential', public.land_eligibility(v_resident_id, 'residential'),
      'farming',     public.land_eligibility(v_resident_id, 'farming'),
      'business',    public.land_eligibility(v_resident_id, 'business'),
      'burial',      public.land_eligibility(v_resident_id, 'burial')),
    'applications', coalesce((
      select jsonb_agg(jsonb_build_object(
               'application_reference', a.application_reference,
               'land_type',             a.land_type,
               'application_status',    a.application_status,
               'submitted_at',          a.submitted_at,
               'decline_reason',        a.decline_reason)
             order by a.submitted_at desc)
      from public.land_applications a
      where a.applicant_resident_id = v_resident_id
         or (a.land_type in ('farming', 'burial') and coalesce(v_is_head, false)
             and a.household_id = v_household_id)), '[]'::jsonb),
    'allocations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'allocation_reference', al.allocation_reference,
               'land_type',            al.land_type,
               'site_code',            s.site_code,
               'street_address',       s.street_address,
               'village_section',      s.village_section,
               'allocation_status',    al.allocation_status,
               'allocation_date',      al.allocation_date,
               'burial_status',        s.burial_status)
             order by al.allocation_date desc)
      from public.land_allocations al
      join public.land_sites s on s.id = al.land_site_id
      where al.allocation_status in ('active', 'succession_pending')
        and (al.resident_id = v_resident_id
             or (al.land_type in ('farming', 'burial') and coalesce(v_is_head, false)
                 and al.household_id = v_household_id))), '[]'::jsonb),
    'ptos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'pto_id',            p.id,
               'pto_number',        p.pto_number,
               'land_type',         p.land_type,
               'site_code',         s.site_code,
               'issue_date',        p.issue_date,
               'expiry_date',       p.expiry_date,
               'perpetual',         (p.expiry_date is null),
               'effective_status',  public.pto_effective_status(p.pto_status, p.expiry_date),
               'verification_token', p.verification_token,
               'renewable',         (p.land_type in ('farming', 'business')
                                     and public.pto_effective_status(p.pto_status, p.expiry_date) in ('active', 'expired')),
               'renewal_pending',   exists (select 1 from public.pto_renewal_requests q
                                             where q.pto_id = p.id and q.request_status = 'pending'))
             order by p.issue_date desc)
      from public.ptos p
      join public.land_allocations al on al.id = p.land_allocation_id
      join public.land_sites s on s.id = al.land_site_id
      where p.holder_resident_id = v_resident_id
         or (coalesce(v_is_head, false) and p.holder_household_id = v_household_id)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- 18. What the Land Officer sees
-- ---------------------------------------------------------------------

create or replace function public.land_officer_dashboard()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_land_officer_staff_id();
  return jsonb_build_object(
    'pending_applications',    (select count(*) from public.land_applications where application_status = 'pending'),
    'awaiting_allocation',     (select count(*) from public.land_applications where application_status = 'approved'),
    'available_sites',         (select count(*) from public.land_sites where site_status = 'available'),
    'active_allocations',      (select count(*) from public.land_allocations where allocation_status = 'active'),
    'succession_pending',      (select count(*) from public.land_allocations where allocation_status = 'succession_pending'),
    'active_ptos',             (select count(*) from public.ptos
                                 where public.pto_effective_status(pto_status, expiry_date) = 'active'),
    'expired_ptos',            (select count(*) from public.ptos
                                 where public.pto_effective_status(pto_status, expiry_date) = 'expired'),
    'pending_renewals',        (select count(*) from public.pto_renewal_requests where request_status = 'pending'),
    'burial_plots_usable',     (select count(*) from public.land_sites
                                 where site_type = 'burial' and burial_status = 'usable'));
end;
$$;

create or replace function public.land_officer_sites(p_search text default null, p_site_type text default null)
returns table (
  site_id uuid, site_code text, site_type text, site_status text, burial_status text,
  stand_number text, street_address text, village_section text, village_name text,
  current_holder text, allocation_count bigint
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_land_officer_staff_id();
  return query
    select s.id, s.site_code, s.site_type, s.site_status, s.burial_status,
           s.stand_number, s.street_address, s.village_section, s.village_name,
           (select coalesce(r.first_name || ' ' || r.last_name, h.household_code)
              from public.land_allocations a
              left join public.residents r on r.id = a.resident_id
              left join public.households h on h.id = a.household_id
              where a.land_site_id = s.id and a.allocation_status in ('active', 'succession_pending')
              limit 1),
           (select count(*) from public.land_allocations a where a.land_site_id = s.id)
    from public.land_sites s
    where (p_site_type is null or s.site_type = p_site_type)
      and (v_empty or s.site_code ilike v_pattern or s.street_address ilike v_pattern
           or coalesce(s.stand_number, '') ilike v_pattern)
    order by s.site_code;
end;
$$;

-- Everything that ever happened to one site.
create or replace function public.land_officer_site_history(p_site_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.acting_land_officer_staff_id();

  select jsonb_build_object(
    'site_id', s.id, 'site_code', s.site_code, 'site_type', s.site_type,
    'site_status', s.site_status, 'burial_status', s.burial_status,
    'stand_number', s.stand_number, 'street_address', s.street_address,
    'village_section', s.village_section, 'village_name', s.village_name,
    'allocations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'allocation_id',        a.id,
               'allocation_reference', a.allocation_reference,
               'land_type',            a.land_type,
               'allocation_status',    a.allocation_status,
               'allocation_date',      a.allocation_date,
               'ended_at',             a.ended_at,
               'end_reason',           a.end_reason,
               'holder', coalesce(r.first_name || ' ' || r.last_name, '(household)'),
               'household_code', h.household_code,
               'application_reference', app.application_reference,
               'succeeds', (select prev.allocation_reference from public.land_allocations prev
                             where prev.id = a.succeeds_allocation_id),
               'ptos', coalesce((select jsonb_agg(jsonb_build_object(
                          'pto_number', p.pto_number,
                          'issue_date', p.issue_date,
                          'expiry_date', p.expiry_date,
                          'stored_status', p.pto_status,
                          'effective_status', public.pto_effective_status(p.pto_status, p.expiry_date),
                          'revocation_reason', p.revocation_reason)
                        order by p.issue_date)
                        from public.ptos p where p.land_allocation_id = a.id), '[]'::jsonb))
             order by a.allocation_date desc)
      from public.land_allocations a
      left join public.residents r on r.id = a.resident_id
      left join public.households h on h.id = a.household_id
      left join public.land_applications app on app.id = a.land_application_id
      where a.land_site_id = s.id), '[]'::jsonb)
  ) into v_result
  from public.land_sites s where s.id = p_site_id;

  if v_result is null then
    raise exception 'That land site could not be found.' using errcode = 'TA066';
  end if;
  return v_result;
end;
$$;

create or replace function public.land_officer_ptos(p_search text default null, p_status text default null)
returns table (
  pto_id uuid, pto_number text, land_type text, site_code text,
  holder_name text, household_code text, issue_date date, expiry_date date,
  stored_status text, effective_status text, allocation_id uuid, allocation_status text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_land_officer_staff_id();
  return query
    select p.id, p.pto_number, p.land_type, s.site_code,
           r.first_name || ' ' || r.last_name, h.household_code,
           p.issue_date, p.expiry_date, p.pto_status,
           public.pto_effective_status(p.pto_status, p.expiry_date),
           a.id, a.allocation_status
    from public.ptos p
    join public.land_allocations a on a.id = p.land_allocation_id
    join public.land_sites s on s.id = a.land_site_id
    left join public.residents r on r.id = p.holder_resident_id
    left join public.households h on h.id = p.holder_household_id
    where (p_status is null or public.pto_effective_status(p.pto_status, p.expiry_date) = p_status)
      and (v_empty or p.pto_number ilike v_pattern or s.site_code ilike v_pattern
           or coalesce(h.household_code, '') ilike v_pattern
           or coalesce(r.first_name || ' ' || r.last_name, '') ilike v_pattern)
    order by p.issue_date desc;
end;
$$;

-- Every allocation, past and present. The Allocations screen and the
-- succession screen are both this list, filtered.
create or replace function public.land_officer_allocations(
  p_status    text default 'active',
  p_land_type text default null,
  p_search    text default null
)
returns table (
  allocation_id uuid, allocation_reference text, land_type text,
  site_id uuid, site_code text, street_address text, village_section text,
  burial_status text, holder_resident_id uuid, holder_name text,
  household_id uuid, household_code text,
  allocation_status text, allocation_date date, ended_at date, end_reason text,
  pto_id uuid, pto_number text, pto_expiry_date date, pto_effective_status text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_land_officer_staff_id();
  return query
    select a.id, a.allocation_reference, a.land_type,
           s.id, s.site_code, s.street_address, s.village_section, s.burial_status,
           a.resident_id, r.first_name || ' ' || r.last_name,
           a.household_id, h.household_code,
           a.allocation_status, a.allocation_date, a.ended_at, a.end_reason,
           p.id, p.pto_number, p.expiry_date,
           public.pto_effective_status(p.pto_status, p.expiry_date)
    from public.land_allocations a
    join public.land_sites s on s.id = a.land_site_id
    left join public.residents r on r.id = a.resident_id
    left join public.households h on h.id = a.household_id
    -- The permission that is current for this allocation, if there is one.
    left join lateral (
      select p2.* from public.ptos p2
       where p2.land_allocation_id = a.id
         and p2.pto_status in ('active', 'expired')
       order by p2.issue_date desc, p2.created_at desc
       limit 1) p on true
    where (p_status is null or a.allocation_status = p_status)
      and (p_land_type is null or a.land_type = p_land_type)
      and (v_empty
           or a.allocation_reference ilike v_pattern
           or s.site_code ilike v_pattern
           or coalesce(h.household_code, '') ilike v_pattern
           or coalesce(r.first_name || ' ' || r.last_name, '') ilike v_pattern)
    order by a.allocation_date desc, a.allocation_reference desc;
end;
$$;

-- ---------------------------------------------------------------------
-- 19. The permission document, and verifying one
--
--     The document carries what a permission has to show and nothing
--     about the person beyond their name. No identity number, no date
--     of birth, no contact details.
-- ---------------------------------------------------------------------

create or replace function public.pto_document(p_pto_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
  v_allowed boolean;
begin
  select
    public.is_active_land_officer()
    or p.holder_resident_id = public.current_resident_id()
    or exists (select 1 from public.households h
                where h.id = p.holder_household_id and h.head_resident_id = public.current_resident_id())
  into v_allowed
  from public.ptos p where p.id = p_pto_id;

  if not coalesce(v_allowed, false) then
    raise exception 'That permission to occupy is not yours to view.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'pto_number',      p.pto_number,
    'land_type',       p.land_type,
    'holder_name',     coalesce(r.first_name || ' ' || r.last_name, 'Household ' || h.household_code),
    'household_code',  h.household_code,
    'site_code',       s.site_code,
    'stand_number',    s.stand_number,
    'street_address',  s.street_address,
    'village_section', s.village_section,
    'village_name',    s.village_name,
    'issue_date',      p.issue_date,
    'expiry_date',     p.expiry_date,
    'perpetual',       (p.expiry_date is null),
    'effective_status', public.pto_effective_status(p.pto_status, p.expiry_date),
    'verification_token', p.verification_token
  ) into v_result
  from public.ptos p
  join public.land_allocations a on a.id = p.land_allocation_id
  join public.land_sites s on s.id = a.land_site_id
  left join public.residents r on r.id = p.holder_resident_id
  left join public.households h on h.id = p.holder_household_id
  where p.id = p_pto_id;

  return v_result;
end;
$$;

-- Public. Anyone holding the printed document can check it is real.
-- It answers with enough to establish authenticity and nothing more:
-- no identity number, no birth date, no contact details, no internal
-- identifiers.
create or replace function public.verify_pto(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  if coalesce(btrim(p_token), '') = '' then
    return jsonb_build_object('found', false);
  end if;

  select jsonb_build_object(
    'found',           true,
    'pto_number',      p.pto_number,
    'land_type',       p.land_type,
    'holder_name',     coalesce(r.first_name || ' ' || r.last_name, 'Household ' || h.household_code),
    'site_code',       s.site_code,
    'village_section', s.village_section,
    'village_name',    s.village_name,
    'issue_date',      p.issue_date,
    'expiry_date',     p.expiry_date,
    'perpetual',       (p.expiry_date is null),
    'status',          public.pto_effective_status(p.pto_status, p.expiry_date)
  ) into v_result
  from public.ptos p
  join public.land_allocations a on a.id = p.land_allocation_id
  join public.land_sites s on s.id = a.land_site_id
  left join public.residents r on r.id = p.holder_resident_id
  left join public.households h on h.id = p.holder_household_id
  where p.verification_token = btrim(p_token);

  return coalesce(v_result, jsonb_build_object('found', false));
end;
$$;

-- ---------------------------------------------------------------------
-- 20. Grants
--
--     Each function establishes its own caller, so execute may be given
--     to signed-in users; the functions turn away anyone who should not
--     be there. Verification is the one public one.
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.is_active_land_officer()',
    'public.is_at_least_age(date, int)',
    'public.pto_effective_status(text, date)',
    'public.pto_term_end(text, date)',
    'public.allocatable_land_types()',
    'public.current_resident_id()',
    'public.current_resident_headed_household_ids()',
    'public.land_eligibility(uuid, text)',
    'public.resident_land_eligibility(text)',
    'public.resident_submit_land_application(text, jsonb)',
    'public.resident_land_portal()',
    'public.resident_request_pto_renewal(uuid, text)',
    'public.pto_document(uuid)',
    'public.land_officer_register_site(text, text, text, text, text, text)',
    'public.land_officer_update_site(uuid, text, text, text, text, text, text)',
    'public.land_officer_applications(text, text, text)',
    'public.land_officer_application(uuid)',
    'public.land_officer_approve_application(uuid)',
    'public.land_officer_decline_application(uuid, text)',
    'public.land_officer_available_sites(text)',
    'public.land_officer_allocate_site(uuid, uuid)',
    'public.land_officer_issue_pto(uuid)',
    'public.land_officer_renewal_requests(text)',
    'public.land_officer_approve_renewal(uuid)',
    'public.land_officer_decline_renewal(uuid, text)',
    'public.land_officer_revoke_pto(uuid, text)',
    'public.land_officer_release_allocation(uuid, text)',
    'public.land_officer_set_burial_status(uuid, text)',
    'public.land_officer_succession_candidates(uuid)',
    'public.land_officer_record_succession(uuid, uuid, text)',
    'public.land_officer_return_to_authority(uuid, text)',
    'public.land_officer_dashboard()',
    'public.land_officer_sites(text, text)',
    'public.land_officer_site_history(uuid)',
    'public.land_officer_ptos(text, text)',
    'public.land_officer_allocations(text, text, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

revoke all on function public.acting_land_officer_staff_id() from public, anon, authenticated;
revoke all on function public.next_reference(text, text, text, int) from public, anon, authenticated;

-- Verification is meant to be usable by anybody holding the document.
revoke all on function public.verify_pto(text) from public;
grant execute on function public.verify_pto(text) to anon, authenticated;


-- ---------------------------------------------------------------------
-- 20260927090000_council_records.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — the Council Secretary's records
--
-- Meetings, who attended them, the minutes, corrections to minutes that
-- have already been finalised, the resolutions a meeting produced, the
-- projects the community is running, and the milestones those projects
-- are measured by.
--
-- Two rules shape the whole thing:
--
--   * Official history is never rewritten. Finalised minutes are
--     locked and corrected by amendment; cancelled meetings, withdrawn
--     resolutions and cancelled projects are kept with their reason.
--     Nothing here is ever physically deleted.
--
--   * What a resident may see is decided by the database, not by the
--     browser. Internal records are unreachable, not merely hidden.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Meetings
-- ---------------------------------------------------------------------

create table if not exists public.council_meetings (
  id                     uuid primary key default gen_random_uuid(),
  meeting_reference      text not null unique,
  title                  text not null,
  meeting_type           text not null,
  meeting_date           date not null,
  start_time             time not null,
  venue                  text not null,
  agenda                 text not null,
  meeting_status         text not null default 'scheduled',

  -- Kept for the record, never to be rewritten later.
  cancellation_reason    text,
  cancelled_at           timestamptz,
  cancelled_by_staff_id  uuid references public.staff (id),
  held_recorded_at       timestamptz,
  held_recorded_by_staff_id uuid references public.staff (id),

  created_by_staff_id    uuid references public.staff (id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint council_meetings_reference_not_blank check (btrim(meeting_reference) <> ''),
  constraint council_meetings_title_not_blank     check (btrim(title) <> ''),
  constraint council_meetings_venue_not_blank     check (btrim(venue) <> ''),
  constraint council_meetings_agenda_not_blank    check (btrim(agenda) <> ''),
  constraint council_meetings_type_allowed
    check (meeting_type in ('ordinary', 'special', 'emergency')),
  constraint council_meetings_status_allowed
    check (meeting_status in ('scheduled', 'held', 'cancelled')),
  -- A date nobody could have meant. The narrower "not decades away"
  -- check lives in the function, because a CHECK constraint may not
  -- look at today's date.
  constraint council_meetings_date_sane check (meeting_date >= date '2000-01-01'),
  -- A cancelled meeting always says why, and who decided.
  constraint council_meetings_cancellation_shape check (
    meeting_status <> 'cancelled'
    or (btrim(coalesce(cancellation_reason, '')) <> ''
        and cancelled_at is not null and cancelled_by_staff_id is not null)
  ),
  -- A meeting that has not been cancelled carries no cancellation.
  constraint council_meetings_no_stray_cancellation check (
    meeting_status = 'cancelled'
    or (cancellation_reason is null and cancelled_at is null and cancelled_by_staff_id is null)
  )
);

create index if not exists council_meetings_date_idx   on public.council_meetings (meeting_date desc);
create index if not exists council_meetings_status_idx on public.council_meetings (meeting_status);

-- ---------------------------------------------------------------------
-- 2. Who was there
--
--    Attendance is an official record of a meeting, not a way of
--    signing in. The Chief, a Headman or Headwoman, a council member or
--    an invited guest is written down by name and capacity; none of
--    them needs a TAMS account, a staff record or a resident record,
--    and this table deliberately links to none of those.
-- ---------------------------------------------------------------------

create table if not exists public.meeting_attendance (
  id                  uuid primary key default gen_random_uuid(),
  meeting_id          uuid not null references public.council_meetings (id),
  attendee_name       text not null,
  role_or_capacity    text not null,
  attendance_status   text not null default 'present',
  recorded_by_staff_id uuid references public.staff (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint meeting_attendance_name_not_blank     check (btrim(attendee_name) <> ''),
  constraint meeting_attendance_capacity_not_blank check (btrim(role_or_capacity) <> ''),
  constraint meeting_attendance_status_allowed
    check (attendance_status in ('present', 'absent', 'apology'))
);

create index if not exists meeting_attendance_meeting_idx on public.meeting_attendance (meeting_id);

-- ---------------------------------------------------------------------
-- 3. Minutes — at most one official record per meeting
--
--    The council confirms minutes the way it always has, in the room.
--    TAMS records that confirmation; it does not add a second digital
--    approver.
-- ---------------------------------------------------------------------

create table if not exists public.meeting_minutes (
  id                    uuid primary key default gen_random_uuid(),
  meeting_id            uuid not null unique references public.council_meetings (id),
  minutes_content       text not null,
  minutes_status        text not null default 'draft',
  finalized_at          timestamptz,
  finalized_by_staff_id uuid references public.staff (id),
  created_by_staff_id   uuid references public.staff (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint meeting_minutes_status_allowed check (minutes_status in ('draft', 'final')),
  constraint meeting_minutes_final_shape check (
    minutes_status <> 'final'
    or (btrim(minutes_content) <> '' and finalized_at is not null and finalized_by_staff_id is not null)
  ),
  constraint meeting_minutes_draft_shape check (
    minutes_status <> 'draft'
    or (finalized_at is null and finalized_by_staff_id is null)
  )
);

-- ---------------------------------------------------------------------
-- 4. Amendments — how finalised minutes are corrected
--
--    The original is never reopened and never overwritten. A correction
--    is a separate record, shown alongside it for ever.
-- ---------------------------------------------------------------------

create table if not exists public.meeting_minutes_amendments (
  id                  uuid primary key default gen_random_uuid(),
  minutes_id          uuid not null references public.meeting_minutes (id),
  amendment_reference text not null unique,
  amendment_text      text not null,
  reason              text not null,
  created_by_staff_id uuid references public.staff (id),
  created_at          timestamptz not null default now(),

  constraint minutes_amendments_text_not_blank   check (btrim(amendment_text) <> ''),
  constraint minutes_amendments_reason_not_blank check (btrim(reason) <> '')
);

create index if not exists minutes_amendments_minutes_idx
  on public.meeting_minutes_amendments (minutes_id);

-- ---------------------------------------------------------------------
-- 5. Resolutions
--
--    One meeting may produce many. The decision date comes from the
--    meeting, never from the browser.
-- ---------------------------------------------------------------------

create table if not exists public.council_resolutions (
  id                    uuid primary key default gen_random_uuid(),
  resolution_reference  text not null unique,
  meeting_id            uuid not null references public.council_meetings (id),
  resolution_text       text not null,
  decision_date         date not null,
  resolution_status     text not null default 'active',
  visibility            text not null default 'internal',

  withdrawal_reason     text,
  withdrawn_at          timestamptz,
  withdrawn_by_staff_id uuid references public.staff (id),
  implemented_at        timestamptz,
  implemented_by_staff_id uuid references public.staff (id),

  created_by_staff_id   uuid references public.staff (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint council_resolutions_text_not_blank check (btrim(resolution_text) <> ''),
  constraint council_resolutions_status_allowed
    check (resolution_status in ('active', 'implemented', 'withdrawn')),
  constraint council_resolutions_visibility_allowed
    check (visibility in ('internal', 'public')),
  constraint council_resolutions_withdrawal_shape check (
    resolution_status <> 'withdrawn'
    or (btrim(coalesce(withdrawal_reason, '')) <> ''
        and withdrawn_at is not null and withdrawn_by_staff_id is not null)
  )
);

create index if not exists council_resolutions_meeting_idx on public.council_resolutions (meeting_id);
create index if not exists council_resolutions_visible_idx
  on public.council_resolutions (visibility, resolution_status);

-- ---------------------------------------------------------------------
-- 6. Projects
--
--    A project may come out of a resolution, or may not. Both are
--    ordinary.
-- ---------------------------------------------------------------------

create table if not exists public.community_projects (
  id                     uuid primary key default gen_random_uuid(),
  project_reference      text not null unique,
  project_name           text not null,
  description            text not null,
  resolution_id          uuid references public.council_resolutions (id),
  start_date             date not null,
  target_completion_date date,
  project_status         text not null default 'planned',
  visibility             text not null default 'internal',

  cancellation_reason    text,
  cancelled_at           timestamptz,
  cancelled_by_staff_id  uuid references public.staff (id),
  completed_on           date,
  completed_at           timestamptz,
  completed_by_staff_id  uuid references public.staff (id),

  created_by_staff_id    uuid references public.staff (id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint community_projects_name_not_blank        check (btrim(project_name) <> ''),
  constraint community_projects_description_not_blank check (btrim(description) <> ''),
  constraint community_projects_status_allowed
    check (project_status in ('planned', 'active', 'completed', 'cancelled')),
  constraint community_projects_visibility_allowed
    check (visibility in ('internal', 'public')),
  -- A target that falls before the start is not a target.
  constraint community_projects_date_order
    check (target_completion_date is null or target_completion_date >= start_date),
  constraint community_projects_start_sane check (start_date >= date '2000-01-01'),
  constraint community_projects_cancellation_shape check (
    project_status <> 'cancelled'
    or (btrim(coalesce(cancellation_reason, '')) <> ''
        and cancelled_at is not null and cancelled_by_staff_id is not null)
  ),
  constraint community_projects_completion_shape check (
    project_status <> 'completed'
    or (completed_on is not null and completed_at is not null)
  )
);

create index if not exists community_projects_status_idx on public.community_projects (project_status);
create index if not exists community_projects_visible_idx on public.community_projects (visibility);
create index if not exists community_projects_resolution_idx on public.community_projects (resolution_id);

-- ---------------------------------------------------------------------
-- 7. Milestones
--
--    Only three statuses are ever stored. "Overdue" is not one of them:
--    it is worked out from the due date whenever anybody looks, so it
--    cannot be forgotten, mis-set, or left wrong because a nightly job
--    did not run.
-- ---------------------------------------------------------------------

create table if not exists public.project_milestones (
  id                  uuid primary key default gen_random_uuid(),
  project_id          uuid not null references public.community_projects (id),
  title               text not null,
  description         text,
  due_date            date not null,
  milestone_status    text not null default 'pending',
  completed_at        timestamptz,
  completed_by_staff_id uuid references public.staff (id),
  created_by_staff_id uuid references public.staff (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint project_milestones_title_not_blank check (btrim(title) <> ''),
  constraint project_milestones_status_allowed
    check (milestone_status in ('pending', 'in_progress', 'completed')),
  constraint project_milestones_completion_shape check (
    (milestone_status = 'completed' and completed_at is not null)
    or (milestone_status <> 'completed' and completed_at is null)
  ),
  constraint project_milestones_due_sane check (due_date >= date '2000-01-01')
);

create index if not exists project_milestones_project_idx on public.project_milestones (project_id);
create index if not exists project_milestones_due_idx on public.project_milestones (due_date);

-- ---------------------------------------------------------------------
-- 8. Visibility history
--
--    Something that was published and is then taken back must leave a
--    trace. One small table covers both resolutions and projects; a row
--    is written for every change of visibility, in either direction.
-- ---------------------------------------------------------------------

create table if not exists public.visibility_changes (
  id                  uuid primary key default gen_random_uuid(),
  subject_type        text not null,
  resolution_id       uuid references public.council_resolutions (id),
  project_id          uuid references public.community_projects (id),
  from_visibility     text not null,
  to_visibility       text not null,
  reason              text,
  changed_by_staff_id uuid references public.staff (id),
  changed_at          timestamptz not null default now(),

  constraint visibility_changes_subject_allowed
    check (subject_type in ('resolution', 'project')),
  constraint visibility_changes_from_allowed check (from_visibility in ('internal', 'public')),
  constraint visibility_changes_to_allowed   check (to_visibility in ('internal', 'public')),
  constraint visibility_changes_actually_changed check (from_visibility <> to_visibility),
  -- Exactly the one subject the row is about, and no other.
  constraint visibility_changes_subject_shape check (
    (subject_type = 'resolution' and resolution_id is not null and project_id is null)
    or (subject_type = 'project' and project_id is not null and resolution_id is null)
  ),
  -- Taking something back off the public record always says why.
  constraint visibility_changes_withdrawal_reason check (
    not (from_visibility = 'public' and to_visibility = 'internal')
    or btrim(coalesce(reason, '')) <> ''
  )
);

create index if not exists visibility_changes_resolution_idx
  on public.visibility_changes (resolution_id);
create index if not exists visibility_changes_project_idx
  on public.visibility_changes (project_id);

-- ---------------------------------------------------------------------
-- 9. updated_at
-- ---------------------------------------------------------------------

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'council_meetings', 'meeting_attendance', 'meeting_minutes',
    'council_resolutions', 'community_projects', 'project_milestones'
  ]
  loop
    execute format('drop trigger if exists %I on public.%I', v_table || '_touch', v_table);
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.tg_touch_updated_at()',
      v_table || '_touch', v_table);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Row Level Security
--
--     Reads are policy-driven and deliberately narrow; the policies
--     themselves are added in the next migration, where the helper
--     functions they depend on exist. Until then these tables are
--     readable by nobody, which is the safe way round.
--
--     There is no insert, update or delete policy on any of them, in
--     this migration or the next. Every write goes through a
--     `security definer` function that establishes its own caller.
-- ---------------------------------------------------------------------

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'council_meetings', 'meeting_attendance', 'meeting_minutes',
    'meeting_minutes_amendments', 'council_resolutions', 'community_projects',
    'project_milestones', 'visibility_changes'
  ]
  loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('alter table public.%I force row level security', v_table);
    execute format('revoke all on public.%I from anon, authenticated', v_table);
    execute format('grant select on public.%I to authenticated', v_table);
    execute format('grant all on public.%I to service_role', v_table);
  end loop;
end;
$$;


-- ---------------------------------------------------------------------
-- 20260928090000_council_functions.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — Council Secretary functions
--
-- Every privileged operation establishes its caller from auth.uid() and
-- rechecks the rules for itself. Nothing is trusted from the browser:
-- not the role, not a staff id, not a decision date.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who is a Council Secretary
--
--    The same walk as the Registry Clerk's and the Land Officer's:
--    auth.uid() -> user_accounts (staff, active) -> staff -> the role
--    that account holds *now*. An account deactivated a second ago
--    fails here, and the Council Administrator does not pass merely by
--    being the administrator.
-- ---------------------------------------------------------------------

create or replace function public.is_active_council_secretary()
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Council Secretary');
$$;

create or replace function public.acting_council_secretary_staff_id()
returns uuid
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff_id uuid;
begin
  select s.id into v_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Secretary';

  if v_staff_id is null then
    raise exception 'Only an active Council Secretary may do that.' using errcode = '42501';
  end if;
  return v_staff_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Small shared helpers
-- ---------------------------------------------------------------------

-- A reference that carries the year it belongs to: MTG-2026-0001.
create or replace function public.council_reference(p_prefix text, p_column text, p_table text)
returns text
language sql volatile security definer set search_path = public, pg_temp
as $$
  select public.next_reference(
    p_prefix || to_char(current_date, 'YYYY') || '-', p_column, p_table, 4);
$$;

-- "Overdue" is never stored. It is this, worked out whenever anybody
-- looks, so it is right the moment the due date passes and needs no
-- scheduler to make it so.
create or replace function public.milestone_effective_status(p_status text, p_due_date date)
returns text
language sql immutable
as $$
  select case
    when p_status = 'completed' then 'completed'
    when p_due_date < current_date then 'overdue'
    else p_status
  end;
$$;

-- Are a meeting's minutes finalised? Asked from Row Level Security, so
-- it has to be able to read meeting_minutes as the definer: a resident
-- has no read policy on that table at all, and never will.
create or replace function public.meeting_minutes_are_final(p_meeting_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.meeting_minutes m
    where m.meeting_id = p_meeting_id and m.minutes_status = 'final');
$$;

-- May a resident see this resolution at all? Public *and* confirmed:
-- a resolution from a meeting whose minutes are still a draft is not
-- yet part of the record.
create or replace function public.resolution_is_public(p_resolution_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.council_resolutions r
    where r.id = p_resolution_id
      and r.visibility = 'public'
      and public.meeting_minutes_are_final(r.meeting_id));
$$;

create or replace function public.project_is_public(p_project_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.community_projects p
    where p.id = p_project_id and p.visibility = 'public');
$$;

-- ---------------------------------------------------------------------
-- 3. Row Level Security policies
--
--     The Secretary reads their own records. A resident reads nothing
--     but public resolutions from confirmed meetings, public projects,
--     and the milestones of those projects. Meetings, attendance,
--     minutes, amendments and the visibility history are unreachable
--     to everybody else — not hidden by the browser, unreachable.
-- ---------------------------------------------------------------------

drop policy if exists council_meetings_readable on public.council_meetings;
create policy council_meetings_readable
  on public.council_meetings for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists meeting_attendance_readable on public.meeting_attendance;
create policy meeting_attendance_readable
  on public.meeting_attendance for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists meeting_minutes_readable on public.meeting_minutes;
create policy meeting_minutes_readable
  on public.meeting_minutes for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists minutes_amendments_readable on public.meeting_minutes_amendments;
create policy minutes_amendments_readable
  on public.meeting_minutes_amendments for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists visibility_changes_readable on public.visibility_changes;
create policy visibility_changes_readable
  on public.visibility_changes for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists council_resolutions_readable on public.council_resolutions;
create policy council_resolutions_readable
  on public.council_resolutions for select to authenticated
  using (
    public.is_active_council_secretary()
    or (visibility = 'public'
        and public.meeting_minutes_are_final(meeting_id)
        and public.current_resident_id() is not null)
  );

drop policy if exists community_projects_readable on public.community_projects;
create policy community_projects_readable
  on public.community_projects for select to authenticated
  using (
    public.is_active_council_secretary()
    or (visibility = 'public' and public.current_resident_id() is not null)
  );

drop policy if exists project_milestones_readable on public.project_milestones;
create policy project_milestones_readable
  on public.project_milestones for select to authenticated
  using (
    public.is_active_council_secretary()
    or (public.project_is_public(project_id) and public.current_resident_id() is not null)
  );

-- ---------------------------------------------------------------------
-- 4. Scheduling a meeting
-- ---------------------------------------------------------------------

create or replace function public.secretary_schedule_meeting(
  p_title        text,
  p_meeting_type text,
  p_meeting_date date,
  p_start_time   time,
  p_venue        text,
  p_agenda       text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_meeting  public.council_meetings;
begin
  if btrim(coalesce(p_title, '')) = '' or btrim(coalesce(p_venue, '')) = ''
     or btrim(coalesce(p_agenda, '')) = '' then
    raise exception 'A title, a venue and an agenda are all required.' using errcode = 'TA081';
  end if;
  if p_meeting_type is null or p_meeting_type not in ('ordinary', 'special', 'emergency') then
    raise exception '% is not a kind of meeting. It is ordinary, special or emergency.',
      coalesce(p_meeting_type, '(none)') using errcode = 'TA082';
  end if;
  if p_meeting_date is null or p_start_time is null then
    raise exception 'A meeting needs a date and a starting time.' using errcode = 'TA083';
  end if;
  -- A date nobody could have meant: mistyped years are the usual cause.
  if p_meeting_date < current_date - make_interval(years => 10)
     or p_meeting_date > current_date + make_interval(years => 2) then
    raise exception 'A meeting date of % is not a date anybody meant.', p_meeting_date
      using errcode = 'TA083';
  end if;

  insert into public.council_meetings (
    meeting_reference, title, meeting_type, meeting_date, start_time, venue, agenda,
    meeting_status, created_by_staff_id)
  values (
    public.council_reference('MTG-', 'meeting_reference', 'council_meetings'),
    btrim(p_title), p_meeting_type, p_meeting_date, p_start_time,
    btrim(p_venue), btrim(p_agenda), 'scheduled', v_staff_id)
  returning * into v_meeting;

  return jsonb_build_object(
    'meeting_id', v_meeting.id,
    'meeting_reference', v_meeting.meeting_reference,
    'meeting_status', v_meeting.meeting_status);
end;
$$;

-- Editing what a meeting says. A meeting that has already been held or
-- cancelled is history: its date, time, type and agenda are what they
-- were, and this refuses to rewrite them.
create or replace function public.secretary_update_meeting(
  p_meeting_id   uuid,
  p_title        text,
  p_meeting_type text,
  p_meeting_date date,
  p_start_time   time,
  p_venue        text,
  p_agenda       text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_meeting public.council_meetings;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_meeting from public.council_meetings where id = p_meeting_id for update;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if v_meeting.meeting_status <> 'scheduled' then
    raise exception 'Meeting % has been recorded as %, so its details are part of the official record and cannot be edited. Record a correction in the minutes instead.',
      v_meeting.meeting_reference, v_meeting.meeting_status using errcode = 'TA085';
  end if;
  if btrim(coalesce(p_title, '')) = '' or btrim(coalesce(p_venue, '')) = ''
     or btrim(coalesce(p_agenda, '')) = '' then
    raise exception 'A title, a venue and an agenda are all required.' using errcode = 'TA081';
  end if;
  if p_meeting_type is null or p_meeting_type not in ('ordinary', 'special', 'emergency') then
    raise exception '% is not a kind of meeting. It is ordinary, special or emergency.',
      coalesce(p_meeting_type, '(none)') using errcode = 'TA082';
  end if;
  if p_meeting_date is null or p_start_time is null then
    raise exception 'A meeting needs a date and a starting time.' using errcode = 'TA083';
  end if;
  if p_meeting_date < current_date - make_interval(years => 10)
     or p_meeting_date > current_date + make_interval(years => 2) then
    raise exception 'A meeting date of % is not a date anybody meant.', p_meeting_date
      using errcode = 'TA083';
  end if;

  update public.council_meetings
     set title = btrim(p_title), meeting_type = p_meeting_type,
         meeting_date = p_meeting_date, start_time = p_start_time,
         venue = btrim(p_venue), agenda = btrim(p_agenda)
   where id = v_meeting.id
  returning * into v_meeting;

  return jsonb_build_object(
    'meeting_id', v_meeting.id, 'meeting_reference', v_meeting.meeting_reference);
end;
$$;

-- The only two moves a meeting can make, and both are one-way.
create or replace function public.secretary_set_meeting_status(
  p_meeting_id uuid,
  p_status     text,
  p_reason     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_meeting  public.council_meetings;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id for update;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if p_status is null or p_status not in ('scheduled', 'held', 'cancelled') then
    raise exception 'A meeting is scheduled, held or cancelled.' using errcode = 'TA086';
  end if;
  if v_meeting.meeting_status <> 'scheduled' then
    raise exception 'Meeting % is already %, and that cannot be undone.',
      v_meeting.meeting_reference, v_meeting.meeting_status using errcode = 'TA086';
  end if;
  if p_status = 'scheduled' then
    raise exception 'Meeting % is already scheduled.', v_meeting.meeting_reference
      using errcode = 'TA086';
  end if;

  if p_status = 'held' then
    update public.council_meetings
       set meeting_status = 'held', held_recorded_at = now(), held_recorded_by_staff_id = v_staff_id
     where id = v_meeting.id
    returning * into v_meeting;
  else
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'A reason is required to cancel a meeting.' using errcode = 'TA087';
    end if;
    update public.council_meetings
       set meeting_status = 'cancelled', cancellation_reason = btrim(p_reason),
           cancelled_at = now(), cancelled_by_staff_id = v_staff_id
     where id = v_meeting.id
    returning * into v_meeting;
  end if;

  return jsonb_build_object(
    'meeting_id', v_meeting.id,
    'meeting_reference', v_meeting.meeting_reference,
    'meeting_status', v_meeting.meeting_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Attendance
-- ---------------------------------------------------------------------

create or replace function public.secretary_add_attendee(
  p_meeting_id       uuid,
  p_attendee_name    text,
  p_role_or_capacity text,
  p_attendance_status text default 'present'
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_council_secretary_staff_id();
  v_meeting    public.council_meetings;
  v_attendance public.meeting_attendance;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if btrim(coalesce(p_attendee_name, '')) = '' or btrim(coalesce(p_role_or_capacity, '')) = '' then
    raise exception 'An attendee needs a name and the capacity they attended in.'
      using errcode = 'TA088';
  end if;
  if p_attendance_status is null or p_attendance_status not in ('present', 'absent', 'apology') then
    raise exception 'Attendance is recorded as present, absent or apology.' using errcode = 'TA089';
  end if;
  -- Once the minutes are final the attendance list is part of them.
  if public.meeting_minutes_are_final(v_meeting.id) then
    raise exception 'The minutes of % are final, so its attendance list is closed.',
      v_meeting.meeting_reference using errcode = 'TA090';
  end if;

  insert into public.meeting_attendance (
    meeting_id, attendee_name, role_or_capacity, attendance_status, recorded_by_staff_id)
  values (v_meeting.id, btrim(p_attendee_name), btrim(p_role_or_capacity),
          p_attendance_status, v_staff_id)
  returning * into v_attendance;

  return jsonb_build_object(
    'attendance_id', v_attendance.id, 'attendee_name', v_attendance.attendee_name);
end;
$$;

create or replace function public.secretary_update_attendee(
  p_attendance_id     uuid,
  p_attendee_name     text,
  p_role_or_capacity  text,
  p_attendance_status text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_attendance public.meeting_attendance;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_attendance from public.meeting_attendance where id = p_attendance_id for update;
  if not found then
    raise exception 'That attendance record could not be found.' using errcode = 'TA091';
  end if;
  if public.meeting_minutes_are_final(v_attendance.meeting_id) then
    raise exception 'The minutes for that meeting are final, so its attendance list is closed.'
      using errcode = 'TA090';
  end if;
  if btrim(coalesce(p_attendee_name, '')) = '' or btrim(coalesce(p_role_or_capacity, '')) = '' then
    raise exception 'An attendee needs a name and the capacity they attended in.'
      using errcode = 'TA088';
  end if;
  if p_attendance_status is null or p_attendance_status not in ('present', 'absent', 'apology') then
    raise exception 'Attendance is recorded as present, absent or apology.' using errcode = 'TA089';
  end if;

  update public.meeting_attendance
     set attendee_name = btrim(p_attendee_name),
         role_or_capacity = btrim(p_role_or_capacity),
         attendance_status = p_attendance_status
   where id = v_attendance.id
  returning * into v_attendance;

  return jsonb_build_object(
    'attendance_id', v_attendance.id, 'attendee_name', v_attendance.attendee_name);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Minutes
-- ---------------------------------------------------------------------

-- Saving a draft. The first save creates the one minutes record the
-- meeting is allowed; later saves replace the draft. Once the minutes
-- are final this refuses, and there is no other way in.
create or replace function public.secretary_save_minutes(
  p_meeting_id uuid,
  p_content    text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_meeting  public.council_meetings;
  v_minutes  public.meeting_minutes;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if v_meeting.meeting_status = 'cancelled' then
    raise exception 'Meeting % was cancelled, so it has no minutes.', v_meeting.meeting_reference
      using errcode = 'TA092';
  end if;

  select * into v_minutes from public.meeting_minutes where meeting_id = v_meeting.id for update;

  if found then
    if v_minutes.minutes_status = 'final' then
      raise exception 'The minutes of % are final and cannot be edited. Record an amendment instead.',
        v_meeting.meeting_reference using errcode = 'TA093';
    end if;
    update public.meeting_minutes set minutes_content = coalesce(p_content, '')
     where id = v_minutes.id
    returning * into v_minutes;
  else
    insert into public.meeting_minutes (meeting_id, minutes_content, minutes_status, created_by_staff_id)
    values (v_meeting.id, coalesce(p_content, ''), 'draft', v_staff_id)
    returning * into v_minutes;
  end if;

  return jsonb_build_object(
    'minutes_id', v_minutes.id, 'minutes_status', v_minutes.minutes_status);
end;
$$;

create or replace function public.secretary_finalize_minutes(p_meeting_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_meeting  public.council_meetings;
  v_minutes  public.meeting_minutes;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if v_meeting.meeting_status <> 'held' then
    raise exception 'Meeting % is recorded as %. Only a meeting that was held has minutes to finalise.',
      v_meeting.meeting_reference, v_meeting.meeting_status using errcode = 'TA092';
  end if;

  select * into v_minutes from public.meeting_minutes where meeting_id = v_meeting.id for update;
  if not found then
    raise exception 'There are no minutes for % to finalise yet.', v_meeting.meeting_reference
      using errcode = 'TA094';
  end if;
  if v_minutes.minutes_status = 'final' then
    raise exception 'The minutes of % are already final.', v_meeting.meeting_reference
      using errcode = 'TA093';
  end if;
  if btrim(coalesce(v_minutes.minutes_content, '')) = '' then
    raise exception 'Empty minutes cannot be finalised.' using errcode = 'TA094';
  end if;

  update public.meeting_minutes
     set minutes_status = 'final', finalized_at = now(), finalized_by_staff_id = v_staff_id
   where id = v_minutes.id
  returning * into v_minutes;

  return jsonb_build_object(
    'minutes_id', v_minutes.id,
    'minutes_status', v_minutes.minutes_status,
    'finalized_at', v_minutes.finalized_at);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Amendments — the only way a finalised minute is ever corrected
-- ---------------------------------------------------------------------

create or replace function public.secretary_add_amendment(
  p_minutes_id     uuid,
  p_amendment_text text,
  p_reason         text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id  uuid := public.acting_council_secretary_staff_id();
  v_minutes   public.meeting_minutes;
  v_amendment public.meeting_minutes_amendments;
begin
  select * into v_minutes from public.meeting_minutes where id = p_minutes_id;
  if not found then
    raise exception 'Those minutes could not be found.' using errcode = 'TA094';
  end if;
  if v_minutes.minutes_status <> 'final' then
    raise exception 'Only final minutes are amended. A draft is simply edited.'
      using errcode = 'TA095';
  end if;
  if btrim(coalesce(p_amendment_text, '')) = '' then
    raise exception 'An amendment needs the correction itself.' using errcode = 'TA096';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'An amendment needs a reason.' using errcode = 'TA096';
  end if;

  insert into public.meeting_minutes_amendments (
    minutes_id, amendment_reference, amendment_text, reason, created_by_staff_id)
  values (
    v_minutes.id,
    public.council_reference('AMD-', 'amendment_reference', 'meeting_minutes_amendments'),
    btrim(p_amendment_text), btrim(p_reason), v_staff_id)
  returning * into v_amendment;

  return jsonb_build_object(
    'amendment_id', v_amendment.id,
    'amendment_reference', v_amendment.amendment_reference);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Resolutions
--
--    The decision date is the meeting's date. It is not a parameter,
--    so no browser can claim a different one.
-- ---------------------------------------------------------------------

create or replace function public.secretary_record_resolution(
  p_meeting_id      uuid,
  p_resolution_text text,
  p_visibility      text default 'internal'
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_council_secretary_staff_id();
  v_meeting    public.council_meetings;
  v_resolution public.council_resolutions;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if v_meeting.meeting_status = 'cancelled' then
    raise exception 'Meeting % was cancelled, so it decided nothing.', v_meeting.meeting_reference
      using errcode = 'TA097';
  end if;
  if btrim(coalesce(p_resolution_text, '')) = '' then
    raise exception 'A resolution needs its wording.' using errcode = 'TA097';
  end if;
  if p_visibility is null or p_visibility not in ('internal', 'public') then
    raise exception 'A resolution is internal or public.' using errcode = 'TA098';
  end if;

  insert into public.council_resolutions (
    resolution_reference, meeting_id, resolution_text, decision_date,
    resolution_status, visibility, created_by_staff_id)
  values (
    public.council_reference('RES-', 'resolution_reference', 'council_resolutions'),
    v_meeting.id, btrim(p_resolution_text), v_meeting.meeting_date,
    'active', p_visibility, v_staff_id)
  returning * into v_resolution;

  -- A resolution recorded as public from the start is still a
  -- publication, and the record says so.
  if p_visibility = 'public' then
    insert into public.visibility_changes (
      subject_type, resolution_id, from_visibility, to_visibility, reason, changed_by_staff_id)
    values ('resolution', v_resolution.id, 'internal', 'public',
            'Recorded as public when the resolution was captured', v_staff_id);
  end if;

  return jsonb_build_object(
    'resolution_id', v_resolution.id,
    'resolution_reference', v_resolution.resolution_reference,
    'decision_date', v_resolution.decision_date);
end;
$$;

create or replace function public.secretary_update_resolution(
  p_resolution_id   uuid,
  p_resolution_text text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_resolution public.council_resolutions;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_resolution from public.council_resolutions where id = p_resolution_id for update;
  if not found then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;
  if v_resolution.resolution_status <> 'active' then
    raise exception 'Resolution % is %, so its wording is part of the record.',
      v_resolution.resolution_reference, v_resolution.resolution_status using errcode = 'TA097';
  end if;
  if public.meeting_minutes_are_final(v_resolution.meeting_id) then
    raise exception 'The minutes of that meeting are final, so resolution % cannot be reworded. Record an amendment to the minutes instead.',
      v_resolution.resolution_reference using errcode = 'TA093';
  end if;
  if btrim(coalesce(p_resolution_text, '')) = '' then
    raise exception 'A resolution needs its wording.' using errcode = 'TA097';
  end if;

  update public.council_resolutions set resolution_text = btrim(p_resolution_text)
   where id = v_resolution.id
  returning * into v_resolution;

  return jsonb_build_object(
    'resolution_id', v_resolution.id,
    'resolution_reference', v_resolution.resolution_reference);
end;
$$;

create or replace function public.secretary_set_resolution_status(
  p_resolution_id uuid,
  p_status        text,
  p_reason        text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_council_secretary_staff_id();
  v_resolution public.council_resolutions;
begin
  select * into v_resolution from public.council_resolutions where id = p_resolution_id for update;
  if not found then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;
  if p_status is null or p_status not in ('active', 'implemented', 'withdrawn') then
    raise exception 'A resolution is active, implemented or withdrawn.' using errcode = 'TA097';
  end if;
  if v_resolution.resolution_status = 'withdrawn' then
    raise exception 'Resolution % has been withdrawn; that stands.', v_resolution.resolution_reference
      using errcode = 'TA097';
  end if;
  if p_status = v_resolution.resolution_status then
    raise exception 'Resolution % is already %.', v_resolution.resolution_reference, p_status
      using errcode = 'TA097';
  end if;
  if p_status = 'active' then
    raise exception 'Resolution % cannot be made active again.', v_resolution.resolution_reference
      using errcode = 'TA097';
  end if;

  if p_status = 'implemented' then
    update public.council_resolutions
       set resolution_status = 'implemented', implemented_at = now(),
           implemented_by_staff_id = v_staff_id
     where id = v_resolution.id
    returning * into v_resolution;
  else
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'A reason is required to withdraw a resolution.' using errcode = 'TA100';
    end if;
    update public.council_resolutions
       set resolution_status = 'withdrawn', withdrawal_reason = btrim(p_reason),
           withdrawn_at = now(), withdrawn_by_staff_id = v_staff_id
     where id = v_resolution.id
    returning * into v_resolution;
  end if;

  return jsonb_build_object(
    'resolution_id', v_resolution.id,
    'resolution_reference', v_resolution.resolution_reference,
    'resolution_status', v_resolution.resolution_status);
end;
$$;

-- Publishing, and taking a publication back. Either direction is
-- written down; taking one back always says why.
create or replace function public.secretary_set_resolution_visibility(
  p_resolution_id uuid,
  p_visibility    text,
  p_reason        text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_council_secretary_staff_id();
  v_resolution public.council_resolutions;
  v_from       text;
begin
  select * into v_resolution from public.council_resolutions where id = p_resolution_id for update;
  if not found then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;
  if p_visibility is null or p_visibility not in ('internal', 'public') then
    raise exception 'A resolution is internal or public.' using errcode = 'TA098';
  end if;
  v_from := v_resolution.visibility;
  if v_from = p_visibility then
    raise exception 'Resolution % is already %.', v_resolution.resolution_reference, p_visibility
      using errcode = 'TA098';
  end if;
  if v_from = 'public' and p_visibility = 'internal'
     and btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Taking resolution % back off the public record needs a reason.',
      v_resolution.resolution_reference using errcode = 'TA101';
  end if;

  update public.council_resolutions set visibility = p_visibility
   where id = v_resolution.id
  returning * into v_resolution;

  insert into public.visibility_changes (
    subject_type, resolution_id, from_visibility, to_visibility, reason, changed_by_staff_id)
  values ('resolution', v_resolution.id, v_from, p_visibility,
          nullif(btrim(coalesce(p_reason, '')), ''), v_staff_id);

  return jsonb_build_object(
    'resolution_id', v_resolution.id,
    'resolution_reference', v_resolution.resolution_reference,
    'visibility', v_resolution.visibility);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Projects
-- ---------------------------------------------------------------------

create or replace function public.secretary_create_project(
  p_project_name           text,
  p_description            text,
  p_start_date             date,
  p_target_completion_date date default null,
  p_resolution_id          uuid default null,
  p_visibility             text default 'internal'
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_project  public.community_projects;
begin
  if btrim(coalesce(p_project_name, '')) = '' or btrim(coalesce(p_description, '')) = '' then
    raise exception 'A project needs a name and a description.' using errcode = 'TA102';
  end if;
  if p_start_date is null then
    raise exception 'A project needs a start date.' using errcode = 'TA103';
  end if;
  if p_target_completion_date is not null and p_target_completion_date < p_start_date then
    raise exception 'A target completion date of % is before the start date of %.',
      p_target_completion_date, p_start_date using errcode = 'TA103';
  end if;
  if p_visibility is null or p_visibility not in ('internal', 'public') then
    raise exception 'A project is internal or public.' using errcode = 'TA098';
  end if;
  -- Linking a resolution is optional; naming one that does not exist is not.
  if p_resolution_id is not null
     and not exists (select 1 from public.council_resolutions where id = p_resolution_id) then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;

  insert into public.community_projects (
    project_reference, project_name, description, resolution_id, start_date,
    target_completion_date, project_status, visibility, created_by_staff_id)
  values (
    public.council_reference('PRJ-', 'project_reference', 'community_projects'),
    btrim(p_project_name), btrim(p_description), p_resolution_id, p_start_date,
    p_target_completion_date, 'planned', p_visibility, v_staff_id)
  returning * into v_project;

  if p_visibility = 'public' then
    insert into public.visibility_changes (
      subject_type, project_id, from_visibility, to_visibility, reason, changed_by_staff_id)
    values ('project', v_project.id, 'internal', 'public',
            'Recorded as public when the project was created', v_staff_id);
  end if;

  return jsonb_build_object(
    'project_id', v_project.id, 'project_reference', v_project.project_reference);
end;
$$;

create or replace function public.secretary_update_project(
  p_project_id             uuid,
  p_project_name           text,
  p_description            text,
  p_start_date             date,
  p_target_completion_date date default null,
  p_resolution_id          uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_project public.community_projects;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_project from public.community_projects where id = p_project_id for update;
  if not found then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  if v_project.project_status in ('completed', 'cancelled') then
    raise exception 'Project % is %, so its details are part of the record.',
      v_project.project_reference, v_project.project_status using errcode = 'TA105';
  end if;
  if btrim(coalesce(p_project_name, '')) = '' or btrim(coalesce(p_description, '')) = '' then
    raise exception 'A project needs a name and a description.' using errcode = 'TA102';
  end if;
  if p_start_date is null then
    raise exception 'A project needs a start date.' using errcode = 'TA103';
  end if;
  if p_target_completion_date is not null and p_target_completion_date < p_start_date then
    raise exception 'A target completion date of % is before the start date of %.',
      p_target_completion_date, p_start_date using errcode = 'TA103';
  end if;
  if p_resolution_id is not null
     and not exists (select 1 from public.council_resolutions where id = p_resolution_id) then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;

  update public.community_projects
     set project_name = btrim(p_project_name), description = btrim(p_description),
         start_date = p_start_date, target_completion_date = p_target_completion_date,
         resolution_id = p_resolution_id
   where id = v_project.id
  returning * into v_project;

  return jsonb_build_object(
    'project_id', v_project.id, 'project_reference', v_project.project_reference);
end;
$$;

-- Completion is always the Secretary's own decision: finishing every
-- milestone does not finish a project by itself.
create or replace function public.secretary_set_project_status(
  p_project_id uuid,
  p_status     text,
  p_reason     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_project  public.community_projects;
begin
  select * into v_project from public.community_projects where id = p_project_id for update;
  if not found then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  if p_status is null or p_status not in ('planned', 'active', 'completed', 'cancelled') then
    raise exception 'A project is planned, active, completed or cancelled.' using errcode = 'TA105';
  end if;
  if v_project.project_status in ('completed', 'cancelled') then
    raise exception 'Project % is already %, and that stands.',
      v_project.project_reference, v_project.project_status using errcode = 'TA105';
  end if;
  if p_status = v_project.project_status then
    raise exception 'Project % is already %.', v_project.project_reference, p_status
      using errcode = 'TA105';
  end if;
  if p_status = 'planned' then
    raise exception 'Project % cannot go back to planned.', v_project.project_reference
      using errcode = 'TA105';
  end if;

  if p_status = 'cancelled' then
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'A reason is required to cancel a project.' using errcode = 'TA106';
    end if;
    update public.community_projects
       set project_status = 'cancelled', cancellation_reason = btrim(p_reason),
           cancelled_at = now(), cancelled_by_staff_id = v_staff_id
     where id = v_project.id
    returning * into v_project;
  elsif p_status = 'completed' then
    update public.community_projects
       set project_status = 'completed', completed_on = current_date,
           completed_at = now(), completed_by_staff_id = v_staff_id
     where id = v_project.id
    returning * into v_project;
  else
    update public.community_projects set project_status = 'active'
     where id = v_project.id
    returning * into v_project;
  end if;

  return jsonb_build_object(
    'project_id', v_project.id,
    'project_reference', v_project.project_reference,
    'project_status', v_project.project_status);
end;
$$;

create or replace function public.secretary_set_project_visibility(
  p_project_id uuid,
  p_visibility text,
  p_reason     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_project  public.community_projects;
  v_from     text;
begin
  select * into v_project from public.community_projects where id = p_project_id for update;
  if not found then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  if p_visibility is null or p_visibility not in ('internal', 'public') then
    raise exception 'A project is internal or public.' using errcode = 'TA098';
  end if;
  v_from := v_project.visibility;
  if v_from = p_visibility then
    raise exception 'Project % is already %.', v_project.project_reference, p_visibility
      using errcode = 'TA098';
  end if;
  if v_from = 'public' and p_visibility = 'internal'
     and btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Taking project % back off the public record needs a reason.',
      v_project.project_reference using errcode = 'TA101';
  end if;

  update public.community_projects set visibility = p_visibility
   where id = v_project.id
  returning * into v_project;

  insert into public.visibility_changes (
    subject_type, project_id, from_visibility, to_visibility, reason, changed_by_staff_id)
  values ('project', v_project.id, v_from, p_visibility,
          nullif(btrim(coalesce(p_reason, '')), ''), v_staff_id);

  return jsonb_build_object(
    'project_id', v_project.id,
    'project_reference', v_project.project_reference,
    'visibility', v_project.visibility);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Milestones
-- ---------------------------------------------------------------------

create or replace function public.secretary_add_milestone(
  p_project_id  uuid,
  p_title       text,
  p_due_date    date,
  p_description text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id  uuid := public.acting_council_secretary_staff_id();
  v_project   public.community_projects;
  v_milestone public.project_milestones;
begin
  select * into v_project from public.community_projects where id = p_project_id;
  if not found then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  if v_project.project_status in ('completed', 'cancelled') then
    raise exception 'Project % is %, so no milestone can be added to it.',
      v_project.project_reference, v_project.project_status using errcode = 'TA105';
  end if;
  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'A milestone needs a title.' using errcode = 'TA107';
  end if;
  if p_due_date is null then
    raise exception 'A milestone needs a due date.' using errcode = 'TA108';
  end if;
  if p_due_date < v_project.start_date then
    raise exception 'A milestone due on % falls before the project starts on %.',
      p_due_date, v_project.start_date using errcode = 'TA108';
  end if;

  insert into public.project_milestones (
    project_id, title, description, due_date, milestone_status, created_by_staff_id)
  values (v_project.id, btrim(p_title), nullif(btrim(coalesce(p_description, '')), ''),
          p_due_date, 'pending', v_staff_id)
  returning * into v_milestone;

  return jsonb_build_object('milestone_id', v_milestone.id, 'title', v_milestone.title);
end;
$$;

create or replace function public.secretary_update_milestone(
  p_milestone_id uuid,
  p_title        text,
  p_due_date     date,
  p_description  text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_milestone public.project_milestones;
  v_project   public.community_projects;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_milestone from public.project_milestones where id = p_milestone_id for update;
  if not found then
    raise exception 'That milestone could not be found.' using errcode = 'TA107';
  end if;
  select * into v_project from public.community_projects where id = v_milestone.project_id;

  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'A milestone needs a title.' using errcode = 'TA107';
  end if;
  if p_due_date is null then
    raise exception 'A milestone needs a due date.' using errcode = 'TA108';
  end if;
  if p_due_date < v_project.start_date then
    raise exception 'A milestone due on % falls before the project starts on %.',
      p_due_date, v_project.start_date using errcode = 'TA108';
  end if;

  update public.project_milestones
     set title = btrim(p_title), due_date = p_due_date,
         description = nullif(btrim(coalesce(p_description, '')), '')
   where id = v_milestone.id
  returning * into v_milestone;

  return jsonb_build_object('milestone_id', v_milestone.id, 'title', v_milestone.title);
end;
$$;

create or replace function public.secretary_set_milestone_status(
  p_milestone_id uuid,
  p_status       text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id  uuid := public.acting_council_secretary_staff_id();
  v_milestone public.project_milestones;
begin
  select * into v_milestone from public.project_milestones where id = p_milestone_id for update;
  if not found then
    raise exception 'That milestone could not be found.' using errcode = 'TA107';
  end if;
  -- 'overdue' is deliberately not offered: it is never stored.
  if p_status is null or p_status not in ('pending', 'in_progress', 'completed') then
    raise exception 'A milestone is pending, in progress or completed. Overdue is worked out from the due date, not chosen.'
      using errcode = 'TA109';
  end if;
  if v_milestone.milestone_status = p_status then
    raise exception 'That milestone is already %.', replace(p_status, '_', ' ')
      using errcode = 'TA109';
  end if;

  if p_status = 'completed' then
    update public.project_milestones
       set milestone_status = 'completed', completed_at = now(), completed_by_staff_id = v_staff_id
     where id = v_milestone.id
    returning * into v_milestone;
  else
    update public.project_milestones
       set milestone_status = p_status, completed_at = null, completed_by_staff_id = null
     where id = v_milestone.id
    returning * into v_milestone;
  end if;

  return jsonb_build_object(
    'milestone_id', v_milestone.id,
    'milestone_status', v_milestone.milestone_status,
    'effective_status', public.milestone_effective_status(
      v_milestone.milestone_status, v_milestone.due_date),
    'completed_at', v_milestone.completed_at);
end;
$$;

-- ---------------------------------------------------------------------
-- 11. What the Secretary sees
-- ---------------------------------------------------------------------

create or replace function public.secretary_meetings(
  p_status text default null,
  p_type   text default null,
  p_when   text default null,     -- 'upcoming', 'past', or null for both
  p_search text default null
)
returns table (
  meeting_id uuid, meeting_reference text, title text, meeting_type text,
  meeting_date date, start_time time, venue text, meeting_status text,
  cancellation_reason text, minutes_status text, resolution_count bigint,
  attendee_count bigint, present_count bigint
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select m.id, m.meeting_reference, m.title, m.meeting_type, m.meeting_date,
           m.start_time, m.venue, m.meeting_status, m.cancellation_reason,
           (select mm.minutes_status from public.meeting_minutes mm where mm.meeting_id = m.id),
           (select count(*) from public.council_resolutions r where r.meeting_id = m.id),
           (select count(*) from public.meeting_attendance a where a.meeting_id = m.id),
           (select count(*) from public.meeting_attendance a
             where a.meeting_id = m.id and a.attendance_status = 'present')
    from public.council_meetings m
    where (p_status is null or m.meeting_status = p_status)
      and (p_type is null or m.meeting_type = p_type)
      and (p_when is null
           or (p_when = 'upcoming' and m.meeting_date >= current_date)
           or (p_when = 'past' and m.meeting_date < current_date))
      and (v_empty or m.meeting_reference ilike v_pattern or m.title ilike v_pattern
           or m.venue ilike v_pattern)
    order by m.meeting_date desc, m.start_time desc;
end;
$$;

-- One meeting, and everything that belongs to it: who was there, the
-- minutes, every amendment to them, and every resolution it produced.
create or replace function public.secretary_meeting(p_meeting_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.acting_council_secretary_staff_id();

  select jsonb_build_object(
    'meeting_id',          m.id,
    'meeting_reference',   m.meeting_reference,
    'title',               m.title,
    'meeting_type',        m.meeting_type,
    'meeting_date',        m.meeting_date,
    'start_time',          m.start_time,
    'venue',               m.venue,
    'agenda',              m.agenda,
    'meeting_status',      m.meeting_status,
    'cancellation_reason', m.cancellation_reason,
    'created_by',          (select s.first_name || ' ' || s.last_name from public.staff s
                             where s.id = m.created_by_staff_id),
    'created_at',          m.created_at,

    'attendance', coalesce((
      select jsonb_agg(jsonb_build_object(
               'attendance_id',     a.id,
               'attendee_name',     a.attendee_name,
               'role_or_capacity',  a.role_or_capacity,
               'attendance_status', a.attendance_status)
             order by a.attendee_name)
      from public.meeting_attendance a where a.meeting_id = m.id), '[]'::jsonb),

    'minutes', (
      select jsonb_build_object(
               'minutes_id',      mm.id,
               'minutes_content', mm.minutes_content,
               'minutes_status',  mm.minutes_status,
               'finalized_at',    mm.finalized_at,
               'finalized_by',    (select s.first_name || ' ' || s.last_name from public.staff s
                                    where s.id = mm.finalized_by_staff_id),
               'amendments', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'amendment_id',        am.id,
                          'amendment_reference', am.amendment_reference,
                          'amendment_text',      am.amendment_text,
                          'reason',              am.reason,
                          'created_at',          am.created_at,
                          'created_by', (select s.first_name || ' ' || s.last_name
                                          from public.staff s where s.id = am.created_by_staff_id))
                        order by am.created_at)
                 from public.meeting_minutes_amendments am where am.minutes_id = mm.id), '[]'::jsonb))
      from public.meeting_minutes mm where mm.meeting_id = m.id),

    'resolutions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'resolution_id',        r.id,
               'resolution_reference', r.resolution_reference,
               'resolution_text',      r.resolution_text,
               'decision_date',        r.decision_date,
               'resolution_status',    r.resolution_status,
               'visibility',           r.visibility,
               'withdrawal_reason',    r.withdrawal_reason)
             order by r.resolution_reference)
      from public.council_resolutions r where r.meeting_id = m.id), '[]'::jsonb)
  ) into v_result
  from public.council_meetings m where m.id = p_meeting_id;

  if v_result is null then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  return v_result;
end;
$$;

create or replace function public.secretary_resolutions(
  p_status     text default null,
  p_visibility text default null,
  p_search     text default null
)
returns table (
  resolution_id uuid, resolution_reference text, resolution_text text,
  decision_date date, resolution_status text, visibility text,
  withdrawal_reason text, meeting_id uuid, meeting_reference text, meeting_title text,
  minutes_status text, visible_to_residents boolean, project_count bigint
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select r.id, r.resolution_reference, r.resolution_text, r.decision_date,
           r.resolution_status, r.visibility, r.withdrawal_reason,
           m.id, m.meeting_reference, m.title,
           mm.minutes_status,
           (r.visibility = 'public' and coalesce(mm.minutes_status, 'draft') = 'final'),
           (select count(*) from public.community_projects p where p.resolution_id = r.id)
    from public.council_resolutions r
    join public.council_meetings m on m.id = r.meeting_id
    left join public.meeting_minutes mm on mm.meeting_id = m.id
    where (p_status is null or r.resolution_status = p_status)
      and (p_visibility is null or r.visibility = p_visibility)
      and (v_empty or r.resolution_reference ilike v_pattern
           or r.resolution_text ilike v_pattern or m.meeting_reference ilike v_pattern)
    order by r.decision_date desc, r.resolution_reference desc;
end;
$$;

create or replace function public.secretary_projects(
  p_status     text default null,
  p_visibility text default null,
  p_search     text default null
)
returns table (
  project_id uuid, project_reference text, project_name text, description text,
  start_date date, target_completion_date date, project_status text, visibility text,
  cancellation_reason text, completed_on date,
  resolution_id uuid, resolution_reference text, resolution_visibility text,
  milestone_count bigint, completed_milestones bigint, overdue_milestones bigint
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select p.id, p.project_reference, p.project_name, p.description, p.start_date,
           p.target_completion_date, p.project_status, p.visibility,
           p.cancellation_reason, p.completed_on,
           r.id, r.resolution_reference, r.visibility,
           (select count(*) from public.project_milestones ms where ms.project_id = p.id),
           (select count(*) from public.project_milestones ms
             where ms.project_id = p.id and ms.milestone_status = 'completed'),
           (select count(*) from public.project_milestones ms
             where ms.project_id = p.id
               and public.milestone_effective_status(ms.milestone_status, ms.due_date) = 'overdue')
    from public.community_projects p
    left join public.council_resolutions r on r.id = p.resolution_id
    where (p_status is null or p.project_status = p_status)
      and (p_visibility is null or p.visibility = p_visibility)
      and (v_empty or p.project_reference ilike v_pattern or p.project_name ilike v_pattern
           or p.description ilike v_pattern)
    order by p.start_date desc, p.project_reference desc;
end;
$$;

create or replace function public.secretary_project(p_project_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.acting_council_secretary_staff_id();

  select jsonb_build_object(
    'project_id',             p.id,
    'project_reference',      p.project_reference,
    'project_name',           p.project_name,
    'description',            p.description,
    'start_date',             p.start_date,
    'target_completion_date', p.target_completion_date,
    'project_status',         p.project_status,
    'visibility',             p.visibility,
    'cancellation_reason',    p.cancellation_reason,
    'completed_on',           p.completed_on,
    'created_by',             (select s.first_name || ' ' || s.last_name from public.staff s
                                where s.id = p.created_by_staff_id),
    'created_at',             p.created_at,
    'resolution', (
      select jsonb_build_object(
               'resolution_id',        r.id,
               'resolution_reference', r.resolution_reference,
               'resolution_text',      r.resolution_text,
               'visibility',           r.visibility,
               'resolution_status',    r.resolution_status,
               'meeting_reference',    (select m.meeting_reference from public.council_meetings m
                                         where m.id = r.meeting_id))
      from public.council_resolutions r where r.id = p.resolution_id),

    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'milestone_id',     ms.id,
               'title',            ms.title,
               'description',      ms.description,
               'due_date',         ms.due_date,
               'milestone_status', ms.milestone_status,
               'effective_status', public.milestone_effective_status(ms.milestone_status, ms.due_date),
               'completed_at',     ms.completed_at)
             order by ms.due_date, ms.created_at)
      from public.project_milestones ms where ms.project_id = p.id), '[]'::jsonb),

    'visibility_history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'from_visibility', v.from_visibility,
               'to_visibility',   v.to_visibility,
               'reason',          v.reason,
               'changed_at',      v.changed_at,
               'changed_by', (select s.first_name || ' ' || s.last_name from public.staff s
                               where s.id = v.changed_by_staff_id))
             order by v.changed_at)
      from public.visibility_changes v where v.project_id = p.id), '[]'::jsonb)
  ) into v_result
  from public.community_projects p where p.id = p_project_id;

  if v_result is null then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  return v_result;
end;
$$;

-- The history of a resolution's publication, for the Secretary only.
create or replace function public.secretary_resolution_visibility_history(p_resolution_id uuid)
returns table (
  from_visibility text, to_visibility text, reason text,
  changed_at timestamptz, changed_by text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select v.from_visibility, v.to_visibility, v.reason, v.changed_at,
           (select s.first_name || ' ' || s.last_name from public.staff s
             where s.id = v.changed_by_staff_id)
    from public.visibility_changes v
    where v.resolution_id = p_resolution_id
    order by v.changed_at;
end;
$$;

-- ---------------------------------------------------------------------
-- 12. The dashboard
--
--     Overdue is counted from the due date every time this runs.
-- ---------------------------------------------------------------------

create or replace function public.secretary_dashboard()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_council_secretary_staff_id();
  return jsonb_build_object(
    'upcoming_meetings', (
      select count(*) from public.council_meetings
      where meeting_status = 'scheduled' and meeting_date >= current_date),
    'meetings_awaiting_minutes', (
      select count(*) from public.council_meetings m
      where m.meeting_status = 'held'
        and not exists (select 1 from public.meeting_minutes mm
                         where mm.meeting_id = m.id and mm.minutes_status = 'final')),
    'draft_minutes', (
      select count(*) from public.meeting_minutes where minutes_status = 'draft'),
    'final_minutes', (
      select count(*) from public.meeting_minutes where minutes_status = 'final'),
    'active_resolutions', (
      select count(*) from public.council_resolutions where resolution_status = 'active'),
    'public_resolutions', (
      select count(*) from public.council_resolutions r
      where r.visibility = 'public' and public.meeting_minutes_are_final(r.meeting_id)),
    'active_projects', (
      select count(*) from public.community_projects where project_status = 'active'),
    'planned_projects', (
      select count(*) from public.community_projects where project_status = 'planned'),
    'public_projects', (
      select count(*) from public.community_projects where visibility = 'public'),
    'overdue_milestones', (
      select count(*) from public.project_milestones ms
      join public.community_projects p on p.id = ms.project_id
      where p.project_status in ('planned', 'active')
        and public.milestone_effective_status(ms.milestone_status, ms.due_date) = 'overdue'),
    'next_meeting', (
      select jsonb_build_object(
               'meeting_id', m.id, 'meeting_reference', m.meeting_reference,
               'title', m.title, 'meeting_date', m.meeting_date, 'start_time', m.start_time,
               'venue', m.venue)
      from public.council_meetings m
      where m.meeting_status = 'scheduled' and m.meeting_date >= current_date
      order by m.meeting_date, m.start_time limit 1));
end;
$$;

-- ---------------------------------------------------------------------
-- 13. What a resident may see
--
--     Community Updates. Only public resolutions from meetings whose
--     minutes are final, only public projects, and the milestones of
--     those projects. Nothing about attendance, nothing about minutes —
--     not their contents, not their status, not whether they exist —
--     and nothing internal.
--
--     Every field here is chosen one at a time. This never selects a
--     whole row and leaves the browser to hide the rest of it.
-- ---------------------------------------------------------------------

create or replace function public.resident_community_updates()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_resident_id uuid := public.current_resident_id();
begin
  if v_resident_id is null then
    raise exception 'Community updates are for verified resident accounts.'
      using errcode = '42501';
  end if;

  return jsonb_build_object(
    'resolutions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'resolution_reference', r.resolution_reference,
               'resolution_text',      r.resolution_text,
               'decision_date',        r.decision_date,
               'resolution_status',    r.resolution_status)
             order by r.decision_date desc, r.resolution_reference desc)
      from public.council_resolutions r
      where r.visibility = 'public'
        and public.meeting_minutes_are_final(r.meeting_id)), '[]'::jsonb),

    'projects', coalesce((
      select jsonb_agg(project order by project ->> 'start_date' desc)
      from (
        select jsonb_build_object(
                 'project_reference',      p.project_reference,
                 'project_name',           p.project_name,
                 'description',            p.description,
                 'start_date',             p.start_date,
                 'target_completion_date', p.target_completion_date,
                 'project_status',         p.project_status,
                 -- Only ever the reference, and only when that
                 -- resolution is itself public and confirmed. A public
                 -- project never becomes a way of reading an internal
                 -- resolution.
                 'resolution_reference', (
                   select r.resolution_reference from public.council_resolutions r
                   where r.id = p.resolution_id
                     and r.visibility = 'public'
                     and public.meeting_minutes_are_final(r.meeting_id)),
                 'milestones', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'title',            ms.title,
                            'description',      ms.description,
                            'due_date',         ms.due_date,
                            'effective_status', public.milestone_effective_status(
                                                  ms.milestone_status, ms.due_date))
                          order by ms.due_date, ms.created_at)
                   from public.project_milestones ms where ms.project_id = p.id), '[]'::jsonb)
               ) as project
        from public.community_projects p
        where p.visibility = 'public'
      ) as public_projects), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- 14. Grants
--
--     Each function establishes its own caller, so execute may be given
--     to signed-in users: the functions turn away anyone who should not
--     be there.
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.is_active_council_secretary()',
    'public.milestone_effective_status(text, date)',
    'public.meeting_minutes_are_final(uuid)',
    'public.resolution_is_public(uuid)',
    'public.project_is_public(uuid)',
    'public.secretary_schedule_meeting(text, text, date, time, text, text)',
    'public.secretary_update_meeting(uuid, text, text, date, time, text, text)',
    'public.secretary_set_meeting_status(uuid, text, text)',
    'public.secretary_add_attendee(uuid, text, text, text)',
    'public.secretary_update_attendee(uuid, text, text, text)',
    'public.secretary_save_minutes(uuid, text)',
    'public.secretary_finalize_minutes(uuid)',
    'public.secretary_add_amendment(uuid, text, text)',
    'public.secretary_record_resolution(uuid, text, text)',
    'public.secretary_update_resolution(uuid, text)',
    'public.secretary_set_resolution_status(uuid, text, text)',
    'public.secretary_set_resolution_visibility(uuid, text, text)',
    'public.secretary_create_project(text, text, date, date, uuid, text)',
    'public.secretary_update_project(uuid, text, text, date, date, uuid)',
    'public.secretary_set_project_status(uuid, text, text)',
    'public.secretary_set_project_visibility(uuid, text, text)',
    'public.secretary_add_milestone(uuid, text, date, text)',
    'public.secretary_update_milestone(uuid, text, date, text)',
    'public.secretary_set_milestone_status(uuid, text)',
    'public.secretary_meetings(text, text, text, text)',
    'public.secretary_meeting(uuid)',
    'public.secretary_resolutions(text, text, text)',
    'public.secretary_projects(text, text, text)',
    'public.secretary_project(uuid)',
    'public.secretary_resolution_visibility_history(uuid)',
    'public.secretary_dashboard()',
    'public.resident_community_updates()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

revoke all on function public.acting_council_secretary_staff_id() from public, anon, authenticated;
revoke all on function public.council_reference(text, text, text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 20260929090000_notifications.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — one notification system for the whole application
--
-- Every important thing that happens to somebody is written down as an
-- in-app notification, and an email is queued for it separately. The
-- in-app notification is the authoritative one: it is created inside the
-- same transaction as the business action, so it cannot go missing,
-- while the email is a best effort that is allowed to fail without
-- undoing anything.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Notifications
-- ---------------------------------------------------------------------

create table if not exists public.notifications (
  id                        uuid primary key default gen_random_uuid(),
  recipient_user_account_id uuid not null references public.user_accounts (id) on delete cascade,
  notification_category     text not null,
  title                     text not null,
  message                   text not null,
  -- Where in TAMS this notification is about, if anywhere. Always an
  -- application path, never an external link.
  link_path                 text,
  source_entity_type        text,
  source_entity_id          uuid,
  source_reference          text,
  created_at                timestamptz not null default now(),
  read_at                   timestamptz,
  archived_at               timestamptz,

  constraint notifications_category_allowed check (notification_category in (
    'account', 'land_application', 'land_allocation', 'pto', 'pto_renewal',
    'community', 'official_notice', 'staff_message', 'work_request', 'administration')),
  constraint notifications_title_not_blank   check (btrim(title) <> ''),
  constraint notifications_message_not_blank check (btrim(message) <> ''),
  -- An application path and nothing that could send somebody elsewhere.
  constraint notifications_link_is_internal
    check (link_path is null or link_path ~ '^/[A-Za-z0-9/_.:-]*$')
);

create index if not exists notifications_recipient_idx
  on public.notifications (recipient_user_account_id, created_at desc);
create index if not exists notifications_unread_idx
  on public.notifications (recipient_user_account_id)
  where read_at is null and archived_at is null;

-- ---------------------------------------------------------------------
-- 2. Email delivery
--
--    One row per notification, at most. The unique constraint is what
--    stops a second queueing attempt creating a second email.
-- ---------------------------------------------------------------------

create table if not exists public.notification_email_deliveries (
  id                  uuid primary key default gen_random_uuid(),
  notification_id     uuid not null unique references public.notifications (id) on delete cascade,
  recipient_email     text not null,
  delivery_status     text not null default 'pending',
  attempt_count       int not null default 0,
  last_attempt_at     timestamptz,
  sent_at             timestamptz,
  provider_message_id text,
  -- Short, safe text. Never a provider key, never a stack trace.
  last_error          text,
  created_at          timestamptz not null default now(),

  constraint notification_email_status_allowed
    check (delivery_status in ('pending', 'sent', 'failed')),
  constraint notification_email_sent_shape
    check (delivery_status <> 'sent' or sent_at is not null)
);

create index if not exists notification_email_pending_idx
  on public.notification_email_deliveries (delivery_status, last_attempt_at)
  where delivery_status <> 'sent';

-- ---------------------------------------------------------------------
-- 3. Permission-to-occupy expiry warnings
--
--    One row per permission per threshold. The unique constraint is the
--    whole idempotency mechanism: a threshold can be reached many times
--    by a scheduled run, and only the first one writes anything.
-- ---------------------------------------------------------------------

create table if not exists public.pto_expiry_warnings (
  id              uuid primary key default gen_random_uuid(),
  pto_id          uuid not null references public.ptos (id) on delete cascade,
  threshold_days  int not null,
  notification_id uuid references public.notifications (id),
  expiry_date     date not null,
  created_at      timestamptz not null default now(),

  constraint pto_expiry_threshold_allowed check (threshold_days in (60, 30, 7)),
  constraint pto_expiry_warning_once unique (pto_id, threshold_days)
);

-- ---------------------------------------------------------------------
-- 4. Writing a notification
--
--    Internal only. `notify_user` is the single door: nothing else in
--    TAMS inserts into notifications, and no application role may
--    execute it, so nobody can invent a notification that looks like a
--    system event.
-- ---------------------------------------------------------------------

create or replace function public.notify_user(
  p_user_account_id uuid,
  p_category        text,
  p_title           text,
  p_message         text,
  p_link_path       text default null,
  p_entity_type     text default null,
  p_entity_id       uuid default null,
  p_reference       text default null
)
returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_account      public.user_accounts;
  v_notification public.notifications;
begin
  if p_user_account_id is null then return null; end if;

  select * into v_account from public.user_accounts where id = p_user_account_id;
  if not found then return null; end if;

  insert into public.notifications (
    recipient_user_account_id, notification_category, title, message,
    link_path, source_entity_type, source_entity_id, source_reference)
  values (
    v_account.id, p_category, btrim(p_title), btrim(p_message),
    p_link_path, p_entity_type, p_entity_id, p_reference)
  returning * into v_notification;

  -- The email is queued, never sent from here. A database transaction
  -- must never wait on an email provider, and must never be undone by
  -- one being down.
  insert into public.notification_email_deliveries (notification_id, recipient_email)
  values (v_notification.id, v_account.email)
  on conflict (notification_id) do nothing;

  return v_notification.id;
end;
$$;

-- The account behind a resident, when they have a working one.
create or replace function public.resident_account_id(p_resident_id uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select ua.id from public.user_accounts ua
  where ua.resident_id = p_resident_id
    and ua.account_type = 'resident'
    and ua.account_status = 'active'
  limit 1;
$$;

-- The account behind the head of a household, when they have one.
create or replace function public.household_head_account_id(p_household_id uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select public.resident_account_id(h.head_resident_id)
  from public.households h where h.id = p_household_id;
$$;

create or replace function public.staff_account_id(p_staff_id uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select ua.id from public.user_accounts ua
  where ua.staff_id = p_staff_id
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
  limit 1;
$$;

-- ---------------------------------------------------------------------
-- 5. What a recipient may do with their own notifications
-- ---------------------------------------------------------------------

create or replace function public.current_user_account_id()
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select id from public.user_accounts
  where auth_user_id = auth.uid() and account_status = 'active';
$$;

create or replace function public.my_notifications(
  p_scope text default 'inbox',    -- 'inbox', 'archived' or 'all'
  p_limit int default 100
)
returns table (
  notification_id uuid, notification_category text, title text, message text,
  link_path text, source_entity_type text, source_reference text,
  created_at timestamptz, read_at timestamptz, archived_at timestamptz
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.current_user_account_id();
begin
  if v_account is null then
    raise exception 'Notifications are for signed-in accounts.' using errcode = '42501';
  end if;
  return query
    select n.id, n.notification_category, n.title, n.message, n.link_path,
           n.source_entity_type, n.source_reference, n.created_at, n.read_at, n.archived_at
    from public.notifications n
    where n.recipient_user_account_id = v_account
      and (p_scope = 'all'
           or (p_scope = 'inbox' and n.archived_at is null)
           or (p_scope = 'archived' and n.archived_at is not null))
    order by n.created_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;

create or replace function public.my_unread_notification_count()
returns int
language sql stable security definer set search_path = public, pg_temp
as $$
  select count(*)::int from public.notifications n
  where n.recipient_user_account_id = public.current_user_account_id()
    and n.read_at is null and n.archived_at is null;
$$;

-- Marking read and archiving touch only those two columns, and only on
-- the caller's own rows. There is no way in here to change a title, a
-- message, a link or a source: those are the system's, not the
-- recipient's.
create or replace function public.mark_notification_read(p_notification_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.current_user_account_id();
        v_updated int;
begin
  if v_account is null then
    raise exception 'Notifications are for signed-in accounts.' using errcode = '42501';
  end if;
  update public.notifications set read_at = coalesce(read_at, now())
   where id = p_notification_id and recipient_user_account_id = v_account;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'That notification is not yours.' using errcode = '42501';
  end if;
  return jsonb_build_object('notification_id', p_notification_id, 'read', true);
end;
$$;

create or replace function public.mark_all_notifications_read()
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.current_user_account_id();
        v_updated int;
begin
  if v_account is null then
    raise exception 'Notifications are for signed-in accounts.' using errcode = '42501';
  end if;
  update public.notifications set read_at = now()
   where recipient_user_account_id = v_account and read_at is null and archived_at is null;
  get diagnostics v_updated = row_count;
  return jsonb_build_object('marked_read', v_updated);
end;
$$;

-- Archiving takes a notification out of the everyday inbox. It is not a
-- deletion: the row and its history stay exactly where they are.
create or replace function public.archive_notification(p_notification_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.current_user_account_id();
        v_updated int;
begin
  if v_account is null then
    raise exception 'Notifications are for signed-in accounts.' using errcode = '42501';
  end if;
  update public.notifications
     set archived_at = coalesce(archived_at, now()), read_at = coalesce(read_at, now())
   where id = p_notification_id and recipient_user_account_id = v_account;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'That notification is not yours.' using errcode = '42501';
  end if;
  return jsonb_build_object('notification_id', p_notification_id, 'archived', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. The email worker's own doors
--
--    Only service_role may execute these: the worker runs as an edge
--    function with the service key, never as a browser.
-- ---------------------------------------------------------------------

-- Hands the worker a batch and records the attempt in the same
-- statement, so two workers running at once cannot take the same row.
create or replace function public.claim_notification_emails(
  p_limit        int default 25,
  p_max_attempts int default 5,
  p_retry_after  interval default interval '10 minutes'
)
returns table (
  delivery_id uuid, notification_id uuid, recipient_email text,
  title text, message text, link_path text, notification_category text, attempt_count int
)
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
begin
  return query
    with claimed as (
      select d.id
      from public.notification_email_deliveries d
      where d.delivery_status <> 'sent'
        and d.attempt_count < greatest(coalesce(p_max_attempts, 5), 1)
        and (d.last_attempt_at is null or d.last_attempt_at < now() - p_retry_after)
      order by d.created_at
      limit least(greatest(coalesce(p_limit, 25), 1), 200)
      for update skip locked
    )
    update public.notification_email_deliveries d
       set attempt_count = d.attempt_count + 1,
           last_attempt_at = now(),
           delivery_status = 'pending'
     from claimed c, public.notifications n
    where d.id = c.id and n.id = d.notification_id
    returning d.id, n.id, d.recipient_email, n.title, n.message, n.link_path,
              n.notification_category, d.attempt_count;
end;
$$;

create or replace function public.mark_notification_email_sent(
  p_delivery_id uuid,
  p_provider_message_id text default null
)
returns void
language sql volatile security definer set search_path = public, pg_temp
as $$
  update public.notification_email_deliveries
     set delivery_status = 'sent', sent_at = now(),
         provider_message_id = p_provider_message_id, last_error = null
   where id = p_delivery_id and delivery_status <> 'sent';
$$;

-- The error text is trimmed hard on the way in. Nothing a provider says
-- is allowed to become a long, quotable blob in the database.
create or replace function public.mark_notification_email_failed(
  p_delivery_id  uuid,
  p_error        text,
  p_max_attempts int default 5
)
returns void
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
begin
  update public.notification_email_deliveries
     set delivery_status = case when attempt_count >= greatest(coalesce(p_max_attempts, 5), 1)
                                then 'failed' else 'pending' end,
         last_error = left(regexp_replace(coalesce(p_error, 'Unknown error'), '\s+', ' ', 'g'), 300)
   where id = p_delivery_id and delivery_status <> 'sent';
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Expiry warnings for the permissions that have a term
--
--    Residential and burial permissions are perpetual and are never
--    warned about — they have no expiry date at all, so they cannot
--    match. Each permission gets each threshold exactly once, which the
--    unique constraint guarantees no matter how often this runs.
-- ---------------------------------------------------------------------

create or replace function public.queue_pto_expiry_warnings()
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_threshold int;
  v_row       record;
  v_account   uuid;
  v_created   int := 0;
  v_notification uuid;
begin
  foreach v_threshold in array array[60, 30, 7]
  loop
    for v_row in
      select p.id, p.pto_number, p.land_type, p.expiry_date,
             p.holder_resident_id, p.holder_household_id,
             s.site_code
      from public.ptos p
      join public.land_allocations a on a.id = p.land_allocation_id
      join public.land_sites s on s.id = a.land_site_id
      where p.land_type in ('farming', 'business')
        and p.pto_status = 'active'
        and p.expiry_date is not null
        and p.expiry_date >= current_date
        and p.expiry_date <= current_date + v_threshold
        and not exists (select 1 from public.pto_expiry_warnings w
                         where w.pto_id = p.id and w.threshold_days = v_threshold)
    loop
      -- Business is held by the person; farming by the household, so it
      -- goes to whoever heads that household today.
      v_account := case
        when v_row.holder_resident_id is not null then public.resident_account_id(v_row.holder_resident_id)
        else public.household_head_account_id(v_row.holder_household_id) end;

      v_notification := public.notify_user(
        v_account, 'pto',
        v_row.pto_number || ' expires in ' || v_threshold || ' days',
        'Your ' || v_row.land_type || ' permission to occupy ' || v_row.pto_number ||
          ' for site ' || v_row.site_code || ' expires on ' ||
          to_char(v_row.expiry_date, 'DD Mon YYYY') ||
          '. You may ask the Land Officer to renew it.',
        '/resident', 'pto', v_row.id, v_row.pto_number);

      -- Written whether or not there was an account to notify, so the
      -- threshold is never reconsidered for this permission.
      insert into public.pto_expiry_warnings (pto_id, threshold_days, notification_id, expiry_date)
      values (v_row.id, v_threshold, v_notification, v_row.expiry_date)
      on conflict (pto_id, threshold_days) do nothing;

      v_created := v_created + 1;
    end loop;
  end loop;

  return jsonb_build_object('warnings_created', v_created);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Row Level Security
--
--    A recipient reads their own notifications and nothing else, and
--    changes nothing directly: marking read and archiving go through
--    the functions above, which touch only those two columns.
--
--    Email deliveries are the worker's business alone. Nobody signed in
--    through a browser can read a provider message id or an error.
-- ---------------------------------------------------------------------

alter table public.notifications enable row level security;
alter table public.notifications force row level security;
revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;
grant all on public.notifications to service_role;

drop policy if exists notifications_own_only on public.notifications;
create policy notifications_own_only
  on public.notifications for select to authenticated
  using (recipient_user_account_id = public.current_user_account_id());

alter table public.notification_email_deliveries enable row level security;
alter table public.notification_email_deliveries force row level security;
revoke all on public.notification_email_deliveries from anon, authenticated;
grant all on public.notification_email_deliveries to service_role;

alter table public.pto_expiry_warnings enable row level security;
alter table public.pto_expiry_warnings force row level security;
revoke all on public.pto_expiry_warnings from anon, authenticated;
grant all on public.pto_expiry_warnings to service_role;

-- ---------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.my_notifications(text, int)',
    'public.my_unread_notification_count()',
    'public.mark_notification_read(uuid)',
    'public.mark_all_notifications_read()',
    'public.archive_notification(uuid)',
    'public.current_user_account_id()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

-- The system's own doors. No browser role may open any of them.
do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.notify_user(uuid, text, text, text, text, text, uuid, text)',
    'public.resident_account_id(uuid)',
    'public.household_head_account_id(uuid)',
    'public.staff_account_id(uuid)',
    'public.claim_notification_emails(int, int, interval)',
    'public.mark_notification_email_sent(uuid, text)',
    'public.mark_notification_email_failed(uuid, text, int)',
    'public.queue_pto_expiry_warnings()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
  end loop;
end;
$$;

grant execute on function public.claim_notification_emails(int, int, interval) to service_role;
grant execute on function public.mark_notification_email_sent(uuid, text) to service_role;
grant execute on function public.mark_notification_email_failed(uuid, text, int) to service_role;
grant execute on function public.queue_pto_expiry_warnings() to service_role;

-- ---------------------------------------------------------------------
-- 10. The events a person is told about
--
--     These are triggers rather than calls added to each function, for
--     one reason: a trigger cannot be forgotten. However the row comes
--     to be written — through the ordinary function, through a later
--     one, or by hand in the SQL editor — the person it concerns is
--     told, in the same transaction.
-- ---------------------------------------------------------------------

create or replace function public.tg_notify_resident_account_decision()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.request_status = old.request_status then return null; end if;

  if new.request_status = 'approved' then
    perform public.notify_user(
      new.user_account_id, 'account',
      'Your resident account has been approved',
      'Your account has been verified and linked to your record on the village register. ' ||
      'You can now apply for land and read the community updates.',
      '/resident', 'resident_account_request', new.id, null);
  elsif new.request_status = 'declined' then
    perform public.notify_user(
      new.user_account_id, 'account',
      'Your resident account could not be verified',
      'The Registry Clerk could not verify your details. Reason: ' ||
      coalesce(new.decline_reason, 'no reason was recorded') ||
      '. You can correct your details and apply again with this same account.',
      '/resident', 'resident_account_request', new.id, null);
  end if;
  return null;
end;
$$;

drop trigger if exists notify_resident_account_decision on public.resident_account_requests;
create trigger notify_resident_account_decision
  after update of request_status on public.resident_account_requests
  for each row execute function public.tg_notify_resident_account_decision();

create or replace function public.tg_notify_land_application_decision()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.resident_account_id(new.applicant_resident_id);
begin
  if new.application_status = old.application_status then return null; end if;

  if new.application_status = 'approved' then
    perform public.notify_user(
      v_account, 'land_application',
      'Land application ' || new.application_reference || ' has been approved',
      'Your ' || new.land_type || ' land application has been approved. ' ||
      'The Land Officer will allocate a site to you.',
      '/resident', 'land_application', new.id, new.application_reference);
  elsif new.application_status = 'declined' then
    perform public.notify_user(
      v_account, 'land_application',
      'Land application ' || new.application_reference || ' has been declined',
      'Your ' || new.land_type || ' land application has been declined. Reason: ' ||
      coalesce(new.decline_reason, 'no reason was recorded') || '.',
      '/resident', 'land_application', new.id, new.application_reference);
  end if;
  return null;
end;
$$;

drop trigger if exists notify_land_application_decision on public.land_applications;
create trigger notify_land_application_decision
  after update of application_status on public.land_applications
  for each row execute function public.tg_notify_land_application_decision();

create or replace function public.tg_notify_land_allocated()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_account uuid := case
    when new.resident_id is not null then public.resident_account_id(new.resident_id)
    else public.household_head_account_id(new.household_id) end;
  v_site text := (select site_code from public.land_sites where id = new.land_site_id);
begin
  if new.allocation_status <> 'active' then return null; end if;

  perform public.notify_user(
    v_account, 'land_allocation',
    'Site ' || v_site || ' has been allocated',
    'Site ' || v_site || ' has been allocated to you as ' || new.allocation_reference ||
    ' for ' || new.land_type || ' use. A permission to occupy will be issued for it.',
    '/resident', 'land_allocation', new.id, new.allocation_reference);
  return null;
end;
$$;

drop trigger if exists notify_land_allocated on public.land_allocations;
create trigger notify_land_allocated
  after insert on public.land_allocations
  for each row execute function public.tg_notify_land_allocated();

create or replace function public.tg_notify_pto_issued()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_account uuid := case
    when new.holder_resident_id is not null then public.resident_account_id(new.holder_resident_id)
    else public.household_head_account_id(new.holder_household_id) end;
begin
  if new.pto_status <> 'active' then return null; end if;

  perform public.notify_user(
    v_account, 'pto',
    'Permission to occupy ' || new.pto_number || ' has been issued',
    'Your ' || new.land_type || ' permission to occupy has been issued. ' ||
    case when new.expiry_date is null
         then 'It is perpetual and does not expire.'
         else 'It runs until ' || to_char(new.expiry_date, 'DD Mon YYYY') || '.' end,
    '/pto/' || new.id::text, 'pto', new.id, new.pto_number);
  return null;
end;
$$;

drop trigger if exists notify_pto_issued on public.ptos;
create trigger notify_pto_issued
  after insert on public.ptos
  for each row execute function public.tg_notify_pto_issued();

create or replace function public.tg_notify_pto_revoked()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_account uuid := case
    when new.holder_resident_id is not null then public.resident_account_id(new.holder_resident_id)
    else public.household_head_account_id(new.holder_household_id) end;
begin
  if new.pto_status <> 'revoked' or old.pto_status = 'revoked' then return null; end if;

  perform public.notify_user(
    v_account, 'pto',
    'Permission to occupy ' || new.pto_number || ' has been revoked',
    'Your permission to occupy ' || new.pto_number || ' has been revoked. Reason: ' ||
    coalesce(new.revocation_reason, 'no reason was recorded') ||
    '. Contact the traditional authority office if you need to discuss it.',
    '/resident', 'pto', new.id, new.pto_number);
  return null;
end;
$$;

drop trigger if exists notify_pto_revoked on public.ptos;
create trigger notify_pto_revoked
  after update of pto_status on public.ptos
  for each row execute function public.tg_notify_pto_revoked();

create or replace function public.tg_notify_renewal_decision()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_account uuid := public.resident_account_id(new.requested_by_resident_id);
  v_number  text := (select pto_number from public.ptos where id = new.pto_id);
  v_new     text := (select pto_number from public.ptos where id = new.resulting_pto_id);
begin
  if new.request_status = old.request_status then return null; end if;

  if new.request_status = 'approved' then
    perform public.notify_user(
      v_account, 'pto_renewal',
      'Your renewal of ' || v_number || ' has been approved',
      'A new permission to occupy, ' || coalesce(v_new, '(pending)') ||
      ', has been issued in place of ' || v_number || '. The site does not change.',
      case when new.resulting_pto_id is not null then '/pto/' || new.resulting_pto_id::text else '/resident' end,
      'pto_renewal_request', new.id, v_number);
  elsif new.request_status = 'declined' then
    perform public.notify_user(
      v_account, 'pto_renewal',
      'Your renewal of ' || v_number || ' has been declined',
      'The Land Officer has declined the renewal of ' || v_number || '. Reason: ' ||
      coalesce(new.decline_reason, 'no reason was recorded') ||
      '. Your existing permission is unchanged.',
      '/resident', 'pto_renewal_request', new.id, v_number);
  end if;
  return null;
end;
$$;

drop trigger if exists notify_renewal_decision on public.pto_renewal_requests;
create trigger notify_renewal_decision
  after update of request_status on public.pto_renewal_requests
  for each row execute function public.tg_notify_renewal_decision();

