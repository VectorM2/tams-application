-- Make the active Council Administrator the only usable TAMS account.
--
-- No account, Auth identity, resident, staff member or operational record is
-- deleted. The previous account statuses and staff deactivation metadata are
-- saved in the tams_private schema so restore_administrator_only.sql can undo this
-- exact batch later.

begin;

create schema if not exists tams_private;
revoke all on schema tams_private from public, anon, authenticated;

create table if not exists tams_private.administrator_only_batches (
  id            uuid primary key,
  enabled_at    timestamptz not null default now(),
  restored_at   timestamptz,
  account_count integer not null default 0 check (account_count >= 0)
);

create table if not exists tams_private.administrator_only_account_snapshot (
  batch_id                              uuid not null references tams_private.administrator_only_batches (id),
  user_account_id                       uuid not null,
  previous_account_status               text not null,
  staff_id                              uuid,
  previous_last_deactivated_at          timestamptz,
  previous_last_deactivated_by_staff_id uuid,
  previous_last_deactivation_reason     text,
  primary key (batch_id, user_account_id),
  constraint administrator_only_previous_status_allowed
    check (previous_account_status in ('active', 'deactivated', 'pending', 'declined'))
);

revoke all on tams_private.administrator_only_batches from public, anon, authenticated;
revoke all on tams_private.administrator_only_account_snapshot from public, anon, authenticated;

do $$
declare
  v_admin_account_id uuid;
  v_admin_staff_id   uuid;
  v_admin_count      integer;
  v_batch_id         uuid := gen_random_uuid();
  v_account_count    integer;
begin
  lock table public.user_accounts in share row exclusive mode;

  select count(*)
    into v_admin_count
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Administrator';

  if v_admin_count <> 1 then
    raise exception
      'Administrator-only mode requires exactly one active Council Administrator; found %.',
      v_admin_count;
  end if;

  select ua.id, s.id
    into v_admin_account_id, v_admin_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Administrator';

  if exists (
    select 1 from tams_private.administrator_only_batches where restored_at is null
  ) then
    raise exception
      'Administrator-only mode already has an unrestored batch. Do not run it twice.';
  end if;

  insert into tams_private.administrator_only_batches (id) values (v_batch_id);

  insert into tams_private.administrator_only_account_snapshot (
    batch_id,
    user_account_id,
    previous_account_status,
    staff_id,
    previous_last_deactivated_at,
    previous_last_deactivated_by_staff_id,
    previous_last_deactivation_reason
  )
  select
    v_batch_id,
    ua.id,
    ua.account_status,
    s.id,
    s.last_deactivated_at,
    s.last_deactivated_by_staff_id,
    s.last_deactivation_reason
  from public.user_accounts ua
  left join public.staff s on s.id = ua.staff_id
  where ua.id <> v_admin_account_id
    and ua.account_status <> 'deactivated';

  select count(*) into v_account_count
  from tams_private.administrator_only_account_snapshot
  where batch_id = v_batch_id;

  perform public.audit_context(
    'ADMINISTRATOR_ONLY_MODE_ENABLED',
    'Administrator-only deployment',
    v_batch_id
  );

  update public.user_accounts ua
     set account_status = 'deactivated'
   where exists (
     select 1
     from tams_private.administrator_only_account_snapshot snapshot
     where snapshot.batch_id = v_batch_id
       and snapshot.user_account_id = ua.id
   );

  update public.staff s
     set last_deactivated_at = now(),
         last_deactivated_by_staff_id = v_admin_staff_id,
         last_deactivation_reason = 'Administrator-only deployment'
   where exists (
     select 1
     from tams_private.administrator_only_account_snapshot snapshot
     where snapshot.batch_id = v_batch_id
       and snapshot.staff_id = s.id
   );

  update tams_private.administrator_only_batches
     set account_count = v_account_count
   where id = v_batch_id;

  if exists (
    select 1
    from public.user_accounts ua
    where ua.account_status <> 'deactivated'
      and ua.id <> v_admin_account_id
  ) then
    raise exception 'The administrator-only verification failed; no changes were committed.';
  end if;

  raise notice 'Administrator-only mode enabled. Batch: %, accounts deactivated: %.',
    v_batch_id, v_account_count;
end;
$$;

commit;

select id as batch_id, enabled_at, account_count
from tams_private.administrator_only_batches
where restored_at is null
order by enabled_at desc
limit 1;

select ua.email, ua.account_type, ua.account_status, r.role_name
from public.user_accounts ua
left join public.staff s on s.id = ua.staff_id
left join public.roles r on r.id = s.role_id
where ua.account_status <> 'deactivated'
order by ua.email;

