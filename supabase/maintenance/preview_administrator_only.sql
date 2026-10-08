-- Preview the account change for an administrator-only deployment.
-- Read-only: this file does not change or delete anything.

select
  ua.id as account_id,
  ua.email,
  ua.account_type,
  ua.account_status as current_status,
  coalesce(r.role_name, 'Resident') as current_role,
  case
    when ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Council Administrator'
      then 'KEEP ACTIVE'
    when ua.account_status = 'deactivated'
      then 'LEAVE DEACTIVATED'
    else 'DEACTIVATE (REVERSIBLE)'
  end as planned_action
from public.user_accounts ua
left join public.staff s on s.id = ua.staff_id
left join public.roles r on r.id = s.role_id
order by
  case when r.role_name = 'Council Administrator' then 0 else 1 end,
  ua.account_type,
  ua.email;

select
  count(*) filter (
    where ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Council Administrator'
  ) as active_council_administrators,
  count(*) filter (
    where not (
      ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Council Administrator'
    )
    and ua.account_status <> 'deactivated'
  ) as accounts_to_deactivate,
  count(*) as total_accounts
from public.user_accounts ua
left join public.staff s on s.id = ua.staff_id
left join public.roles r on r.id = s.role_id;

