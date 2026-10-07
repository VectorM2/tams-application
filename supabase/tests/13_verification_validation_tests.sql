-- New claims must pass the same identity rules when the UI is bypassed.
insert into auth.users (email, last_sign_in_at) values ('validation@village.example', now());
select tams_test.check('VALIDATION — resident account setup',
  tams_test.run_as('authenticated', tams_test.uid_of('validation@village.example'),
    'select public.resident_ensure_account()') = 'OK');

create function tams_test.submit_validation_claim(p_changes jsonb default '{}')
returns jsonb language sql volatile as $$
  select public.resident_submit_verification_request(
    tams_test.claim('0002290000000', 'Alice', 'Nkosi', '2000-02-29')
      || jsonb_build_object('gender', 'Female') || p_changes,
    jsonb_build_array(
      tams_test.document('certified_id_copy',
        tams_test.put_document(auth.uid(), 'validation-id.pdf', 100000)),
      tams_test.document('proof_of_residence',
        tams_test.put_document(auth.uid(), 'validation-proof.pdf', 100000))));
$$;

do $$
declare
  v_case record;
begin
  for v_case in select * from (values
    ('short ID', '{"id_number":"000229000000"}'::jsonb),
    ('long ID', '{"id_number":"00022900000000"}'::jsonb),
    ('letters in ID', '{"id_number":"000229000000x"}'::jsonb),
    ('spaces in ID', '{"id_number":"000229 000000"}'::jsonb),
    ('impossible ID date', '{"id_number":"0002300000000"}'::jsonb),
    ('mismatched birth date', '{"date_of_birth":"2000-03-01"}'::jsonb),
    ('future birth date', jsonb_build_object('date_of_birth', (current_date + 1)::text,
      'id_number', to_char(current_date + 1, 'YYMMDD') || '0000000')),
    ('two-letter first name', '{"first_name":"Al"}'::jsonb),
    ('padding is not a name', '{"first_name":"  Al  "}'::jsonb),
    ('digits in name', '{"first_name":"Alice123"}'::jsonb),
    ('two-letter surname', '{"last_name":"Li"}'::jsonb),
    ('short optional middle name', '{"middle_names":"Al"}'::jsonb),
    ('short optional previous surname', '{"previous_surname":"Li"}'::jsonb),
    ('short household head name', '{"household_head_name":"Al"}'::jsonb),
    ('unsupported gender', '{"gender":"Unknown"}'::jsonb),
    ('missing gender', '{"gender":""}'::jsonb)
  ) as cases(label, changes)
  loop
    perform tams_test.check('VALIDATION — rejects ' || v_case.label,
      tams_test.run_as('authenticated', tams_test.uid_of('validation@village.example'),
        format('select tams_test.submit_validation_claim(%L::jsonb)', v_case.changes)) = 'TV001');
  end loop;
end;
$$;

select tams_test.check('VALIDATION — rejected requests leave no application or attached documents',
  not exists (select 1 from public.resident_account_requests
    where user_account_id = tams_test.account_id_of('validation@village.example'))
  and not exists (select 1 from public.resident_request_documents d
    join public.resident_account_requests q on q.id = d.request_id
    where q.user_account_id = tams_test.account_id_of('validation@village.example')));

select tams_test.check('VALIDATION — accepts leap-day DOB, leading-zero ID, accented names and optional blank names',
  tams_test.run_as('authenticated', tams_test.uid_of('validation@village.example'),
    $sql$select tams_test.submit_validation_claim(
      '{"first_name":"  Zoë  ","last_name":"O’Neil","middle_names":"","previous_surname":""}'::jsonb)$sql$) = 'OK');

select tams_test.check('VALIDATION — stores normalized names and the exact 13-digit ID',
  (select first_name = 'Zoë' and last_name = 'O’Neil' and id_number = '0002290000000'
    and date_of_birth = date '2000-02-29' and gender = 'Female'
    and middle_names is null and previous_surname is null
   from public.resident_account_requests
   where user_account_id = tams_test.account_id_of('validation@village.example')));

select tams_test.check('VALIDATION — both documents accompany the valid claim',
  (select count(*) = 2 from public.resident_request_documents d
   join public.resident_account_requests q on q.id = d.request_id
   where q.user_account_id = tams_test.account_id_of('validation@village.example')));

select tams_test.check('VALIDATION — an identity edit cannot bypass validation',
  tams_test.try_sql($sql$update public.resident_account_requests set gender = 'Unknown'
    where user_account_id = tams_test.account_id_of('validation@village.example')$sql$) = 'TV001');
