-- Undo the most recent unrestored administrator-only batch.
-- This restores only the statuses and staff metadata changed by the enable
-- script. Accounts that were already deactivated before that batch stay so.

begin;

do $$
declare
  v_batch_id      uuid;
  v_admin_count   integer;
  v_expected      integer;
  v_restored      integer;
begin
  lock table public.user_accounts in share row exclusive mode;

  select id into v_batch_id
  from tams_private.administrator_only_batches
  where restored_at is null
  order by enabled_at desc
  limit 1
  for update;

  if v_batch_id is null then
    raise exception 'There is no unrestored administrator-only batch.';
  end if;

  select count(*) into v_admin_count
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Administrator';

  if v_admin_count <> 1 then
    raise exception
      'Restore requires exactly one active Council Administrator; found %.',
      v_admin_count;
  end if;

  if exists (
    select 1
    from tams_private.administrator_only_account_snapshot snapshot
    left join public.user_accounts ua on ua.id = snapshot.user_account_id
    where snapshot.batch_id = v_batch_id
      and ua.id is null
  ) then
    raise exception
      'At least one snapshotted account no longer exists. Restore stopped without changing anything.';
  end if;

  select count(*) into v_expected
  from tams_private.administrator_only_account_snapshot
  where batch_id = v_batch_id;

  perform public.audit_context(
    'ADMINISTRATOR_ONLY_MODE_RESTORED',
    'Restore the previous account availability',
    v_batch_id
  );

  update public.user_accounts ua
     set account_status = snapshot.previous_account_status
    from tams_private.administrator_only_account_snapshot snapshot
   where snapshot.batch_id = v_batch_id
     and snapshot.user_account_id = ua.id;

  get diagnostics v_restored = row_count;
  if v_restored <> v_expected then
    raise exception
      'Expected to restore % account statuses but restored %. No changes were committed.',
      v_expected, v_restored;
  end if;

  update public.staff s
     set last_deactivated_at = snapshot.previous_last_deactivated_at,
         last_deactivated_by_staff_id = snapshot.previous_last_deactivated_by_staff_id,
         last_deactivation_reason = snapshot.previous_last_deactivation_reason
    from tams_private.administrator_only_account_snapshot snapshot
   where snapshot.batch_id = v_batch_id
     and snapshot.staff_id = s.id;

  update tams_private.administrator_only_batches
     set restored_at = now()
   where id = v_batch_id;

  raise notice 'Administrator-only mode restored. Batch: %, account statuses restored: %.',
    v_batch_id, v_restored;
end;
$$;

commit;

select id as batch_id, enabled_at, restored_at, account_count
from tams_private.administrator_only_batches
order by enabled_at desc
limit 1;

