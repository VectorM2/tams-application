-- =====================================================================
-- TAMS — the two starting accounts for a new Supabase project.
--
-- Run in the Supabase SQL Editor AFTER `npm run db:push`.
--
-- BEFORE running this, create both sign-ins yourself:
--   Supabase Dashboard → Authentication → Users → Add user → Create new user
--     • Email: vectormediax@gmail.com       Password: (your choice)
--     • Email: mathabelavector@gmail.com    Password: (your choice)
--     • Tick "Auto Confirm User" for both.
--
-- This script then turns those sign-ins into TAMS staff:
--   vectormediax@gmail.com     → Council Administrator
--   mathabelavector@gmail.com  → Registry Clerk
--
-- It uses the same database functions the bootstrap and the "Create
-- staff account" page use, so every rule (one administrator only,
-- unique employee numbers, valid contact numbers) still applies.
-- Running it twice is harmless: anyone already set up is skipped.
--
-- ► Edit the names, employee numbers and phone numbers below first.
-- =====================================================================

do $$
declare
  -- ---- EDIT THESE ---------------------------------------------------
  admin_email      text := 'vectormediax@gmail.com';
  admin_employee   text := 'TA-0001';
  admin_first_name text := 'Council';
  admin_last_name  text := 'Administrator';
  admin_phone      text := '0712345678';

  clerk_email      text := 'mathabelavector@gmail.com';
  clerk_employee   text := 'TA-0002';
  clerk_first_name text := 'Registry';
  clerk_last_name  text := 'Clerk';
  clerk_phone      text := '0723456789';
  -- -------------------------------------------------------------------

  v_auth_id uuid;
  v_result  jsonb;
begin
  -- ---- Council Administrator ---------------------------------------
  select id into v_auth_id from auth.users where lower(email) = lower(admin_email);
  if v_auth_id is null then
    raise exception 'No sign-in exists for %. Create it under Authentication → Users first.', admin_email;
  end if;

  if exists (select 1 from public.user_accounts where auth_user_id = v_auth_id) then
    raise notice '% is already set up — skipped.', admin_email;
  else
    v_result := public.bootstrap_council_administrator(
      v_auth_id, admin_employee, admin_first_name, admin_last_name, lower(admin_email), admin_phone);
    raise notice 'Council Administrator created: %', v_result;
  end if;

  -- ---- Registry Clerk ----------------------------------------------
  select id into v_auth_id from auth.users where lower(email) = lower(clerk_email);
  if v_auth_id is null then
    raise exception 'No sign-in exists for %. Create it under Authentication → Users first.', clerk_email;
  end if;

  if exists (select 1 from public.user_accounts where auth_user_id = v_auth_id) then
    raise notice '% is already set up — skipped.', clerk_email;
  else
    v_result := public.create_staff_with_account(
      v_auth_id, clerk_employee, clerk_first_name, clerk_last_name, lower(clerk_email), clerk_phone,
      (select id from public.roles where role_name = 'Registry Clerk'));
    raise notice 'Registry Clerk created: %', v_result;
  end if;
end;
$$;

-- What you should now see: two active staff accounts.
select s.employee_number, s.first_name, s.last_name, s.email, r.role_name, ua.account_status
  from public.staff s
  join public.roles r on r.id = s.role_id
  join public.user_accounts ua on ua.staff_id = s.id
 order by s.employee_number;
