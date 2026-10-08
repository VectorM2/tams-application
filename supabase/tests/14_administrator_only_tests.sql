-- Administrator-only maintenance scripts: reversible account lockdown.

create table tams_test.administrator_only_status_before as
select id, account_status from public.user_accounts;

create table tams_test.administrator_only_counts_before as
select
  (select count(*) from auth.users) as auth_users,
  (select count(*) from public.user_accounts) as user_accounts,
  (select count(*) from public.staff) as staff,
  (select count(*) from public.residents) as residents;

\ir ../maintenance/enable_administrator_only.sql

select tams_test.check(
  'ADMIN ONLY 1 — exactly one account remains available',
  (select count(*) = 1 from public.user_accounts where account_status <> 'deactivated')
);

select tams_test.check(
  'ADMIN ONLY 2 — the available account is the active Council Administrator',
  (select count(*) = 1
     from public.user_accounts ua
     join public.staff s on s.id = ua.staff_id
     join public.roles r on r.id = s.role_id
    where ua.account_status = 'active'
      and ua.account_type = 'staff'
      and r.role_name = 'Council Administrator')
);

select tams_test.check(
  'ADMIN ONLY 3 — no identities, accounts, staff or residents were deleted',
  (select jsonb_build_array(
      (select count(*) from auth.users),
      (select count(*) from public.user_accounts),
      (select count(*) from public.staff),
      (select count(*) from public.residents)
    ) = jsonb_build_array(auth_users, user_accounts, staff, residents)
   from tams_test.administrator_only_counts_before)
);

select tams_test.check(
  'ADMIN ONLY 4 — every changed account has a private status snapshot',
  (select count(*)
     from tams_private.administrator_only_account_snapshot snapshot
     join tams_private.administrator_only_batches batch on batch.id = snapshot.batch_id
    where batch.restored_at is null)
  =
  (select count(*)
     from tams_test.administrator_only_status_before before_status
     join public.user_accounts ua on ua.id = before_status.id
     left join public.staff s on s.id = ua.staff_id
     left join public.roles r on r.id = s.role_id
    where before_status.account_status <> 'deactivated'
      and not (ua.account_type = 'staff' and r.role_name = 'Council Administrator'))
);

select tams_test.check(
  'ADMIN ONLY 5 — the account changes share one auditable event group',
  (select count(distinct event_group_id) = 1
     from public.audit_logs
    where action = 'ADMINISTRATOR_ONLY_MODE_ENABLED'
      and entity_type = 'user_account')
);

\ir ../maintenance/restore_administrator_only.sql

select tams_test.check(
  'ADMIN ONLY 6 — restore puts every account status back exactly',
  not exists (
    select 1
    from tams_test.administrator_only_status_before before_status
    join public.user_accounts ua on ua.id = before_status.id
    where ua.account_status is distinct from before_status.account_status
  )
);

select tams_test.check(
  'ADMIN ONLY 7 — the batch is marked restored',
  (select count(*) = 1
     from tams_private.administrator_only_batches
    where restored_at is not null)
);

