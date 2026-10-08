-- =====================================================================
-- TAMS — demonstration records for a new Supabase project.
--
-- Run in the Supabase SQL Editor, in this order:
--   1. npm run db:push                       (the schema)
--   2. scripts/demo/01_create_accounts.sql   (the two staff accounts)
--   3. npm run import:demo                   (residents, households, homes)
--   4. this file
--
-- It adds what the import cannot carry:
--   • land sites that are AVAILABLE — residential, farming, business and
--     burial — so a Land Officer has somewhere to allocate during the demo;
--   • the council's record — three meetings (two held, one coming up),
--     attendance, final minutes, four resolutions and two community
--     projects with milestones (one overdue), so the Council Secretary's
--     pages and the residents' Community updates have something in them.
--
-- Everything is attributed to the Council Administrator. Every name is
-- invented. It refuses to run twice.
-- =====================================================================

do $$
declare
  v_admin uuid;
  m1 uuid; m2 uuid; m3 uuid;
  r1 uuid; r2 uuid; r3 uuid; r4 uuid;
  p1 uuid; p2 uuid;
begin
  select s.id into v_admin
    from public.staff s join public.roles r on r.id = s.role_id
   where r.role_name = 'Council Administrator'
   limit 1;
  if v_admin is null then
    raise exception 'Run scripts/demo/01_create_accounts.sql first — there is no Council Administrator yet.';
  end if;

  if exists (select 1 from public.council_meetings where meeting_reference = 'MTG-2026-0001') then
    raise exception 'The demonstration records are already loaded.';
  end if;

  -- ---- Land that is free to allocate ---------------------------------
  insert into public.land_sites (site_code, site_type, stand_number, street_address, village_section, village_name, site_status)
  values
    ('RES-0101', 'residential', 'ST-2501', '4 Baobab Street',          'Mhinga Zone 2',   'Mhinga Village', 'available'),
    ('RES-0102', 'residential', 'ST-2502', '6 Baobab Street',          'Mhinga Zone 2',   'Mhinga Village', 'available'),
    ('RES-0103', 'residential', 'ST-2503', '11 Mopani Street',         'Shitlhelani',     'Mhinga Village', 'available'),
    ('RES-0104', 'residential', 'ST-2504', '15 Mopani Street',         'Shitlhelani',     'Mhinga Village', 'available'),
    ('RES-0105', 'residential', 'ST-2505', '2 Nandoni Street',         'Mhinga-Vhuyani',  'Mhinga Village', 'available'),
    ('RES-0106', 'residential', 'ST-2506', '9 Nandoni Street',         'Mhinga-Vhuyani',  'Mhinga Village', 'unavailable'),
    ('FRM-0001', 'farming',     'FM-301',  'Plot 1, Levubu River fields', 'Mhinga Zone 1', 'Mhinga Village', 'available'),
    ('FRM-0002', 'farming',     'FM-302',  'Plot 2, Levubu River fields', 'Mhinga Zone 1', 'Mhinga Village', 'available'),
    ('FRM-0003', 'farming',     'FM-303',  'Plot 3, Levubu River fields', 'Mhinga Zone 1', 'Mhinga Village', 'available'),
    ('FRM-0004', 'farming',     'FM-310',  'Grazing camp road, plot 10',  'Shitlhelani',   'Mhinga Village', 'available'),
    ('BUS-0001', 'business',    'BS-11',   'Stall 1, Mhinga Taxi Rank',   'Mhinga Central', 'Mhinga Village', 'available'),
    ('BUS-0002', 'business',    'BS-12',   'Stall 2, Mhinga Taxi Rank',   'Mhinga Central', 'Mhinga Village', 'available'),
    ('BUS-0003', 'business',    'BS-20',   '1 Hosi Mhinga Street (corner site)', 'Mhinga Central', 'Mhinga Village', 'available'),
    ('BUR-0001', 'burial',      'GY-A',    'Mhinga Community Cemetery, section A', 'Mhinga Zone 2', 'Mhinga Village', 'available'),
    ('BUR-0002', 'burial',      'GY-B',    'Mhinga Community Cemetery, section B', 'Mhinga Zone 2', 'Mhinga Village', 'available');

  -- ---- Meetings ----------------------------------------------------
  insert into public.council_meetings
    (meeting_reference, title, meeting_type, meeting_date, start_time, venue, agenda,
     meeting_status, held_recorded_at, held_recorded_by_staff_id, created_by_staff_id)
  values
    ('MTG-2026-0001', 'Ordinary council meeting — July', 'ordinary', date '2026-07-14', time '10:00',
     'Mhinga Traditional Council Office',
     E'1. Opening and apologies\n2. Water supply in Mhinga Zone 2\n3. Applications for residential sites\n4. Cemetery extension\n5. General',
     'held', timestamptz '2026-07-14 14:00+02', v_admin, v_admin)
  returning id into m1;

  insert into public.council_meetings
    (meeting_reference, title, meeting_type, meeting_date, start_time, venue, agenda,
     meeting_status, held_recorded_at, held_recorded_by_staff_id, created_by_staff_id)
  values
    ('MTG-2026-0002', 'Special meeting — community hall renovation', 'special', date '2026-09-08', time '09:30',
     'Mhinga Community Hall',
     E'1. Opening\n2. Quotations for the hall roof and toilets\n3. Youth sports field\n4. Closing',
     'held', timestamptz '2026-09-08 12:30+02', v_admin, v_admin)
  returning id into m2;

  insert into public.council_meetings
    (meeting_reference, title, meeting_type, meeting_date, start_time, venue, agenda, meeting_status, created_by_staff_id)
  values
    ('MTG-2026-0003', 'Ordinary council meeting — October', 'ordinary', date '2026-10-20', time '10:00',
     'Mhinga Traditional Council Office',
     E'1. Opening and apologies\n2. Progress on the community hall\n3. Farming plots along the Levubu\n4. General',
     'scheduled', v_admin)
  returning id into m3;

  insert into public.meeting_attendance (meeting_id, attendee_name, role_or_capacity, attendance_status, recorded_by_staff_id)
  values
    (m1, 'Hosi Mhinga',          'Chief',                 'present', v_admin),
    (m1, 'Samuel Maluleke',      'Headman, Zone 1',       'present', v_admin),
    (m1, 'Tintswalo Baloyi',     'Headwoman, Zone 2',     'present', v_admin),
    (m1, 'Elias Chauke',         'Council member',        'apology', v_admin),
    (m1, 'Ntsakisi Mathebula',   'Council member',        'present', v_admin),
    (m2, 'Hosi Mhinga',          'Chief',                 'present', v_admin),
    (m2, 'Samuel Maluleke',      'Headman, Zone 1',       'present', v_admin),
    (m2, 'Tintswalo Baloyi',     'Headwoman, Zone 2',     'absent',  v_admin),
    (m2, 'Ward 31 Councillor',   'Municipal councillor',  'present', v_admin);

  insert into public.meeting_minutes (meeting_id, minutes_content, minutes_status, finalized_at, finalized_by_staff_id, created_by_staff_id)
  values
    (m1, E'The meeting opened at 10:00 with a prayer.\n\nWater: residents of Zone 2 reported three weeks without water. The council resolved to write to Collins Chabane Local Municipality.\n\nResidential sites: five new sites in Zone 2 and Shitlhelani were confirmed as available for allocation.\n\nCemetery: section B of the community cemetery is to be fenced and opened.\n\nThe meeting closed at 13:40.',
     'final', timestamptz '2026-07-21 09:00+02', v_admin, v_admin),
    (m2, E'Three quotations for the hall roof and toilets were tabled. The council chose the second quotation.\n\nThe youth asked for the sports field to be levelled before the December tournament.\n\nThe meeting closed at 12:15.',
     'final', timestamptz '2026-09-15 09:00+02', v_admin, v_admin);

  -- ---- Resolutions --------------------------------------------------
  insert into public.council_resolutions (resolution_reference, meeting_id, resolution_text, decision_date, resolution_status, visibility, created_by_staff_id)
  values ('RES-2026-0001', m1, 'The council will write to Collins Chabane Local Municipality about the water outages in Mhinga Zone 2 and ask for a repair date.', date '2026-07-14', 'active', 'public', v_admin)
  returning id into r1;
  insert into public.council_resolutions (resolution_reference, meeting_id, resolution_text, decision_date, resolution_status, visibility, created_by_staff_id)
  values ('RES-2026-0002', m1, 'Section B of the Mhinga Community Cemetery is to be fenced and opened for burials.', date '2026-07-14', 'active', 'public', v_admin)
  returning id into r2;
  insert into public.council_resolutions (resolution_reference, meeting_id, resolution_text, decision_date, resolution_status, visibility, created_by_staff_id)
  values ('RES-2026-0003', m2, 'The community hall roof and toilets will be renovated using the second quotation tabled.', date '2026-09-08', 'active', 'public', v_admin)
  returning id into r3;
  insert into public.council_resolutions (resolution_reference, meeting_id, resolution_text, decision_date, resolution_status, visibility, created_by_staff_id)
  values ('RES-2026-0004', m2, 'The council will negotiate the hall contractor''s payment schedule in private.', date '2026-09-08', 'active', 'internal', v_admin)
  returning id into r4;

  -- ---- Projects and milestones -------------------------------------
  insert into public.community_projects (project_reference, project_name, description, resolution_id, start_date, target_completion_date, project_status, visibility, created_by_staff_id)
  values ('PRJ-2026-0001', 'Community hall renovation', 'New roof sheeting and two new toilets for the Mhinga Community Hall.', r3, date '2026-09-15', date '2027-01-31', 'active', 'public', v_admin)
  returning id into p1;
  insert into public.community_projects (project_reference, project_name, description, resolution_id, start_date, target_completion_date, project_status, visibility, created_by_staff_id)
  values ('PRJ-2026-0002', 'Cemetery section B fencing', 'Fence and gate for section B of the community cemetery so it can be opened for burials.', r2, date '2026-08-01', date '2026-11-30', 'active', 'public', v_admin)
  returning id into p2;

  insert into public.project_milestones (project_id, title, description, due_date, milestone_status, completed_at, completed_by_staff_id, created_by_staff_id)
  values
    (p1, 'Contractor appointed',      'Sign the contract with the chosen contractor.',   date '2026-09-30', 'completed',   timestamptz '2026-09-26 11:00+02', v_admin, v_admin),
    (p1, 'Roof sheeting replaced',    null,                                              date '2026-11-15', 'in_progress', null, null, v_admin),
    (p1, 'Toilets built and handed over', null,                                          date '2027-01-31', 'pending',     null, null, v_admin),
    (p2, 'Fencing material delivered', 'Poles, wire and a gate delivered to site.',      date '2026-09-01', 'completed',   timestamptz '2026-08-29 15:00+02', v_admin, v_admin),
    (p2, 'Fence erected',              null,                                             date '2026-10-01', 'in_progress', null, null, v_admin),
    (p2, 'Section B opened',           null,                                             date '2026-11-30', 'pending',     null, null, v_admin);

  raise notice 'Demonstration records loaded: 15 land sites, 3 meetings, 4 resolutions, 2 projects.';
end;
$$;
