-- =====================================================================
-- TAMS database schema — part 3 of 3
-- Generated from supabase/migrations (do not edit by hand).
-- Paste into the Supabase SQL Editor and run. Run the three parts in
-- order: 00a, 00b, 00c — then 01_create_accounts.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 20260930090000_audit_trail.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — the immutable audit trail
--
-- Who changed what, when, from what, to what, and why.
--
-- The design is deliberately not "every function remembers to write a
-- log line". A function can be changed, or written next year by somebody
-- who forgets. Instead the audit is written by triggers on the tables
-- themselves, so it happens however the row came to be written; a
-- business action may add its own name and reason through a
-- transaction-local context, and nothing else can.
--
-- The actor is read from auth.uid() inside a security definer trigger.
-- No client can supply it, and there is no function anywhere that takes
-- an actor or an action as a parameter from a browser.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The log
-- ---------------------------------------------------------------------

create table if not exists public.audit_logs (
  id                 uuid primary key default gen_random_uuid(),
  actor_user_id      uuid,          -- auth.users.id, or null for the system
  actor_staff_id     uuid references public.staff (id),
  actor_role         text,          -- the role they held at the moment of the action
  actor_account_type text,
  actor_label        text,          -- a readable name, kept even if records change later

  action             text not null,
  entity_type        text not null,
  entity_id          uuid,
  entity_reference   text,

  old_values         jsonb,
  new_values         jsonb,
  changed_fields     text[],
  reason             text,

  -- Several rows written by one business action share this.
  event_group_id     uuid,
  created_at         timestamptz not null default now(),

  constraint audit_logs_action_not_blank      check (btrim(action) <> ''),
  constraint audit_logs_entity_type_not_blank check (btrim(entity_type) <> '')
);

create index if not exists audit_logs_created_idx  on public.audit_logs (created_at desc);
create index if not exists audit_logs_entity_idx   on public.audit_logs (entity_type, entity_id);
create index if not exists audit_logs_actor_idx    on public.audit_logs (actor_staff_id);
create index if not exists audit_logs_action_idx   on public.audit_logs (action);
create index if not exists audit_logs_group_idx    on public.audit_logs (event_group_id);

-- ---------------------------------------------------------------------
-- 2. Immutability
--
--    Insert only. Not "we try not to update it" — an update or a delete
--    raises, whoever attempts it, so the application cannot rewrite its
--    own history even by mistake. (A database owner can drop a trigger;
--    that is outside the application, and outside what this can
--    promise.)
-- ---------------------------------------------------------------------

create or replace function public.tg_audit_logs_are_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'The audit trail is insert-only. An audit record cannot be % .', lower(tg_op)
    using errcode = 'TA120';
end;
$$;

drop trigger if exists audit_logs_immutable on public.audit_logs;
create trigger audit_logs_immutable
  before update or delete or truncate on public.audit_logs
  for each statement execute function public.tg_audit_logs_are_immutable();

-- ---------------------------------------------------------------------
-- 3. Who is acting
-- ---------------------------------------------------------------------

create or replace function public.audit_actor()
returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$
  select coalesce(
    (select jsonb_build_object(
              'actor_user_id',      ua.auth_user_id,
              'actor_staff_id',     ua.staff_id,
              'actor_account_type', ua.account_type,
              'actor_role',         coalesce(r.role_name, ua.account_type),
              'actor_label',        coalesce(s.first_name || ' ' || s.last_name,
                                             res.first_name || ' ' || res.last_name,
                                             ua.email))
     from public.user_accounts ua
     left join public.staff s on s.id = ua.staff_id
     left join public.roles r on r.id = s.role_id
     left join public.residents res on res.id = ua.resident_id
     where ua.auth_user_id = auth.uid()),
    -- Nobody signed in: a scheduled worker, a migration, or the
    -- recovery process. Recorded as the system, never as a person.
    jsonb_build_object(
      'actor_user_id', null, 'actor_staff_id', null,
      'actor_account_type', 'system', 'actor_role', 'system', 'actor_label', 'TAMS')
  );
$$;

-- ---------------------------------------------------------------------
-- 4. The context a business action may add
--
--    Transaction-local, so it cannot leak between requests on a pooled
--    connection. A function sets the action it is performing and the
--    reason it was given; the triggers below pick them up.
-- ---------------------------------------------------------------------

create or replace function public.audit_context(
  p_action text default null,
  p_reason text default null,
  p_group  uuid default null
)
returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_group uuid := coalesce(p_group, gen_random_uuid());
begin
  perform set_config('tams.audit_action', coalesce(p_action, ''), true);
  perform set_config('tams.audit_reason', coalesce(p_reason, ''), true);
  perform set_config('tams.audit_group',  v_group::text, true);
  return v_group;
end;
$$;

create or replace function public.audit_context_value(p_key text)
returns text
language sql stable
as $$
  select nullif(btrim(coalesce(current_setting(p_key, true), '')), '');
$$;

-- ---------------------------------------------------------------------
-- 5. What never goes into the log
--
--    Secrets are not audited merely because the row they live on is.
--    Anything that could be replayed — a password, a token, a key — and
--    anything that is the content of somebody's private document is
--    dropped before the values are written.
-- ---------------------------------------------------------------------

create or replace function public.audit_strip(p_values jsonb, p_extra text[] default '{}')
returns jsonb
language sql immutable
as $$
  select coalesce(
    (select jsonb_object_agg(k, v)
     from jsonb_each(coalesce(p_values, '{}'::jsonb)) as e(k, v)
     where not (k = any (p_extra))
       and k not in ('updated_at', 'created_at')
       and k !~* '(password|secret|token|api_key|service_role|private_key|credential)'
       and k !~* '(storage_path|file_path|document_content|file_bytes|raw_document)'),
    '{}'::jsonb);
$$;

-- ---------------------------------------------------------------------
-- 6. The audit trigger
--
--    Arguments, in order:
--      0  entity type            e.g. 'pto'
--      1  reference column       e.g. 'pto_number'    (or '' for none)
--      2  status column          e.g. 'pto_status'    (or '' for none)
--      3  extra excluded columns comma separated      (or '')
--
--    The action is the business action the function announced, if it
--    announced one. Otherwise it is worked out: an insert is a CREATE,
--    and an update that moved the status column is named after where it
--    moved to — PTO_REVOKED, MEETING_CANCELLED, PROJECT_COMPLETED —
--    which is the vocabulary an administrator reading this actually
--    wants.
-- ---------------------------------------------------------------------

create or replace function public.tg_audit()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_entity   text := tg_argv[0];
  v_ref_col  text := nullif(tg_argv[1], '');
  v_stat_col text := nullif(tg_argv[2], '');
  v_extra    text[] := case when coalesce(tg_argv[3], '') = '' then '{}'::text[]
                            else string_to_array(tg_argv[3], ',') end;

  v_old      jsonb := case when tg_op = 'INSERT' then null else public.audit_strip(to_jsonb(old), v_extra) end;
  v_new      jsonb := case when tg_op = 'DELETE' then null else public.audit_strip(to_jsonb(new), v_extra) end;
  v_changed  text[] := '{}';
  v_old_out  jsonb;
  v_new_out  jsonb;
  v_action   text := public.audit_context_value('tams.audit_action');
  v_reason   text := public.audit_context_value('tams.audit_reason');
  v_group    uuid := nullif(public.audit_context_value('tams.audit_group'), '')::uuid;
  v_actor    jsonb := public.audit_actor();
  v_ref      text;
  v_id       uuid;
  v_status   text;
  v_key      text;
begin
  -- ---- what changed -------------------------------------------------
  if tg_op = 'UPDATE' then
    select coalesce(array_agg(k order by k), '{}')
      into v_changed
      from jsonb_object_keys(v_new) as k
     where v_new -> k is distinct from v_old -> k;

    -- Nothing worth recording: a touch of updated_at and no more.
    if array_length(v_changed, 1) is null then return null; end if;

    -- Only the fields that actually moved, on both sides.
    v_old_out := '{}'::jsonb;
    v_new_out := '{}'::jsonb;
    foreach v_key in array v_changed loop
      v_old_out := v_old_out || jsonb_build_object(v_key, v_old -> v_key);
      v_new_out := v_new_out || jsonb_build_object(v_key, v_new -> v_key);
    end loop;
  elsif tg_op = 'INSERT' then
    v_old_out := null;
    v_new_out := v_new;
    select coalesce(array_agg(k order by k), '{}') into v_changed from jsonb_object_keys(v_new) as k;
  else
    v_old_out := v_old;
    v_new_out := null;
  end if;

  -- ---- readable names in place of internal ids ----------------------
  if v_entity = 'staff' and (v_changed @> array['role_id'] or tg_op = 'INSERT') then
    v_old_out := (v_old_out - 'role_id')
      || case when v_old_out is null then '{}'::jsonb
              else jsonb_build_object('role',
                   (select role_name from public.roles where id = (v_old ->> 'role_id')::uuid)) end;
    v_new_out := (v_new_out - 'role_id')
      || jsonb_build_object('role',
           (select role_name from public.roles where id = (v_new ->> 'role_id')::uuid));
    v_changed := array_replace(v_changed, 'role_id', 'role');
  end if;

  if v_entity = 'household' and v_changed @> array['head_resident_id'] then
    v_old_out := (v_old_out - 'head_resident_id') || jsonb_build_object('head',
      coalesce((select r.first_name || ' ' || r.last_name || ' (' || r.id_number || ')'
                from public.residents r where r.id = (v_old ->> 'head_resident_id')::uuid), 'none'));
    v_new_out := (v_new_out - 'head_resident_id') || jsonb_build_object('head',
      coalesce((select r.first_name || ' ' || r.last_name || ' (' || r.id_number || ')'
                from public.residents r where r.id = (v_new ->> 'head_resident_id')::uuid), 'none'));
    v_changed := array_replace(v_changed, 'head_resident_id', 'head');
  end if;

  -- ---- identity of the thing ----------------------------------------
  v_id := coalesce((v_new ->> 'id')::uuid, (v_old ->> 'id')::uuid);
  if v_ref_col is not null then
    v_ref := coalesce(v_new ->> v_ref_col, v_old ->> v_ref_col);
  end if;

  -- ---- the name of the action ---------------------------------------
  if v_action is null then
    if tg_op = 'INSERT' then
      v_action := 'CREATE_' || upper(v_entity);
    elsif tg_op = 'DELETE' then
      v_action := 'DELETE_' || upper(v_entity);
    else
      v_status := case when v_stat_col is null then null
                       when (v_new ->> v_stat_col) is distinct from (v_old ->> v_stat_col)
                       then v_new ->> v_stat_col end;
      v_action := case when v_status is null then 'UPDATE_' || upper(v_entity)
                       else upper(v_entity) || '_' || upper(v_status) end;
    end if;
  end if;

  -- ---- why, when the row itself says why -----------------------------
  if v_reason is null and v_new_out is not null then
    select v_new_out ->> k into v_reason
      from jsonb_object_keys(v_new_out) as k
     where k ~ '_reason$' and nullif(btrim(coalesce(v_new_out ->> k, '')), '') is not null
     limit 1;
  end if;

  insert into public.audit_logs (
    actor_user_id, actor_staff_id, actor_role, actor_account_type, actor_label,
    action, entity_type, entity_id, entity_reference,
    old_values, new_values, changed_fields, reason, event_group_id)
  values (
    nullif(v_actor ->> 'actor_user_id', '')::uuid,
    nullif(v_actor ->> 'actor_staff_id', '')::uuid,
    v_actor ->> 'actor_role',
    v_actor ->> 'actor_account_type',
    v_actor ->> 'actor_label',
    v_action, v_entity, v_id, v_ref,
    v_old_out, v_new_out, v_changed, v_reason, v_group);

  return null;
end;
$$;

-- An event with no row behind it: a document being looked at, an
-- administrator being transferred, the recovery process running.
create or replace function public.audit_event(
  p_action     text,
  p_entity     text,
  p_entity_id  uuid default null,
  p_reference  text default null,
  p_old        jsonb default null,
  p_new        jsonb default null,
  p_reason     text default null
)
returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_actor jsonb := public.audit_actor();
  v_group uuid := nullif(public.audit_context_value('tams.audit_group'), '')::uuid;
  v_old   jsonb := public.audit_strip(p_old);
  v_new   jsonb := public.audit_strip(p_new);
  v_id    uuid;
begin
  insert into public.audit_logs (
    actor_user_id, actor_staff_id, actor_role, actor_account_type, actor_label,
    action, entity_type, entity_id, entity_reference,
    old_values, new_values, changed_fields, reason, event_group_id)
  values (
    nullif(v_actor ->> 'actor_user_id', '')::uuid,
    nullif(v_actor ->> 'actor_staff_id', '')::uuid,
    v_actor ->> 'actor_role', v_actor ->> 'actor_account_type', v_actor ->> 'actor_label',
    p_action, p_entity, p_entity_id, p_reference,
    case when p_old is null then null else v_old end,
    case when p_new is null then null else v_new end,
    case when p_new is null then null
         else (select coalesce(array_agg(k order by k), '{}') from jsonb_object_keys(v_new) as k) end,
    nullif(btrim(coalesce(p_reason, '')), ''),
    v_group)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Where the triggers go
--
--    Everything official. Notifications themselves are deliberately not
--    audited — they are an effect of the actions below, and auditing
--    them would only fill the trail with copies of people's messages.
-- ---------------------------------------------------------------------

do $$
declare
  v_spec record;
begin
  for v_spec in
    select * from (values
      -- table,                       entity,                 reference,             status,               extra excluded
      ('staff',                       'staff',                'employee_number',     '',                   ''),
      ('user_accounts',               'user_account',         'email',               'account_status',     ''),
      ('residents',                   'resident',             'id_number',           'resident_status',    ''),
      ('households',                  'household',            'household_code',      'household_status',   ''),
      ('family_relationships',        'family_relationship',  '',                    'relationship_status',''),
      ('resident_account_requests',   'resident_account_request', 'id_number',       'request_status',     ''),
      ('resident_request_documents',  'verification_document','document_type',       '',                   'file_name'),
      ('land_sites',                  'land_site',            'site_code',           'site_status',        ''),
      ('land_applications',           'land_application',     'application_reference','application_status', ''),
      ('land_allocations',            'land_allocation',      'allocation_reference','allocation_status',   ''),
      ('ptos',                        'pto',                  'pto_number',          'pto_status',          'verification_token'),
      ('pto_renewal_requests',        'pto_renewal_request',  '',                    'request_status',      ''),
      ('council_meetings',            'meeting',              'meeting_reference',   'meeting_status',      ''),
      ('meeting_attendance',          'meeting_attendance',   'attendee_name',       'attendance_status',   ''),
      ('meeting_minutes',             'meeting_minutes',      '',                    'minutes_status',      'minutes_content'),
      ('meeting_minutes_amendments',  'minutes_amendment',    'amendment_reference', '',                    'amendment_text'),
      ('council_resolutions',         'resolution',           'resolution_reference','resolution_status',   ''),
      ('community_projects',          'project',              'project_reference',   'project_status',      ''),
      ('project_milestones',          'project_milestone',    'title',               'milestone_status',    ''),
      ('visibility_changes',          'visibility_change',    '',                    '',                    '')
    ) as t(table_name, entity, reference, status, extra)
  loop
    execute format('drop trigger if exists audit_%1$s on public.%1$I', v_spec.table_name);
    execute format(
      'create trigger audit_%1$s after insert or update or delete on public.%1$I ' ||
      'for each row execute function public.tg_audit(%2$L, %3$L, %4$L, %5$L)',
      v_spec.table_name, v_spec.entity, v_spec.reference, v_spec.status, v_spec.extra);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Looking at a verification document
--
--    The documents live in a private storage bucket and the browser
--    fetches them with a short-lived signed link. Asking for that link
--    now goes through here, so that the asking is on the record. Only
--    the metadata is: never a byte of the document itself.
-- ---------------------------------------------------------------------

create or replace function public.registry_open_verification_document(
  p_request_id    uuid,
  p_document_type text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_registry_clerk_staff_id();
  v_document public.resident_request_documents;
  v_request  public.resident_account_requests;
begin
  select * into v_request from public.resident_account_requests where id = p_request_id;
  if not found then
    raise exception 'That verification request could not be found.' using errcode = 'TA050';
  end if;

  select * into v_document from public.resident_request_documents
   where request_id = p_request_id and document_type = p_document_type;
  if not found then
    raise exception 'That document was not submitted with this request.' using errcode = 'TA050';
  end if;

  perform public.audit_event(
    'VIEWED_VERIFICATION_DOCUMENT', 'verification_document', v_document.id,
    v_document.document_type, null,
    jsonb_build_object(
      'document_type',    v_document.document_type,
      'request_id_number', v_request.id_number,
      'applicant',        v_request.first_name || ' ' || v_request.last_name),
    null);

  return jsonb_build_object(
    'storage_path', v_document.storage_path,
    'document_type', v_document.document_type,
    'file_name', v_document.file_name);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Reading the trail
--
--    The Council Administrator, and nobody else. A Registry Clerk, a
--    Land Officer, a Council Secretary and a resident each get nothing.
-- ---------------------------------------------------------------------

create or replace function public.admin_audit_logs(
  p_from        date default null,
  p_to          date default null,
  p_actor       text default null,   -- name, employee number or email
  p_actor_role  text default null,
  p_action      text default null,
  p_entity_type text default null,
  p_reference   text default null,
  p_limit       int  default 200
)
returns table (
  audit_id uuid, created_at timestamptz, actor_label text, actor_role text,
  action text, entity_type text, entity_id uuid, entity_reference text,
  changed_fields text[], reason text, event_group_id uuid
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the active Council Administrator may read the audit trail.'
      using errcode = '42501';
  end if;
  return query
    select a.id, a.created_at, a.actor_label, a.actor_role, a.action, a.entity_type,
           a.entity_id, a.entity_reference, a.changed_fields, a.reason, a.event_group_id
    from public.audit_logs a
    left join public.staff s on s.id = a.actor_staff_id
    where (p_from is null or a.created_at >= p_from::timestamptz)
      and (p_to is null or a.created_at < (p_to + 1)::timestamptz)
      and (p_actor_role is null or a.actor_role = p_actor_role)
      and (p_action is null or a.action = p_action)
      and (p_entity_type is null or a.entity_type = p_entity_type)
      and (coalesce(btrim(p_reference), '') = ''
           or a.entity_reference ilike public.like_pattern(p_reference))
      and (coalesce(btrim(p_actor), '') = ''
           or a.actor_label ilike public.like_pattern(p_actor)
           or coalesce(s.employee_number, '') ilike public.like_pattern(p_actor)
           or coalesce(s.email, '') ilike public.like_pattern(p_actor))
    order by a.created_at desc
    limit least(greatest(coalesce(p_limit, 200), 1), 2000);
end;
$$;

create or replace function public.admin_audit_log(p_audit_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the active Council Administrator may read the audit trail.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'audit_id', a.id, 'created_at', a.created_at,
    'actor_label', a.actor_label, 'actor_role', a.actor_role,
    'actor_account_type', a.actor_account_type,
    'actor_employee_number', s.employee_number,
    'action', a.action, 'entity_type', a.entity_type,
    'entity_id', a.entity_id, 'entity_reference', a.entity_reference,
    'old_values', a.old_values, 'new_values', a.new_values,
    'changed_fields', a.changed_fields, 'reason', a.reason,
    'event_group_id', a.event_group_id,
    -- The other rows written by the same business action.
    'related', coalesce((
      select jsonb_agg(jsonb_build_object(
               'audit_id', b.id, 'action', b.action, 'entity_type', b.entity_type,
               'entity_reference', b.entity_reference) order by b.created_at)
      from public.audit_logs b
      where a.event_group_id is not null
        and b.event_group_id = a.event_group_id and b.id <> a.id), '[]'::jsonb)
  ) into v_result
  from public.audit_logs a
  left join public.staff s on s.id = a.actor_staff_id
  where a.id = p_audit_id;

  if v_result is null then
    raise exception 'That audit record could not be found.' using errcode = 'TA121';
  end if;
  return v_result;
end;
$$;

-- The distinct values behind the filters, so the viewer offers what
-- actually exists rather than a guess.
create or replace function public.admin_audit_filters()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the active Council Administrator may read the audit trail.'
      using errcode = '42501';
  end if;
  return jsonb_build_object(
    'actions',      coalesce((select jsonb_agg(distinct action order by action) from public.audit_logs), '[]'::jsonb),
    'entity_types', coalesce((select jsonb_agg(distinct entity_type order by entity_type) from public.audit_logs), '[]'::jsonb),
    'actor_roles',  coalesce((select jsonb_agg(distinct actor_role order by actor_role)
                              from public.audit_logs where actor_role is not null), '[]'::jsonb),
    'total',        (select count(*) from public.audit_logs));
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Row Level Security
-- ---------------------------------------------------------------------

alter table public.audit_logs enable row level security;
revoke all on public.audit_logs from anon, authenticated;
grant select on public.audit_logs to authenticated;
grant select, insert on public.audit_logs to service_role;

drop policy if exists audit_logs_administrator_reads on public.audit_logs;
create policy audit_logs_administrator_reads
  on public.audit_logs for select to authenticated
  using (public.is_active_council_administrator());

-- ---------------------------------------------------------------------
-- 11. Grants
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.audit_actor()',
    'public.audit_context(text, text, uuid)',
    'public.audit_strip(jsonb, text[])',
    'public.audit_event(text, text, uuid, text, jsonb, jsonb, text)',
    'public.tg_audit()',
    'public.audit_context_value(text)',
    'public.tg_audit_logs_are_immutable()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
  end loop;
end;
$$;

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.admin_audit_logs(date, date, text, text, text, text, text, int)',
    'public.admin_audit_log(uuid)',
    'public.admin_audit_filters()',
    'public.registry_open_verification_document(uuid, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;


-- ---------------------------------------------------------------------
-- 20261001090000_communications.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — official communications and internal staff messaging
--
-- Two separate things that happen to share a delivery mechanism:
--
--   * the Council Secretary writing to residents, officially, on behalf
--     of the Chief or the Traditional Council;
--   * staff writing to each other to get work done across roles that
--     are deliberately kept apart.
--
-- Neither is a chat. Both are records: once sent, the words stand, and
-- a correction is a new message rather than an edit to an old one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Official communications to residents
-- ---------------------------------------------------------------------

create table if not exists public.resident_communications (
  id                      uuid primary key default gen_random_uuid(),
  communication_reference text not null unique,
  sent_by_staff_id        uuid not null references public.staff (id),
  communication_type      text not null,
  audience_type           text not null,
  subject                 text not null,
  message                 text not null,
  -- Descriptive only. The Chief, a Headman and a Headwoman have no
  -- accounts in TAMS and are not being authenticated here.
  issued_on_behalf_of     text,
  event_date              date,
  event_time              time,
  venue                   text,
  related_entity_type     text,
  related_entity_id       uuid,
  related_reference       text,
  recipient_count         int not null default 0,
  created_at              timestamptz not null default now(),

  constraint resident_communications_type_allowed check (communication_type in (
    'community_announcement', 'individual_notice', 'summons', 'general_notice')),
  constraint resident_communications_audience_allowed check (audience_type in (
    'all_active_residents', 'one_resident', 'selected_residents')),
  constraint resident_communications_subject_not_blank check (btrim(subject) <> ''),
  constraint resident_communications_message_not_blank check (btrim(message) <> ''),
  constraint resident_communications_related_allowed check (
    related_entity_type is null
    or related_entity_type in ('meeting', 'resolution', 'project'))
);

-- Who it actually went to, frozen at the moment it was sent. Somebody
-- verified next month is not retrospectively a recipient of last
-- month's notice.
create table if not exists public.resident_communication_recipients (
  id               uuid primary key default gen_random_uuid(),
  communication_id uuid not null references public.resident_communications (id),
  resident_id      uuid not null references public.residents (id),
  user_account_id  uuid not null references public.user_accounts (id),
  notification_id  uuid references public.notifications (id),
  created_at       timestamptz not null default now(),
  constraint resident_communication_recipient_once unique (communication_id, user_account_id)
);

create index if not exists resident_communication_recipients_account_idx
  on public.resident_communication_recipients (user_account_id);

-- ---------------------------------------------------------------------
-- 2. Internal staff messages
-- ---------------------------------------------------------------------

create table if not exists public.staff_messages (
  id                  uuid primary key default gen_random_uuid(),
  message_reference   text not null unique,
  sender_staff_id     uuid not null references public.staff (id),
  subject             text not null,
  body                text not null,
  message_kind        text not null default 'normal',
  target_type         text not null,
  target_staff_id     uuid references public.staff (id),
  target_role_id      uuid references public.roles (id),

  related_entity_type text,
  related_entity_id   uuid,
  related_reference   text,

  -- Set only on an action_required message.
  action_status           text,
  acknowledged_by_staff_id uuid references public.staff (id),
  acknowledged_at         timestamptz,
  resolved_by_staff_id    uuid references public.staff (id),
  resolved_at             timestamptz,

  created_at          timestamptz not null default now(),

  constraint staff_messages_subject_not_blank check (btrim(subject) <> ''),
  constraint staff_messages_body_not_blank    check (btrim(body) <> ''),
  constraint staff_messages_kind_allowed
    check (message_kind in ('normal', 'action_required', 'announcement')),
  constraint staff_messages_target_allowed
    check (target_type in ('direct', 'role', 'all_staff')),
  constraint staff_messages_target_shape check (
    (target_type = 'direct' and target_staff_id is not null and target_role_id is null)
    or (target_type = 'role' and target_role_id is not null and target_staff_id is null)
    or (target_type = 'all_staff' and target_staff_id is null and target_role_id is null)
  ),
  constraint staff_messages_related_allowed check (
    related_entity_type is null or related_entity_type in (
      'resident', 'household', 'resident_account_request', 'land_application',
      'land_allocation', 'pto', 'meeting', 'resolution', 'project')),
  -- A work request has a lifecycle; an ordinary message has none.
  constraint staff_messages_action_shape check (
    (message_kind = 'action_required' and action_status in ('open', 'acknowledged', 'resolved'))
    or (message_kind <> 'action_required' and action_status is null)
  ),
  constraint staff_messages_acknowledged_shape check (
    action_status is null or action_status = 'open'
    or (acknowledged_by_staff_id is not null and acknowledged_at is not null)
  ),
  constraint staff_messages_resolved_shape check (
    action_status is distinct from 'resolved'
    or (resolved_by_staff_id is not null and resolved_at is not null)
  )
);

create index if not exists staff_messages_sender_idx on public.staff_messages (sender_staff_id, created_at desc);

-- The recipients as they were when the message was sent. A role change
-- tomorrow does not rewrite who was written to today.
create table if not exists public.staff_message_recipients (
  id                uuid primary key default gen_random_uuid(),
  message_id        uuid not null references public.staff_messages (id),
  recipient_staff_id uuid not null references public.staff (id),
  notification_id   uuid references public.notifications (id),
  read_at           timestamptz,
  archived_at       timestamptz,
  created_at        timestamptz not null default now(),
  constraint staff_message_recipient_once unique (message_id, recipient_staff_id)
);

create index if not exists staff_message_recipients_staff_idx
  on public.staff_message_recipients (recipient_staff_id, created_at desc);

-- ---------------------------------------------------------------------
-- 3. Sending an official communication
-- ---------------------------------------------------------------------

create or replace function public.secretary_search_residents(p_search text default null)
returns table (
  resident_id uuid, full_name text, id_number text, household_code text,
  street_address text, has_account boolean
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select r.id, r.first_name || ' ' || r.last_name, r.id_number, h.household_code,
           ls.street_address, (public.resident_account_id(r.id) is not null)
    from public.residents r
    left join public.households h on h.id = r.household_id
    left join public.land_sites ls on ls.id = h.residential_site_id
    where r.resident_status = 'active'
      and public.resident_account_id(r.id) is not null
      and (v_empty or r.first_name || ' ' || r.last_name ilike v_pattern
           or r.id_number ilike v_pattern
           or coalesce(h.household_code, '') ilike v_pattern
           or coalesce(ls.street_address, '') ilike v_pattern)
    order by r.last_name, r.first_name
    limit 50;
end;
$$;

create or replace function public.secretary_send_communication(
  p_communication_type text,
  p_audience_type      text,
  p_subject            text,
  p_message            text,
  p_resident_ids       uuid[] default null,
  p_issued_on_behalf_of text default null,
  p_event_date         date default null,
  p_event_time         time default null,
  p_venue              text default null,
  p_related_entity_type text default null,
  p_related_entity_id  uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id      uuid := public.acting_council_secretary_staff_id();
  v_communication public.resident_communications;
  v_reference     text;
  v_row           record;
  v_notification  uuid;
  v_count         int := 0;
  v_group         uuid;
  v_related_ref   text;
begin
  if p_communication_type is null or p_communication_type not in (
       'community_announcement', 'individual_notice', 'summons', 'general_notice') then
    raise exception 'That is not a kind of communication TAMS sends.' using errcode = 'TA110';
  end if;
  if p_audience_type is null or p_audience_type not in (
       'all_active_residents', 'one_resident', 'selected_residents') then
    raise exception 'A communication goes to all active residents, one resident, or a selection.'
      using errcode = 'TA111';
  end if;
  if btrim(coalesce(p_subject, '')) = '' or btrim(coalesce(p_message, '')) = '' then
    raise exception 'A communication needs a subject and a message.' using errcode = 'TA112';
  end if;
  if p_audience_type in ('one_resident', 'selected_residents')
     and coalesce(array_length(p_resident_ids, 1), 0) = 0 then
    raise exception 'Choose at least one resident to send this to.' using errcode = 'TA113';
  end if;
  if p_audience_type = 'one_resident' and array_length(p_resident_ids, 1) <> 1 then
    raise exception 'An individual notice goes to exactly one resident.' using errcode = 'TA113';
  end if;

  -- A linked record is referred to by its reference and nothing more.
  -- Linking a meeting never publishes that meeting.
  if p_related_entity_type is not null then
    v_related_ref := case p_related_entity_type
      when 'meeting'    then (select meeting_reference from public.council_meetings where id = p_related_entity_id)
      when 'resolution' then (select resolution_reference from public.council_resolutions where id = p_related_entity_id)
      when 'project'    then (select project_reference from public.community_projects where id = p_related_entity_id)
      end;
    if v_related_ref is null then
      raise exception 'That linked record could not be found.' using errcode = 'TA114';
    end if;
  end if;

  v_reference := public.council_reference('COM-', 'communication_reference', 'resident_communications');
  v_group := public.audit_context('SEND_RESIDENT_COMMUNICATION', null, null);

  insert into public.resident_communications (
    communication_reference, sent_by_staff_id, communication_type, audience_type,
    subject, message, issued_on_behalf_of, event_date, event_time, venue,
    related_entity_type, related_entity_id, related_reference)
  values (
    v_reference, v_staff_id, p_communication_type, p_audience_type,
    btrim(p_subject), btrim(p_message),
    nullif(btrim(coalesce(p_issued_on_behalf_of, '')), ''),
    p_event_date, p_event_time, nullif(btrim(coalesce(p_venue, '')), ''),
    p_related_entity_type, p_related_entity_id, v_related_ref)
  returning * into v_communication;

  -- The recipients, worked out now and written down now. Everything
  -- below reads only accounts that are verified and active at this
  -- moment: pending, declined and deactivated accounts are not
  -- recipients, and never become recipients later.
  for v_row in
    select r.id as resident_id, ua.id as account_id
    from public.residents r
    join public.user_accounts ua on ua.resident_id = r.id
    where ua.account_type = 'resident'
      and ua.account_status = 'active'
      and r.resident_status = 'active'
      and (p_audience_type = 'all_active_residents' or r.id = any (p_resident_ids))
  loop
    v_notification := public.notify_user(
      v_row.account_id, 'official_notice',
      v_communication.subject,
      v_communication.message
        || case when v_communication.event_date is not null
                then E'\n\nDate: ' || to_char(v_communication.event_date, 'DD Mon YYYY') else '' end
        || case when v_communication.event_time is not null
                then E'\nTime: ' || to_char(v_communication.event_time, 'HH24:MI') else '' end
        || case when v_communication.venue is not null
                then E'\nVenue: ' || v_communication.venue else '' end
        || case when v_communication.issued_on_behalf_of is not null
                then E'\n\nIssued on behalf of: ' || v_communication.issued_on_behalf_of else '' end,
      '/resident/notifications', 'resident_communication', v_communication.id, v_reference);

    insert into public.resident_communication_recipients (
      communication_id, resident_id, user_account_id, notification_id)
    values (v_communication.id, v_row.resident_id, v_row.account_id, v_notification)
    on conflict (communication_id, user_account_id) do nothing;

    v_count := v_count + 1;
  end loop;

  update public.resident_communications set recipient_count = v_count
   where id = v_communication.id;

  return jsonb_build_object(
    'communication_id', v_communication.id,
    'communication_reference', v_reference,
    'recipient_count', v_count,
    'event_group_id', v_group);
end;
$$;

create or replace function public.secretary_communications(
  p_type text default null,
  p_search text default null
)
returns table (
  communication_id uuid, communication_reference text, communication_type text,
  audience_type text, subject text, message text, issued_on_behalf_of text,
  event_date date, event_time time, venue text, related_reference text,
  recipient_count int, created_at timestamptz, sent_by text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select c.id, c.communication_reference, c.communication_type, c.audience_type,
           c.subject, c.message, c.issued_on_behalf_of, c.event_date, c.event_time,
           c.venue, c.related_reference, c.recipient_count, c.created_at,
           s.first_name || ' ' || s.last_name
    from public.resident_communications c
    join public.staff s on s.id = c.sent_by_staff_id
    where (p_type is null or c.communication_type = p_type)
      and (v_empty or c.communication_reference ilike v_pattern or c.subject ilike v_pattern)
    order by c.created_at desc;
end;
$$;

create or replace function public.secretary_communication_recipients(p_communication_id uuid)
returns table (full_name text, id_number text, household_code text, read_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select r.first_name || ' ' || r.last_name, r.id_number, h.household_code, n.read_at
    from public.resident_communication_recipients cr
    join public.residents r on r.id = cr.resident_id
    left join public.households h on h.id = r.household_id
    left join public.notifications n on n.id = cr.notification_id
    where cr.communication_id = p_communication_id
    order by r.last_name, r.first_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Staff messaging
-- ---------------------------------------------------------------------

create or replace function public.acting_staff_id()
returns uuid
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff_id uuid;
begin
  select ua.staff_id into v_staff_id
  from public.user_accounts ua
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and ua.staff_id is not null;

  if v_staff_id is null then
    raise exception 'Only an active staff member may use internal messaging.'
      using errcode = '42501';
  end if;
  return v_staff_id;
end;
$$;

create or replace function public.staff_role_name(p_staff_id uuid)
returns text
language sql stable security definer set search_path = public, pg_temp
as $$
  select r.role_name from public.staff s join public.roles r on r.id = s.role_id
  where s.id = p_staff_id;
$$;

create or replace function public.staff_send_message(
  p_subject             text,
  p_body                text,
  p_target_type         text,
  p_message_kind        text default 'normal',
  p_target_staff_id     uuid default null,
  p_target_role_id      uuid default null,
  p_related_entity_type text default null,
  p_related_entity_id   uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_sender      uuid := public.acting_staff_id();
  v_sender_role text := public.staff_role_name(v_sender);
  v_message     public.staff_messages;
  v_reference   text;
  v_related_ref text;
  v_row         record;
  v_count       int := 0;
  v_group       uuid;
  v_notification uuid;
begin
  if btrim(coalesce(p_subject, '')) = '' or btrim(coalesce(p_body, '')) = '' then
    raise exception 'A message needs a subject and a body.' using errcode = 'TA115';
  end if;
  if p_target_type is null or p_target_type not in ('direct', 'role', 'all_staff') then
    raise exception 'A message goes to one staff member, to a role, or to all staff.'
      using errcode = 'TA116';
  end if;
  if p_message_kind is null or p_message_kind not in ('normal', 'action_required', 'announcement') then
    raise exception 'A message is normal, action required, or an announcement.' using errcode = 'TA117';
  end if;

  -- An announcement to everybody is the Council Administrator's or the
  -- Council Secretary's to make.
  if p_target_type = 'all_staff'
     and v_sender_role not in ('Council Administrator', 'Council Secretary') then
    raise exception 'Only the Council Administrator or the Council Secretary may write to all staff.'
      using errcode = '42501';
  end if;

  if p_target_type = 'direct' then
    if p_target_staff_id is null then
      raise exception 'Choose the staff member to write to.' using errcode = 'TA116';
    end if;
    if p_target_staff_id = v_sender then
      raise exception 'There is no point writing to yourself.' using errcode = 'TA116';
    end if;
    if public.staff_account_id(p_target_staff_id) is null then
      raise exception 'That staff member''s account is not active.' using errcode = 'TA118';
    end if;
  elsif p_target_type = 'role' then
    if p_target_role_id is null
       or not exists (select 1 from public.roles where id = p_target_role_id) then
      raise exception 'Choose the role to write to.' using errcode = 'TA116';
    end if;
  end if;

  -- A link is a reference, never a key. It grants the recipient nothing
  -- at all; whether they may open it is decided where that record
  -- lives, exactly as it was before the message existed.
  if p_related_entity_type is not null then
    v_related_ref := case p_related_entity_type
      when 'resident'                 then (select id_number from public.residents where id = p_related_entity_id)
      when 'household'                then (select household_code from public.households where id = p_related_entity_id)
      when 'resident_account_request' then (select id_number from public.resident_account_requests where id = p_related_entity_id)
      when 'land_application'         then (select application_reference from public.land_applications where id = p_related_entity_id)
      when 'land_allocation'          then (select allocation_reference from public.land_allocations where id = p_related_entity_id)
      when 'pto'                      then (select pto_number from public.ptos where id = p_related_entity_id)
      when 'meeting'                  then (select meeting_reference from public.council_meetings where id = p_related_entity_id)
      when 'resolution'               then (select resolution_reference from public.council_resolutions where id = p_related_entity_id)
      when 'project'                  then (select project_reference from public.community_projects where id = p_related_entity_id)
      end;
    if v_related_ref is null then
      raise exception 'That linked record could not be found.' using errcode = 'TA114';
    end if;
  end if;

  v_reference := public.council_reference('MSG-', 'message_reference', 'staff_messages');
  v_group := public.audit_context('SEND_STAFF_MESSAGE', null, null);

  insert into public.staff_messages (
    message_reference, sender_staff_id, subject, body, message_kind, target_type,
    target_staff_id, target_role_id, related_entity_type, related_entity_id,
    related_reference, action_status)
  values (
    v_reference, v_sender, btrim(p_subject), btrim(p_body), p_message_kind, p_target_type,
    p_target_staff_id, p_target_role_id, p_related_entity_type, p_related_entity_id,
    v_related_ref,
    case when p_message_kind = 'action_required' then 'open' end)
  returning * into v_message;

  -- The recipients as they are now. Whoever holds the role tomorrow is
  -- not retrospectively a recipient of this.
  for v_row in
    select s.id as staff_id, ua.id as account_id
    from public.staff s
    join public.user_accounts ua on ua.staff_id = s.id
    where ua.account_type = 'staff'
      and ua.account_status = 'active'
      and s.id <> v_sender
      and (p_target_type = 'all_staff'
           or (p_target_type = 'direct' and s.id = p_target_staff_id)
           or (p_target_type = 'role' and s.role_id = p_target_role_id))
  loop
    -- The alert says who wrote, about what, and how urgent. The body
    -- itself stays inside TAMS; an email inbox is not the place for it.
    v_notification := public.notify_user(
      v_row.account_id,
      case when p_message_kind = 'action_required' then 'work_request' else 'staff_message' end,
      case when p_message_kind = 'action_required' then 'Action required: ' else '' end
        || v_message.subject,
      (select s.first_name || ' ' || s.last_name from public.staff s where s.id = v_sender)
        || ' (' || v_sender_role || ') has sent you '
        || case p_message_kind
             when 'action_required' then 'a work request'
             when 'announcement'    then 'an announcement'
             else 'a message' end
        || ' in TAMS'
        || case when v_related_ref is not null then ' about ' || v_related_ref else '' end
        || '. Open TAMS to read it.',
      '/messages/' || v_message.id::text, 'staff_message', v_message.id, v_reference);

    insert into public.staff_message_recipients (message_id, recipient_staff_id, notification_id)
    values (v_message.id, v_row.staff_id, v_notification)
    on conflict (message_id, recipient_staff_id) do nothing;

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'There is nobody active to send that to.' using errcode = 'TA118';
  end if;

  return jsonb_build_object(
    'message_id', v_message.id, 'message_reference', v_reference,
    'recipient_count', v_count, 'event_group_id', v_group);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Work requests
--
--    A role request goes to everybody who holds that role, and the
--    first of them to acknowledge it claims it. The row is locked for
--    the duration, so two people pressing at the same moment cannot
--    both win: the second one is told who did.
-- ---------------------------------------------------------------------

create or replace function public.staff_acknowledge_request(p_message_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := public.acting_staff_id();
  v_message public.staff_messages;
begin
  select * into v_message from public.staff_messages where id = p_message_id for update;
  if not found then
    raise exception 'That message could not be found.' using errcode = 'TA119';
  end if;
  if not exists (select 1 from public.staff_message_recipients
                  where message_id = v_message.id and recipient_staff_id = v_staff) then
    raise exception 'That work request was not sent to you.' using errcode = '42501';
  end if;
  if v_message.message_kind <> 'action_required' then
    raise exception 'That message is not a work request.' using errcode = 'TA119';
  end if;
  if v_message.action_status <> 'open' then
    raise exception 'That work request has already been claimed by %.',
      coalesce((select s.first_name || ' ' || s.last_name from public.staff s
                 where s.id = v_message.acknowledged_by_staff_id), 'somebody else')
      using errcode = 'TA119';
  end if;

  perform public.audit_context('ACKNOWLEDGE_WORK_REQUEST', null, null);

  update public.staff_messages
     set action_status = 'acknowledged',
         acknowledged_by_staff_id = v_staff, acknowledged_at = now()
   where id = v_message.id
  returning * into v_message;

  perform public.notify_user(
    public.staff_account_id(v_message.sender_staff_id), 'work_request',
    'Work request ' || v_message.message_reference || ' has been acknowledged',
    (select s.first_name || ' ' || s.last_name from public.staff s where s.id = v_staff)
      || ' has taken on "' || v_message.subject || '".',
    '/messages/' || v_message.id::text, 'staff_message', v_message.id, v_message.message_reference);

  return jsonb_build_object(
    'message_reference', v_message.message_reference,
    'action_status', v_message.action_status,
    'acknowledged_by', (select s.first_name || ' ' || s.last_name from public.staff s where s.id = v_staff));
end;
$$;

create or replace function public.staff_resolve_request(p_message_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := public.acting_staff_id();
  v_message public.staff_messages;
begin
  select * into v_message from public.staff_messages where id = p_message_id for update;
  if not found then
    raise exception 'That message could not be found.' using errcode = 'TA119';
  end if;
  if v_message.message_kind <> 'action_required' then
    raise exception 'That message is not a work request.' using errcode = 'TA119';
  end if;
  if v_message.action_status = 'open' then
    raise exception 'That work request has not been acknowledged yet.' using errcode = 'TA119';
  end if;
  if v_message.action_status = 'resolved' then
    raise exception 'That work request is already resolved.' using errcode = 'TA119';
  end if;
  -- Only whoever took it on may put it down.
  if v_message.acknowledged_by_staff_id <> v_staff then
    raise exception 'That work request belongs to %.',
      coalesce((select s.first_name || ' ' || s.last_name from public.staff s
                 where s.id = v_message.acknowledged_by_staff_id), 'somebody else')
      using errcode = '42501';
  end if;

  perform public.audit_context('RESOLVE_WORK_REQUEST', null, null);

  update public.staff_messages
     set action_status = 'resolved', resolved_by_staff_id = v_staff, resolved_at = now()
   where id = v_message.id
  returning * into v_message;

  perform public.notify_user(
    public.staff_account_id(v_message.sender_staff_id), 'work_request',
    'Work request ' || v_message.message_reference || ' has been resolved',
    (select s.first_name || ' ' || s.last_name from public.staff s where s.id = v_staff)
      || ' has resolved "' || v_message.subject || '".',
    '/messages/' || v_message.id::text, 'staff_message', v_message.id, v_message.message_reference);

  return jsonb_build_object(
    'message_reference', v_message.message_reference,
    'action_status', v_message.action_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Reading messages
-- ---------------------------------------------------------------------

create or replace function public.staff_messages_list(p_box text default 'inbox')
returns table (
  message_id uuid, message_reference text, subject text, message_kind text,
  target_type text, related_entity_type text, related_reference text,
  action_status text, created_at timestamptz,
  sender_name text, sender_role text,
  read_at timestamptz, archived_at timestamptz, recipient_count int,
  acknowledged_by text, resolved_by text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff uuid := public.acting_staff_id();
begin
  return query
    select m.id, m.message_reference, m.subject, m.message_kind, m.target_type,
           m.related_entity_type, m.related_reference, m.action_status, m.created_at,
           s.first_name || ' ' || s.last_name, r.role_name,
           mr.read_at, mr.archived_at,
           (select count(*)::int from public.staff_message_recipients x where x.message_id = m.id),
           (select a.first_name || ' ' || a.last_name from public.staff a where a.id = m.acknowledged_by_staff_id),
           (select b.first_name || ' ' || b.last_name from public.staff b where b.id = m.resolved_by_staff_id)
    from public.staff_messages m
    join public.staff s on s.id = m.sender_staff_id
    left join public.roles r on r.id = s.role_id
    left join public.staff_message_recipients mr
      on mr.message_id = m.id and mr.recipient_staff_id = v_staff
    where (p_box = 'sent' and m.sender_staff_id = v_staff)
       or (p_box = 'inbox' and mr.id is not null and mr.archived_at is null)
       or (p_box = 'archived' and mr.id is not null and mr.archived_at is not null)
    order by m.created_at desc;
end;
$$;

create or replace function public.staff_message(p_message_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_staff  uuid := public.acting_staff_id();
  v_result jsonb;
begin
  select jsonb_build_object(
    'message_id', m.id, 'message_reference', m.message_reference,
    'subject', m.subject, 'body', m.body, 'message_kind', m.message_kind,
    'target_type', m.target_type, 'created_at', m.created_at,
    'sender_name', s.first_name || ' ' || s.last_name,
    'sender_role', r.role_name,
    'is_sender', (m.sender_staff_id = v_staff),
    'target_role', (select ro.role_name from public.roles ro where ro.id = m.target_role_id),
    'related_entity_type', m.related_entity_type,
    'related_entity_id', m.related_entity_id,
    'related_reference', m.related_reference,
    'action_status', m.action_status,
    'acknowledged_by', (select a.first_name || ' ' || a.last_name from public.staff a
                         where a.id = m.acknowledged_by_staff_id),
    'acknowledged_at', m.acknowledged_at,
    'acknowledged_by_me', (m.acknowledged_by_staff_id = v_staff),
    'resolved_by', (select b.first_name || ' ' || b.last_name from public.staff b
                     where b.id = m.resolved_by_staff_id),
    'resolved_at', m.resolved_at,
    'am_recipient', exists (select 1 from public.staff_message_recipients x
                             where x.message_id = m.id and x.recipient_staff_id = v_staff),
    'read_at', (select x.read_at from public.staff_message_recipients x
                 where x.message_id = m.id and x.recipient_staff_id = v_staff),
    'archived_at', (select x.archived_at from public.staff_message_recipients x
                     where x.message_id = m.id and x.recipient_staff_id = v_staff),
    'recipients', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', rs.first_name || ' ' || rs.last_name,
               'role', rr.role_name,
               'read_at', x.read_at) order by rs.last_name)
      from public.staff_message_recipients x
      join public.staff rs on rs.id = x.recipient_staff_id
      left join public.roles rr on rr.id = rs.role_id
      where x.message_id = m.id), '[]'::jsonb)
  ) into v_result
  from public.staff_messages m
  join public.staff s on s.id = m.sender_staff_id
  left join public.roles r on r.id = s.role_id
  where m.id = p_message_id
    and (m.sender_staff_id = v_staff
         or exists (select 1 from public.staff_message_recipients x
                     where x.message_id = m.id and x.recipient_staff_id = v_staff));

  if v_result is null then
    raise exception 'That message is not yours to read.' using errcode = '42501';
  end if;

  return v_result;
end;
$$;

create or replace function public.staff_mark_message_read(p_message_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_staff uuid := public.acting_staff_id();
        v_updated int;
begin
  update public.staff_message_recipients set read_at = coalesce(read_at, now())
   where message_id = p_message_id and recipient_staff_id = v_staff;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'That message was not sent to you.' using errcode = '42501';
  end if;
  return jsonb_build_object('message_id', p_message_id, 'read', true);
end;
$$;

-- Archiving takes the recipient's own copy out of their inbox. The
-- message itself is untouched, and stays in everybody else's.
create or replace function public.staff_archive_message(p_message_id uuid, p_archived boolean default true)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_staff uuid := public.acting_staff_id();
        v_updated int;
begin
  update public.staff_message_recipients
     set archived_at = case when p_archived then coalesce(archived_at, now()) else null end,
         read_at = case when p_archived then coalesce(read_at, now()) else read_at end
   where message_id = p_message_id and recipient_staff_id = v_staff;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'That message was not sent to you.' using errcode = '42501';
  end if;
  return jsonb_build_object('message_id', p_message_id, 'archived', p_archived);
end;
$$;

-- Who a message may be addressed to: active staff, and the roles.
create or replace function public.staff_message_targets()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff uuid := public.acting_staff_id();
begin
  return jsonb_build_object(
    'may_announce', public.staff_role_name(v_staff) in ('Council Administrator', 'Council Secretary'),
    'staff', coalesce((
      select jsonb_agg(jsonb_build_object(
               'staff_id', s.id,
               'full_name', s.first_name || ' ' || s.last_name,
               'role', r.role_name) order by s.last_name, s.first_name)
      from public.staff s
      join public.roles r on r.id = s.role_id
      join public.user_accounts ua on ua.staff_id = s.id
      where ua.account_status = 'active' and s.id <> v_staff), '[]'::jsonb),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'role_id', r.id, 'role_name', r.role_name,
               'active_members', (select count(*) from public.staff s2
                                   join public.user_accounts u2 on u2.staff_id = s2.id
                                   where s2.role_id = r.id and u2.account_status = 'active'))
             order by r.role_name)
      from public.roles r), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Row Level Security
-- ---------------------------------------------------------------------

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'resident_communications', 'resident_communication_recipients',
    'staff_messages', 'staff_message_recipients'
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

-- The Secretary reads what they have sent. A resident does not read
-- this table at all: their copy is the notification.
drop policy if exists resident_communications_secretary on public.resident_communications;
create policy resident_communications_secretary
  on public.resident_communications for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists resident_communication_recipients_secretary on public.resident_communication_recipients;
create policy resident_communication_recipients_secretary
  on public.resident_communication_recipients for select to authenticated
  using (public.is_active_council_secretary()
         or user_account_id = public.current_user_account_id());

-- Read through a definer helper rather than through each other's
-- policies: two policies that each consult the other table recurse, and
-- Postgres refuses the query outright.
create or replace function public.staff_message_ids_for_me()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select m.id from public.staff_messages m
  where m.sender_staff_id = (select ua.staff_id from public.user_accounts ua
                              where ua.auth_user_id = auth.uid() and ua.account_status = 'active')
  union
  select x.message_id from public.staff_message_recipients x
  where x.recipient_staff_id = (select ua.staff_id from public.user_accounts ua
                                 where ua.auth_user_id = auth.uid() and ua.account_status = 'active');
$$;

-- A staff message is readable by the person who wrote it and by the
-- people it was actually sent to. The Council Administrator gets no
-- special key to other people's post.
drop policy if exists staff_messages_sender_or_recipient on public.staff_messages;
create policy staff_messages_sender_or_recipient
  on public.staff_messages for select to authenticated
  using (id in (select public.staff_message_ids_for_me()));

drop policy if exists staff_message_recipients_own on public.staff_message_recipients;
create policy staff_message_recipients_own
  on public.staff_message_recipients for select to authenticated
  using (message_id in (select public.staff_message_ids_for_me()));

-- Addressing an official notice means finding the person it is for.
-- The Secretary reads the register for that, and writes none of it:
-- every change to a resident or a household is still the Registry
-- Clerk's alone.
drop policy if exists residents_readable_by_council_secretary on public.residents;
create policy residents_readable_by_council_secretary
  on public.residents for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists households_readable_by_council_secretary on public.households;
create policy households_readable_by_council_secretary
  on public.households for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists land_sites_readable_by_council_secretary on public.land_sites;
create policy land_sites_readable_by_council_secretary
  on public.land_sites for select to authenticated
  using (public.is_active_council_secretary());

-- ---------------------------------------------------------------------
-- 8. Audit triggers for the two new records
--
--    Metadata only. The body of a private staff message and the wording
--    of an official notice are not copied into the audit trail.
-- ---------------------------------------------------------------------

drop trigger if exists audit_resident_communications on public.resident_communications;
create trigger audit_resident_communications
  after insert or update or delete on public.resident_communications
  for each row execute function public.tg_audit(
    'resident_communication', 'communication_reference', '', 'subject,message');

drop trigger if exists audit_staff_messages on public.staff_messages;
create trigger audit_staff_messages
  after insert or update or delete on public.staff_messages
  for each row execute function public.tg_audit(
    'staff_message', 'message_reference', 'action_status', 'subject,body');

-- ---------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.secretary_search_residents(text)',
    'public.secretary_send_communication(text, text, text, text, uuid[], text, date, time, text, text, uuid)',
    'public.secretary_communications(text, text)',
    'public.secretary_communication_recipients(uuid)',
    'public.staff_send_message(text, text, text, text, uuid, uuid, text, uuid)',
    'public.staff_acknowledge_request(uuid)',
    'public.staff_resolve_request(uuid)',
    'public.staff_messages_list(text)',
    'public.staff_message(uuid)',
    'public.staff_mark_message_read(uuid)',
    'public.staff_archive_message(uuid, boolean)',
    'public.staff_message_targets()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

revoke all on function public.acting_staff_id() from public, anon, authenticated;
revoke all on function public.staff_role_name(uuid) from public, anon, authenticated;
revoke all on function public.staff_message_ids_for_me() from public, anon;
-- Used inside a policy, so the querying role must be able to run it.
grant execute on function public.staff_message_ids_for_me() to authenticated;


-- ---------------------------------------------------------------------
-- 20261002090000_administrator_transfer.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — handing over the Council Administrator, and getting back in
-- when nobody can
--
-- The governance rule has not changed: normal operation has exactly one
-- active Council Administrator, and no ordinary staff function may ever
-- hand that role out. What changes here is that there is now a proper
-- way to pass it on — one transaction, one reason, one audit trail —
-- and a locked-away way to recover when there is nobody left holding it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The invariant, restated
--
--    It used to be "no second staff row may carry the administrator
--    role at all". That cannot survive a transfer that leaves the
--    outgoing administrator deactivated but still recorded as what they
--    were. The rule that actually matters is about live access:
--
--        AT MOST ONE ACTIVE COUNCIL ADMINISTRATOR
--
--    so that is what is enforced now — on the staff row and on the
--    account, because either one could otherwise create a second.
-- ---------------------------------------------------------------------

create or replace function public.active_council_administrator_count(p_excluding_staff_id uuid default null)
returns int
language sql stable security definer set search_path = public, pg_temp
as $$
  select count(*)::int
  from public.staff s
  join public.roles r on r.id = s.role_id
  join public.user_accounts ua on ua.staff_id = s.id
  where r.role_name = 'Council Administrator'
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and (p_excluding_staff_id is null or s.id <> p_excluding_staff_id);
$$;

create or replace function public.tg_enforce_single_council_administrator()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_admin_role_id uuid := public.council_administrator_role_id();
begin
  if new.role_id = v_admin_role_id
     and public.active_council_administrator_count(new.id) > 0 then
    raise exception 'An active Council Administrator already exists.' using errcode = 'TA001';
  end if;
  return new;
end;
$$;

-- The other way in: reactivating an account whose staff record still
-- carries the administrator role.
create or replace function public.tg_enforce_single_active_administrator_account()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.account_status = 'active'
     and new.account_type = 'staff'
     and new.staff_id is not null
     and exists (select 1 from public.staff s join public.roles r on r.id = s.role_id
                  where s.id = new.staff_id and r.role_name = 'Council Administrator')
     and public.active_council_administrator_count(new.staff_id) > 0 then
    raise exception 'An active Council Administrator already exists.' using errcode = 'TA001';
  end if;
  return new;
end;
$$;

drop trigger if exists user_accounts_single_active_administrator on public.user_accounts;
create trigger user_accounts_single_active_administrator
  before insert or update of account_status on public.user_accounts
  for each row execute function public.tg_enforce_single_active_administrator_account();

-- ---------------------------------------------------------------------
-- 2. Who could take it on
-- ---------------------------------------------------------------------

create or replace function public.admin_transfer_candidates()
returns table (
  staff_id uuid, employee_number text, full_name text, email text,
  role_name text, account_status text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_council_administrator_staff_id();
  return query
    select s.id, s.employee_number, s.first_name || ' ' || s.last_name, s.email,
           r.role_name, ua.account_status
    from public.staff s
    join public.roles r on r.id = s.role_id
    join public.user_accounts ua on ua.staff_id = s.id
    where ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name in ('Registry Clerk', 'Land Officer', 'Council Secretary')
      and exists (select 1 from auth.users u where u.id = ua.auth_user_id)
    order by s.last_name, s.first_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. The transfer
--
--    One transaction. Either the whole handover happened or none of it
--    did: there is no committed moment with two active administrators,
--    and none with none.
-- ---------------------------------------------------------------------

create or replace function public.transfer_council_administrator(
  p_incoming_staff_id  uuid,
  p_outgoing_outcome   text,      -- 'remain_staff' or 'deactivate'
  p_reason             text,
  p_outgoing_role_id   uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_outgoing_staff_id uuid := public.acting_council_administrator_staff_id();
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_outgoing public.staff;
  v_incoming public.staff;
  v_outgoing_account public.user_accounts;
  v_incoming_account public.user_accounts;
  v_incoming_role public.roles;
  v_outgoing_new_role public.roles;
  v_admin_role_id uuid := public.council_administrator_role_id();
  v_group uuid;
begin
  if v_reason = '' then
    raise exception 'A reason for the transfer is required.' using errcode = 'TA130';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA130';
  end if;
  if p_outgoing_outcome is null or p_outgoing_outcome not in ('remain_staff', 'deactivate') then
    raise exception 'Say what becomes of the outgoing administrator: remain as staff, or be deactivated.'
      using errcode = 'TA131';
  end if;

  select * into v_outgoing from public.staff where id = v_outgoing_staff_id for update;
  select * into v_outgoing_account from public.user_accounts where staff_id = v_outgoing.id for update;

  -- ---- the incoming administrator ---------------------------------
  if p_incoming_staff_id is null or p_incoming_staff_id = v_outgoing_staff_id then
    raise exception 'Choose a different staff member to transfer to.' using errcode = 'TA132';
  end if;

  select * into v_incoming from public.staff where id = p_incoming_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA132';
  end if;

  select * into v_incoming_role from public.roles where id = v_incoming.role_id;
  if v_incoming_role.role_name = 'Council Administrator' then
    raise exception 'That staff member already holds the Council Administrator role.'
      using errcode = 'TA132';
  end if;
  if v_incoming_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
    raise exception 'The incoming administrator must currently hold an ordinary staff role.'
      using errcode = 'TA132';
  end if;

  select * into v_incoming_account from public.user_accounts where staff_id = v_incoming.id for update;
  if not found or v_incoming_account.account_type <> 'staff' then
    raise exception 'That staff member has no staff account.' using errcode = 'TA133';
  end if;
  if v_incoming_account.account_status <> 'active' then
    raise exception 'That staff member''s account is deactivated, so they cannot take over.'
      using errcode = 'TA133';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_incoming_account.auth_user_id) then
    raise exception 'That staff member has no sign-in identity, so they cannot take over.'
      using errcode = 'TA133';
  end if;

  -- ---- what becomes of the outgoing one ---------------------------
  if p_outgoing_outcome = 'remain_staff' then
    select * into v_outgoing_new_role from public.roles where id = p_outgoing_role_id;
    if not found then
      raise exception 'Choose the ordinary role the outgoing administrator will hold.'
        using errcode = 'TA134';
    end if;
    if v_outgoing_new_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
      raise exception 'The outgoing administrator must take one of the three ordinary roles.'
        using errcode = 'TA134';
    end if;
  end if;

  -- ---- the handover, in order -------------------------------------
  --      The outgoing administrator stops being one first, so there is
  --      never an instant with two.
  v_group := public.audit_context('TRANSFER_COUNCIL_ADMINISTRATOR', v_reason, null);

  -- The actor's role is recorded now, before it changes, so the trail
  -- shows who they were when they did this.
  perform public.audit_event(
    'TRANSFER_COUNCIL_ADMINISTRATOR', 'staff', v_incoming.id, v_incoming.employee_number,
    jsonb_build_object(
      'administrator',        v_outgoing.first_name || ' ' || v_outgoing.last_name,
      'administrator_employee_number', v_outgoing.employee_number,
      'incoming_role',        v_incoming_role.role_name),
    jsonb_build_object(
      'administrator',        v_incoming.first_name || ' ' || v_incoming.last_name,
      'administrator_employee_number', v_incoming.employee_number,
      'outgoing_outcome',     p_outgoing_outcome,
      'outgoing_new_role',    case when p_outgoing_outcome = 'remain_staff'
                                   then v_outgoing_new_role.role_name else 'deactivated' end,
      'performed_by',         v_outgoing.first_name || ' ' || v_outgoing.last_name,
      'performed_by_role',    'Council Administrator'),
    v_reason);

  if p_outgoing_outcome = 'remain_staff' then
    update public.staff set role_id = v_outgoing_new_role.id where id = v_outgoing.id;
  else
    -- The role is left as it was: they were the administrator, and the
    -- record should keep saying so. What stops them acting is the
    -- account, which is the single source of truth for access.
    update public.user_accounts set account_status = 'deactivated' where id = v_outgoing_account.id;
    update public.staff
       set last_deactivated_at = now(),
           last_deactivated_by_staff_id = v_outgoing.id,
           last_deactivation_reason = 'Administrator transfer: ' || v_reason
     where id = v_outgoing.id;
  end if;

  update public.staff set role_id = v_admin_role_id where id = v_incoming.id;

  -- ---- exactly one, or none of this happened ----------------------
  if public.active_council_administrator_count() <> 1 then
    raise exception 'The transfer would not have left exactly one active Council Administrator.'
      using errcode = 'TA135';
  end if;

  -- ---- telling both of them ---------------------------------------
  perform public.notify_user(
    public.staff_account_id(v_incoming.id), 'administration',
    'You are now the Council Administrator',
    v_outgoing.first_name || ' ' || v_outgoing.last_name ||
    ' has transferred the Council Administrator role to you. Reason: ' || v_reason ||
    '. You now manage staff accounts and can read the audit trail.',
    '/dashboard', 'staff', v_incoming.id, v_incoming.employee_number);

  if p_outgoing_outcome = 'remain_staff' then
    perform public.notify_user(
      public.staff_account_id(v_outgoing.id), 'administration',
      'You are no longer the Council Administrator',
      'The Council Administrator role has been transferred to ' ||
      v_incoming.first_name || ' ' || v_incoming.last_name ||
      '. You now hold the ' || v_outgoing_new_role.role_name || ' role. Reason: ' || v_reason || '.',
      '/home', 'staff', v_outgoing.id, v_outgoing.employee_number);
  end if;

  return jsonb_build_object(
    'event_group_id',     v_group,
    'outgoing_name',      v_outgoing.first_name || ' ' || v_outgoing.last_name,
    'outgoing_outcome',   p_outgoing_outcome,
    'outgoing_new_role',  case when p_outgoing_outcome = 'remain_staff'
                               then v_outgoing_new_role.role_name else null end,
    'incoming_name',      v_incoming.first_name || ' ' || v_incoming.last_name,
    'incoming_previous_role', v_incoming_role.role_name,
    'active_administrators', public.active_council_administrator_count(),
    'reason',             v_reason);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Emergency recovery
--
--    For one situation only: TAMS has no administrator anybody can sign
--    in as. Not a forgotten password — that is what password recovery
--    is for — but an account that is gone, deactivated, or whose
--    sign-in identity no longer exists.
--
--    There is no page anywhere in the application that reaches this. It
--    runs as service_role, from an edge function that first checks a
--    secret only the person who set the project up knows, and it
--    refuses outright the moment a healthy administrator exists.
-- ---------------------------------------------------------------------

create or replace function public.administrator_health()
returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'active_administrators', public.active_council_administrator_count(),
    -- An administrator who can actually sign in: active account, active
    -- staff record, and an auth identity that still exists.
    'valid_administrators', (
      select count(*) from public.staff s
      join public.roles r on r.id = s.role_id
      join public.user_accounts ua on ua.staff_id = s.id
      join auth.users u on u.id = ua.auth_user_id
      where r.role_name = 'Council Administrator'
        and ua.account_type = 'staff'
        and ua.account_status = 'active'));
$$;

create or replace function public.emergency_recovery_candidates()
returns table (
  staff_id uuid, employee_number text, full_name text, email text, role_name text
)
language sql stable security definer set search_path = public, pg_temp
as $$
  select s.id, s.employee_number, s.first_name || ' ' || s.last_name, s.email, r.role_name
  from public.staff s
  join public.roles r on r.id = s.role_id
  join public.user_accounts ua on ua.staff_id = s.id
  join auth.users u on u.id = ua.auth_user_id
  where ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name in ('Registry Clerk', 'Land Officer', 'Council Secretary')
  order by s.last_name, s.first_name;
$$;

create or replace function public.emergency_promote_administrator(
  p_staff_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_staff   public.staff;
  v_account public.user_accounts;
  v_role    public.roles;
  v_health  jsonb := public.administrator_health();
begin
  if v_reason = '' then
    raise exception 'A reason for the emergency recovery is required.' using errcode = 'TA136';
  end if;

  -- The whole guard. If somebody can already sign in as the
  -- administrator, this is not an emergency and there is nothing here.
  if (v_health ->> 'valid_administrators')::int > 0 then
    raise exception 'TAMS already has an active Council Administrator who can sign in. Use the ordinary Administrator Transfer, or normal password recovery.'
      using errcode = 'TA137';
  end if;

  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA138';
  end if;

  select * into v_role from public.roles where id = v_staff.role_id;
  if v_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
    raise exception 'Recovery promotes an existing ordinary staff member.' using errcode = 'TA138';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found or v_account.account_type <> 'staff' or v_account.account_status <> 'active' then
    raise exception 'That staff member has no active staff account.' using errcode = 'TA138';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_account.auth_user_id) then
    raise exception 'That staff member has no sign-in identity.' using errcode = 'TA138';
  end if;

  perform public.audit_context('EMERGENCY_ADMIN_RECOVERY', v_reason, null);

  update public.staff set role_id = public.council_administrator_role_id() where id = v_staff.id;

  if public.active_council_administrator_count() <> 1 then
    raise exception 'Recovery would not have left exactly one active Council Administrator.'
      using errcode = 'TA135';
  end if;

  -- The reason is recorded. The secret that let this run is not, here
  -- or anywhere else: it never reaches the database at all.
  perform public.audit_event(
    'EMERGENCY_ADMIN_RECOVERY', 'staff', v_staff.id, v_staff.employee_number,
    jsonb_build_object('role', v_role.role_name,
                       'valid_administrators_before', (v_health ->> 'valid_administrators')::int),
    jsonb_build_object('role', 'Council Administrator',
                       'administrator', v_staff.first_name || ' ' || v_staff.last_name,
                       'recovered_by', 'emergency recovery process'),
    v_reason);

  perform public.notify_user(
    public.staff_account_id(v_staff.id), 'administration',
    'You are now the Council Administrator',
    'TAMS had no Council Administrator who could sign in, and the emergency recovery process has ' ||
    'promoted your account. Reason given: ' || v_reason || '.',
    '/dashboard', 'staff', v_staff.id, v_staff.employee_number);

  return jsonb_build_object(
    'staff_id', v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name', v_staff.first_name || ' ' || v_staff.last_name,
    'previous_role', v_role.role_name,
    'active_administrators', public.active_council_administrator_count());
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Naming the staff actions in the trail
--
--    The three ordinary staff operations get their proper names and
--    carry their reason, so the audit reads as what happened rather
--    than as a row that changed.
-- ---------------------------------------------------------------------

create or replace function public.change_staff_role(p_staff_id uuid, p_new_role_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
  v_staff          public.staff;
  v_account        public.user_accounts;
  v_current_role   public.roles;
  v_new_role       public.roles;
begin
  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA010';
  end if;

  select * into v_current_role from public.roles where id = v_staff.role_id;
  if v_current_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be changed here.' using errcode = 'TA011';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found or v_account.account_status <> 'active' then
    raise exception 'That staff member''s account is not active, so their role cannot be changed.'
      using errcode = 'TA012';
  end if;

  select * into v_new_role from public.roles where id = p_new_role_id;
  if not found then
    raise exception 'The selected role does not exist.' using errcode = 'TA013';
  end if;
  -- Still refused, transfer or no transfer. The administrator role is
  -- handed over by Administrator Transfer and by nothing else.
  if v_new_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be assigned to a staff member.'
      using errcode = 'TA014';
  end if;
  if v_new_role.id = v_staff.role_id then
    raise exception 'That staff member already holds the % role.', v_new_role.role_name
      using errcode = 'TA015';
  end if;

  perform public.audit_context('STAFF_ROLE_CHANGED', null, null);
  update public.staff set role_id = v_new_role.id where id = v_staff.id;

  return jsonb_build_object(
    'staff_id', v_staff.id, 'employee_number', v_staff.employee_number,
    'full_name', v_staff.first_name || ' ' || v_staff.last_name, 'email', v_staff.email,
    'previous_role', v_current_role.role_name, 'new_role', v_new_role.role_name,
    'account_status', v_account.account_status, 'changed_by', v_admin_staff_id);
end;
$$;

-- The same two, only so the audit says what happened and carries the
-- reason across both rows the operation writes.
do $$
begin
  execute $fn$
    create or replace function public.deactivate_staff_account(p_staff_id uuid, p_reason text)
    returns jsonb
    language plpgsql volatile security definer set search_path = public, pg_temp
    as $body$
    declare
      v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
      v_reason text := btrim(coalesce(p_reason, ''));
      v_staff public.staff; v_account public.user_accounts; v_role public.roles;
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
        raise exception 'The Council Administrator account cannot be deactivated here.' using errcode = 'TA011';
      end if;

      select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
      if not found then
        raise exception 'That staff member has no user account.' using errcode = 'TA010';
      end if;
      if v_account.account_status = 'deactivated' then
        raise exception 'That account is already deactivated.' using errcode = 'TA016';
      end if;

      perform public.audit_context('STAFF_DEACTIVATED', v_reason, null);

      update public.user_accounts set account_status = 'deactivated' where id = v_account.id;
      update public.staff
         set last_deactivated_at = now(),
             last_deactivated_by_staff_id = v_admin_staff_id,
             last_deactivation_reason = v_reason
       where id = v_staff.id;

      return jsonb_build_object(
        'staff_id', v_staff.id, 'employee_number', v_staff.employee_number,
        'full_name', v_staff.first_name || ' ' || v_staff.last_name, 'email', v_staff.email,
        'role_name', v_role.role_name, 'account_status', 'deactivated',
        'reason', v_reason, 'deactivated_by', v_admin_staff_id);
    end;
    $body$;
  $fn$;

  execute $fn$
    create or replace function public.reactivate_staff_account(p_staff_id uuid, p_reason text)
    returns jsonb
    language plpgsql volatile security definer set search_path = public, pg_temp
    as $body$
    declare
      v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
      v_reason text := btrim(coalesce(p_reason, ''));
      v_staff public.staff; v_account public.user_accounts; v_role public.roles;
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
        raise exception 'The Council Administrator account is not managed here.' using errcode = 'TA011';
      end if;

      select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
      if not found then
        raise exception 'That staff member has no user account.' using errcode = 'TA010';
      end if;
      if v_account.account_status = 'active' then
        raise exception 'That account is already active.' using errcode = 'TA017';
      end if;

      perform public.audit_context('STAFF_REACTIVATED', v_reason, null);

      update public.user_accounts set account_status = 'active' where id = v_account.id;
      update public.staff
         set last_reactivated_at = now(),
             last_reactivated_by_staff_id = v_admin_staff_id,
             last_reactivation_reason = v_reason
       where id = v_staff.id;

      return jsonb_build_object(
        'staff_id', v_staff.id, 'employee_number', v_staff.employee_number,
        'full_name', v_staff.first_name || ' ' || v_staff.last_name, 'email', v_staff.email,
        'role_name', v_role.role_name, 'account_status', 'active',
        'reason', v_reason, 'reactivated_by', v_admin_staff_id);
    end;
    $body$;
  $fn$;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.admin_transfer_candidates()',
    'public.transfer_council_administrator(uuid, text, text, uuid)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

-- Recovery is not reachable from a browser at all, at any privilege.
revoke all on function public.emergency_promote_administrator(uuid, text) from public, anon, authenticated;
revoke all on function public.emergency_recovery_candidates() from public, anon, authenticated;
revoke all on function public.administrator_health() from public, anon, authenticated;
revoke all on function public.active_council_administrator_count(uuid) from public, anon, authenticated;
grant execute on function public.emergency_promote_administrator(uuid, text) to service_role;
grant execute on function public.emergency_recovery_candidates() to service_role;
grant execute on function public.administrator_health() to service_role;


-- ---------------------------------------------------------------------
-- 20261003090000_password_reset_audit.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- TAMS — recording that somebody reset their password
--
-- The reset itself is Supabase Auth's: TAMS mints no recovery token,
-- stores none, and never touches the auth tables. What this adds is one
-- line in the audit trail saying that a password was reset, by whom and
-- when — and nothing else.
--
-- Deliberately taking no parameters at all. The function cannot be
-- asked to name a different actor, a different account or a different
-- action: everything it records it works out for itself from
-- auth.uid(). A caller therefore gains nothing by calling it that they
-- could not already say truthfully about themselves, which is why it
-- does not weaken the authentication boundary the way an ordinary
-- "write me an audit entry" endpoint would.
-- =====================================================================

create or replace function public.record_password_reset()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare v_account public.user_accounts;
begin
  select * into v_account from public.user_accounts where auth_user_id = auth.uid();

  -- A recovery session with no TAMS account behind it. There is nothing
  -- to record, and saying so would be saying something about who does
  -- and does not have an account here.
  if not found then
    return jsonb_build_object('recorded', false);
  end if;

  -- No old value and no new value: nothing in TAMS changed, and the
  -- one thing that did change outside it is a password, which is never
  -- written down here in any form.
  perform public.audit_event(
    'PASSWORD_RESET_COMPLETED',
    'user_account',
    v_account.id,
    v_account.email,
    null,
    null,
    null);

  return jsonb_build_object('recorded', true);
end;
$$;

revoke all on function public.record_password_reset() from public, anon, authenticated;
grant execute on function public.record_password_reset() to authenticated;


-- ---------------------------------------------------------------------
-- 20261004090000_final_hardening.sql
-- ---------------------------------------------------------------------
-- =====================================================================
-- Final hardening pass.
--
-- Two findings from the whole-schema security review, and one thing
-- deliberately left as it is.
--
-- 1. Trigger functions were still executable by PUBLIC.
--
--    Every ordinary function in TAMS has its EXECUTE revoked from
--    public, anon and authenticated and then granted back only to
--    authenticated. The trigger functions were never put through that,
--    because they are never called by name — so they kept PostgreSQL's
--    default, which is EXECUTE to PUBLIC.
--
--    PostgreSQL refuses to run a `returns trigger` function called
--    directly, so this was not a way in. It was an inconsistency in a
--    schema whose whole defence is that the privileges are uniform and
--    can be read off in one query. Now they are.
--
-- 2. audit_logs is intentionally NOT `force row level security`.
--
--    Every other table is forced. This one must not be, and the reason
--    is worth writing down so nobody "fixes" it later:
--
--      * audit_logs is written only by security definer functions
--        owned by the schema owner. FORCE makes the owner subject to
--        the policies too, and there is deliberately no INSERT policy —
--        so forcing it would silently stop the system auditing itself.
--      * Nothing is lost. `authenticated` is never the owner, holds no
--        INSERT, UPDATE or DELETE grant on the table, and is fully
--        subject to audit_logs_administrator_reads.
--      * Immutability does not come from RLS at all. It comes from
--        tg_audit_logs_are_immutable, which raises on any update or
--        delete whoever attempts it.
--
--    The supabase/tests suite pins all three of those properties, so
--    the reasoning is checked rather than merely asserted here.
-- =====================================================================

do $$
declare
  v_signature text;
begin
  for v_signature in
    select p.oid::regprocedure::text
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join pg_type t on t.oid = p.prorettype
     where n.nspname = 'public'
       and t.typname = 'trigger'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
  end loop;
end;
$$;


-- =====================================================================
-- 3. An audited change must name only what actually changed.
--
--    audit_event() is the hand-written path: the few events that are
--    not a row being written, such as an administrator transfer. It
--    filled changed_fields with every key of the new side, whether or
--    not that key existed on the old side and whether or not its value
--    had moved.
--
--    The trigger path has always computed a real diff. This makes the
--    hand-written path agree with it, so the Council Administrator
--    reading the trail sees the same thing either way:
--
--      * both sides given  -> the keys whose values genuinely differ,
--                             across the union of the two sides, so a
--                             field that only appears on one side still
--                             counts as having moved;
--      * only the new side -> a creation: everything arrived, nothing
--                             moved, which is what the trigger records
--                             for an INSERT too.
--
--    Nothing that was already written changes. audit_logs is insert
--    only, and history is not ours to correct.
-- =====================================================================

create or replace function public.audit_event(
  p_action     text,
  p_entity     text,
  p_entity_id  uuid default null,
  p_reference  text default null,
  p_old        jsonb default null,
  p_new        jsonb default null,
  p_reason     text default null
)
returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_actor   jsonb := public.audit_actor();
  v_group   uuid := nullif(public.audit_context_value('tams.audit_group'), '')::uuid;
  v_old     jsonb := public.audit_strip(p_old);
  v_new     jsonb := public.audit_strip(p_new);
  v_changed text[];
  v_id      uuid;
begin
  if p_new is null then
    v_changed := null;
  elsif p_old is null then
    -- A creation. Everything on the new side arrived at once.
    select coalesce(array_agg(k order by k), '{}') into v_changed
      from jsonb_object_keys(v_new) as k;
  else
    -- A change. Only what moved, judged over both sides together.
    select coalesce(array_agg(k order by k), '{}') into v_changed
      from (select jsonb_object_keys(v_old) as k
            union
            select jsonb_object_keys(v_new)) as keys
     where v_old -> k is distinct from v_new -> k;
  end if;

  insert into public.audit_logs (
    actor_user_id, actor_staff_id, actor_role, actor_account_type, actor_label,
    action, entity_type, entity_id, entity_reference,
    old_values, new_values, changed_fields, reason, event_group_id)
  values (
    nullif(v_actor ->> 'actor_user_id', '')::uuid,
    nullif(v_actor ->> 'actor_staff_id', '')::uuid,
    v_actor ->> 'actor_role', v_actor ->> 'actor_account_type', v_actor ->> 'actor_label',
    p_action, p_entity, p_entity_id, p_reference,
    case when p_old is null then null else v_old end,
    case when p_new is null then null else v_new end,
    v_changed,
    nullif(btrim(coalesce(p_reason, '')), ''),
    v_group)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.audit_event(text, text, uuid, text, jsonb, jsonb, text)
  from public, anon, authenticated;


-- =====================================================================
-- 4. The two hand-written events now read as a real before and after.
--
--    Administrator transfer and emergency recovery each built their own
--    old and new objects, and the two sides carried different keys. The
--    Council Administrator reading the trail saw four fields whose
--    "from" column was empty, and one whose "to" column was, for an
--    event where every one of those facts genuinely has both.
--
--    Two of the fields were not a before-and-after at all: performed_by
--    and performed_by_role repeated the actor, which every audit row
--    already records in its own columns.
--
--    Only the payloads change. Neither function's behaviour, checks or
--    return value moves, and nothing already written is touched.
-- =====================================================================

create or replace function public.transfer_council_administrator(
  p_incoming_staff_id  uuid,
  p_outgoing_outcome   text,      -- 'remain_staff' or 'deactivate'
  p_reason             text,
  p_outgoing_role_id   uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_outgoing_staff_id uuid := public.acting_council_administrator_staff_id();
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_outgoing public.staff;
  v_incoming public.staff;
  v_outgoing_account public.user_accounts;
  v_incoming_account public.user_accounts;
  v_incoming_role public.roles;
  v_outgoing_new_role public.roles;
  v_admin_role_id uuid := public.council_administrator_role_id();
  v_group uuid;
begin
  if v_reason = '' then
    raise exception 'A reason for the transfer is required.' using errcode = 'TA130';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA130';
  end if;
  if p_outgoing_outcome is null or p_outgoing_outcome not in ('remain_staff', 'deactivate') then
    raise exception 'Say what becomes of the outgoing administrator: remain as staff, or be deactivated.'
      using errcode = 'TA131';
  end if;

  select * into v_outgoing from public.staff where id = v_outgoing_staff_id for update;
  select * into v_outgoing_account from public.user_accounts where staff_id = v_outgoing.id for update;

  -- ---- the incoming administrator ---------------------------------
  if p_incoming_staff_id is null or p_incoming_staff_id = v_outgoing_staff_id then
    raise exception 'Choose a different staff member to transfer to.' using errcode = 'TA132';
  end if;

  select * into v_incoming from public.staff where id = p_incoming_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA132';
  end if;

  select * into v_incoming_role from public.roles where id = v_incoming.role_id;
  if v_incoming_role.role_name = 'Council Administrator' then
    raise exception 'That staff member already holds the Council Administrator role.'
      using errcode = 'TA132';
  end if;
  if v_incoming_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
    raise exception 'The incoming administrator must currently hold an ordinary staff role.'
      using errcode = 'TA132';
  end if;

  select * into v_incoming_account from public.user_accounts where staff_id = v_incoming.id for update;
  if not found or v_incoming_account.account_type <> 'staff' then
    raise exception 'That staff member has no staff account.' using errcode = 'TA133';
  end if;
  if v_incoming_account.account_status <> 'active' then
    raise exception 'That staff member''s account is deactivated, so they cannot take over.'
      using errcode = 'TA133';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_incoming_account.auth_user_id) then
    raise exception 'That staff member has no sign-in identity, so they cannot take over.'
      using errcode = 'TA133';
  end if;

  -- ---- what becomes of the outgoing one ---------------------------
  if p_outgoing_outcome = 'remain_staff' then
    select * into v_outgoing_new_role from public.roles where id = p_outgoing_role_id;
    if not found then
      raise exception 'Choose the ordinary role the outgoing administrator will hold.'
        using errcode = 'TA134';
    end if;
    if v_outgoing_new_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
      raise exception 'The outgoing administrator must take one of the three ordinary roles.'
        using errcode = 'TA134';
    end if;
  end if;

  -- ---- the handover, in order -------------------------------------
  --      The outgoing administrator stops being one first, so there is
  --      never an instant with two.
  v_group := public.audit_context('TRANSFER_COUNCIL_ADMINISTRATOR', v_reason, null);

  -- The actor's role is recorded now, before it changes, so the trail
  -- shows who they were when they did this.
  perform public.audit_event(
    'TRANSFER_COUNCIL_ADMINISTRATOR', 'staff', v_incoming.id, v_incoming.employee_number,
    -- Both sides describe the same four facts, so the trail reads as a
    -- genuine before and after. Who performed the transfer is not
    -- repeated here: the audit row already records the actor.
    jsonb_build_object(
      'administrator',                 v_outgoing.first_name || ' ' || v_outgoing.last_name,
      'administrator_employee_number', v_outgoing.employee_number,
      'incoming_administrator_role',   v_incoming_role.role_name,
      'outgoing_administrator_role',   'Council Administrator'),
    jsonb_build_object(
      'administrator',                 v_incoming.first_name || ' ' || v_incoming.last_name,
      'administrator_employee_number', v_incoming.employee_number,
      'incoming_administrator_role',   'Council Administrator',
      'outgoing_administrator_role',   case when p_outgoing_outcome = 'remain_staff'
                                            then v_outgoing_new_role.role_name
                                            else 'deactivated' end),
    v_reason);

  if p_outgoing_outcome = 'remain_staff' then
    update public.staff set role_id = v_outgoing_new_role.id where id = v_outgoing.id;
  else
    -- The role is left as it was: they were the administrator, and the
    -- record should keep saying so. What stops them acting is the
    -- account, which is the single source of truth for access.
    update public.user_accounts set account_status = 'deactivated' where id = v_outgoing_account.id;
    update public.staff
       set last_deactivated_at = now(),
           last_deactivated_by_staff_id = v_outgoing.id,
           last_deactivation_reason = 'Administrator transfer: ' || v_reason
     where id = v_outgoing.id;
  end if;

  update public.staff set role_id = v_admin_role_id where id = v_incoming.id;

  -- ---- exactly one, or none of this happened ----------------------
  if public.active_council_administrator_count() <> 1 then
    raise exception 'The transfer would not have left exactly one active Council Administrator.'
      using errcode = 'TA135';
  end if;

  -- ---- telling both of them ---------------------------------------
  perform public.notify_user(
    public.staff_account_id(v_incoming.id), 'administration',
    'You are now the Council Administrator',
    v_outgoing.first_name || ' ' || v_outgoing.last_name ||
    ' has transferred the Council Administrator role to you. Reason: ' || v_reason ||
    '. You now manage staff accounts and can read the audit trail.',
    '/dashboard', 'staff', v_incoming.id, v_incoming.employee_number);

  if p_outgoing_outcome = 'remain_staff' then
    perform public.notify_user(
      public.staff_account_id(v_outgoing.id), 'administration',
      'You are no longer the Council Administrator',
      'The Council Administrator role has been transferred to ' ||
      v_incoming.first_name || ' ' || v_incoming.last_name ||
      '. You now hold the ' || v_outgoing_new_role.role_name || ' role. Reason: ' || v_reason || '.',
      '/home', 'staff', v_outgoing.id, v_outgoing.employee_number);
  end if;

  return jsonb_build_object(
    'event_group_id',     v_group,
    'outgoing_name',      v_outgoing.first_name || ' ' || v_outgoing.last_name,
    'outgoing_outcome',   p_outgoing_outcome,
    'outgoing_new_role',  case when p_outgoing_outcome = 'remain_staff'
                               then v_outgoing_new_role.role_name else null end,
    'incoming_name',      v_incoming.first_name || ' ' || v_incoming.last_name,
    'incoming_previous_role', v_incoming_role.role_name,
    'active_administrators', public.active_council_administrator_count(),
    'reason',             v_reason);
end;
$$;
create or replace function public.emergency_promote_administrator(
  p_staff_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_staff   public.staff;
  v_account public.user_accounts;
  v_role    public.roles;
  v_health  jsonb := public.administrator_health();
begin
  if v_reason = '' then
    raise exception 'A reason for the emergency recovery is required.' using errcode = 'TA136';
  end if;

  -- The whole guard. If somebody can already sign in as the
  -- administrator, this is not an emergency and there is nothing here.
  if (v_health ->> 'valid_administrators')::int > 0 then
    raise exception 'TAMS already has an active Council Administrator who can sign in. Use the ordinary Administrator Transfer, or normal password recovery.'
      using errcode = 'TA137';
  end if;

  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA138';
  end if;

  select * into v_role from public.roles where id = v_staff.role_id;
  if v_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
    raise exception 'Recovery promotes an existing ordinary staff member.' using errcode = 'TA138';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found or v_account.account_type <> 'staff' or v_account.account_status <> 'active' then
    raise exception 'That staff member has no active staff account.' using errcode = 'TA138';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_account.auth_user_id) then
    raise exception 'That staff member has no sign-in identity.' using errcode = 'TA138';
  end if;

  perform public.audit_context('EMERGENCY_ADMIN_RECOVERY', v_reason, null);

  update public.staff set role_id = public.council_administrator_role_id() where id = v_staff.id;

  if public.active_council_administrator_count() <> 1 then
    raise exception 'Recovery would not have left exactly one active Council Administrator.'
      using errcode = 'TA135';
  end if;

  -- The reason is recorded. The secret that let this run is not, here
  -- or anywhere else: it never reaches the database at all.
  perform public.audit_event(
    'EMERGENCY_ADMIN_RECOVERY', 'staff', v_staff.id, v_staff.employee_number,
    -- The same two facts on each side. That this was the recovery
    -- process is the action's name, and who it promoted is the entity.
    jsonb_build_object(
      'administrator_role',   v_role.role_name,
      'valid_administrators', (v_health ->> 'valid_administrators')::int),
    jsonb_build_object(
      'administrator_role',   'Council Administrator',
      'valid_administrators', public.active_council_administrator_count()),
    v_reason);

  perform public.notify_user(
    public.staff_account_id(v_staff.id), 'administration',
    'You are now the Council Administrator',
    'TAMS had no Council Administrator who could sign in, and the emergency recovery process has ' ||
    'promoted your account. Reason given: ' || v_reason || '.',
    '/dashboard', 'staff', v_staff.id, v_staff.employee_number);

  return jsonb_build_object(
    'staff_id', v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name', v_staff.first_name || ' ' || v_staff.last_name,
    'previous_role', v_role.role_name,
    'active_administrators', public.active_council_administrator_count());
end;
$$;


-- ---------------------------------------------------------------------
-- 20261007180000_resident_verification_validation.sql
-- ---------------------------------------------------------------------
-- Validate new verification claims, including requests made directly to
-- the RPC. Existing applications remain reviewable: this trigger runs
-- only on inserts or edits to identity fields, not approval/decline.
create or replace function public.validate_resident_verification_identity()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_name text;
  v_label text;
  v_required boolean;
begin
  new.id_number := btrim(coalesce(new.id_number, ''));
  if new.id_number !~ '^[0-9]{13}$' then
    raise exception 'Enter exactly 13 digits for your South African ID number.' using errcode = 'TV001';
  end if;
  if new.date_of_birth is null or new.date_of_birth > current_date then
    raise exception 'Enter a valid date of birth that is not in the future.' using errcode = 'TV001';
  end if;
  if to_char(new.date_of_birth, 'YYMMDD') <> left(new.id_number, 6) then
    raise exception 'Date of birth must match the first six digits of your ID number.' using errcode = 'TV001';
  end if;

  new.gender := btrim(coalesce(new.gender, ''));
  if new.gender not in ('Male', 'Female') then
    raise exception 'Select Male or Female.' using errcode = 'TV001';
  end if;

  new.first_name := normalize(btrim(new.first_name), NFC);
  new.middle_names := nullif(normalize(btrim(new.middle_names), NFC), '');
  new.last_name := normalize(btrim(new.last_name), NFC);
  new.previous_surname := nullif(normalize(btrim(new.previous_surname), NFC), '');
  new.household_head_name := normalize(btrim(new.household_head_name), NFC);

  for v_name, v_label, v_required in
    select * from (values
      (new.first_name, 'First name', true),
      (new.middle_names, 'Middle name(s)', false),
      (new.last_name, 'Surname', true),
      (new.previous_surname, 'Previous or maiden surname', false),
      (new.household_head_name, 'Household head''s name', true)
    ) as names(value, label, required)
  loop
    v_name := coalesce(v_name, '');
    if v_name = '' and not v_required then continue; end if;
    if char_length(regexp_replace(v_name, '[^[:alpha:]]', '', 'g')) < 3 then
      raise exception '% must contain at least 3 letters.', v_label using errcode = 'TV001';
    end if;
    if v_name !~ '^[[:alpha:]]+([ ''’-]+[[:alpha:]]+)*$' then
      raise exception '% may contain letters, spaces, apostrophes and hyphens only.', v_label
        using errcode = 'TV001';
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function public.validate_resident_verification_identity() from public, anon, authenticated;

drop trigger if exists resident_verification_identity_validation on public.resident_account_requests;
create trigger resident_verification_identity_validation
before insert or update of id_number, date_of_birth, gender, first_name,
  middle_names, last_name, previous_surname, household_head_name
on public.resident_account_requests
for each row execute function public.validate_resident_verification_identity();

