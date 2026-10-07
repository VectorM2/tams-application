-- =====================================================================
-- TAMS — resident accounts, verification requests, approval, decline
-- and reapplying with the same account.
-- =====================================================================

-- Only this throwaway test fixture is updated; the supplied legacy CSV
-- package stays unchanged. New verification claims now need numeric IDs.
update public.residents set id_number = '9001010000022' where id_number = 'SYN0000000022';

-- ---- people applying for accounts -----------------------------------
insert into auth.users (email, last_sign_in_at) values
  ('applicant@village.example',  now()),
  ('applicant2@village.example', now()),
  ('nohousehold@village.example', now());

create function tams_test.applicant(p_email text default 'applicant@village.example')
returns uuid language sql stable as $$ select tams_test.uid_of(p_email); $$;

create function tams_test.account_id_of(p_email text)
returns uuid language sql stable security definer as $$
  select id from public.user_accounts where email = lower(p_email);
$$;

create function tams_test.account_status_of(p_email text)
returns text language sql stable security definer as $$
  select account_status from public.user_accounts where email = lower(p_email);
$$;

-- A document sitting in the applicant's own folder in the private bucket.
create function tams_test.put_document(p_uid uuid, p_file text, p_size bigint)
returns text language plpgsql volatile security definer as $$
declare v_path text := p_uid::text || '/' || p_file;
begin
  insert into storage.objects (bucket_id, name, owner, metadata)
  values ('resident-verification-documents', v_path, p_uid, jsonb_build_object('size', p_size))
  on conflict (bucket_id, name) do update set metadata = excluded.metadata;
  return v_path;
end; $$;

create function tams_test.document(p_type text, p_path text, p_mime text default 'application/pdf',
                                   p_size bigint default 100000)
returns jsonb language sql immutable as $$
  select jsonb_build_object('document_type', p_type, 'storage_path', p_path,
                            'file_name', 'document.pdf', 'mime_type', p_mime,
                            'file_size_bytes', p_size);
$$;

create function tams_test.claim(p_id_number text, p_first text, p_last text, p_dob text,
                                p_street text default '13 Marula Street',
                                p_head text default 'Samuel Rachidi')
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'first_name', p_first, 'last_name', p_last, 'id_number', p_id_number,
    'date_of_birth', p_dob, 'gender', 'Male', 'cellphone_number', '0730000001',
    'house_number', '13', 'street_address', p_street,
    'household_head_name', p_head, 'relationship_to_household_head', 'Son');
$$;


-- =====================================================================
-- REGISTRATION
-- =====================================================================

select tams_test.check(
  'REG 14 — signing up gives a resident an account of their own',
  tams_test.run_as('authenticated', tams_test.applicant(),
    'select public.resident_ensure_account()') = 'OK'
);

select tams_test.check(
  'REG 15/16/17 — it is a resident account, pending, linked to no resident',
  (select account_type = 'resident' and account_status = 'pending' and resident_id is null
     and staff_id is null
   from public.user_accounts where email = 'applicant@village.example')
);

select tams_test.check(
  'REG 18 — registering created nobody on the village register',
  (select count(*) = 0 from public.residents r
    where r.email = 'applicant@village.example')
);

select tams_test.check(
  'REG 19 — signing in again does not create a second account',
  tams_test.query_as('authenticated', tams_test.applicant(),
    $sql$select public.resident_ensure_account() ->> 'created'$sql$) = 'false'
);

select tams_test.check(
  'REG 19a — and there is still exactly one account for that email',
  (select count(*) = 1 from public.user_accounts where email = 'applicant@village.example')
);

select tams_test.check(
  'REG 20 — a staff email cannot be turned into a resident account this way',
  tams_test.run_as('authenticated', tams_test.uid_of('secretary@ta.example'),
    'select public.resident_ensure_account()') = 'OK'
  and (select account_type = 'staff' from public.user_accounts where email = 'secretary@ta.example')
);

select tams_test.check(
  'REG 20a — every staff account is still a staff account, linked to its staff record',
  (select count(*) > 0 from public.user_accounts where account_type = 'staff')
  and not exists (select 1 from public.user_accounts
                   where account_type = 'staff'
                     and (staff_id is null or resident_id is not null))
);

select tams_test.check(
  'REG 21 — a signed-out visitor cannot create an account',
  tams_test.run_as('authenticated', null,
    'select public.resident_ensure_account()') = '42501'
);


-- =====================================================================
-- DOCUMENTS AND SUBMISSION
-- =====================================================================

select tams_test.check(
  'DOC 21 — a request without a certified ID copy is refused',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(tams_test.document('proof_of_residence',
        tams_test.put_document(tams_test.applicant(), 'proof.pdf', 100000))))
  $sql$) = 'TA057'
);

select tams_test.check(
  'DOC 22 — a request without a proof of residence is refused',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(tams_test.document('certified_id_copy',
        tams_test.put_document(tams_test.applicant(), 'id.pdf', 100000))))
  $sql$) = 'TA057'
);

select tams_test.check(
  'DOC 23 — a document larger than 2 MB is refused',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant(), 'huge.pdf', 3000000)),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof.pdf', 100000))))
  $sql$) = 'TA058'
);

select tams_test.check(
  'DOC 23a — a small declared size cannot talk a large file through',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(
        -- claims 1 KB; the stored object is 3 MB
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant(), 'huge.pdf', 3000000), 'application/pdf', 1024),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof.pdf', 100000))))
  $sql$) = 'TA058'
);

select tams_test.check(
  'DOC 24 — a file type that is not PDF, JPG or PNG is refused',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant(), 'id.zip', 100000), 'application/zip'),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof.pdf', 100000))))
  $sql$) = 'TA058'
);

select tams_test.check(
  'DOC 26 — a document belonging to somebody else cannot be attached',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant('applicant2@village.example'), 'id.pdf', 100000)),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof.pdf', 100000))))
  $sql$) = 'TA059'
);

select tams_test.check(
  'DOC 25 — the bucket is private, with the size and types enforced by storage itself',
  (select not public and file_size_limit = 2097152
     and allowed_mime_types @> array['application/pdf', 'image/jpeg', 'image/png']
   from storage.buckets where id = 'resident-verification-documents')
);

select tams_test.check(
  'REQ 28 — a complete request is submitted',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant(), 'id.pdf', 100000)),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof.pdf', 150000))))
  $sql$) = 'OK'
);

select tams_test.check(
  'REQ 30 — what the applicant claimed was stored as given',
  (select q.first_name = 'Themba' and q.last_name = 'Ngwenya' and q.id_number = '9001010000022'
          and q.house_number = '13' and q.street_address = '13 Marula Street'
          and q.household_head_name = 'Samuel Rachidi'
          and q.relationship_to_household_head = 'Son'
          and q.request_status = 'pending'
   from public.resident_account_requests q
   join public.user_accounts ua on ua.id = q.user_account_id
   where ua.email = 'applicant@village.example')
);

select tams_test.check(
  'REQ 28a — both documents are attached to it',
  (select count(*) = 2 from public.resident_request_documents d
    join public.resident_account_requests q on q.id = d.request_id
    join public.user_accounts ua on ua.id = q.user_account_id
    where ua.email = 'applicant@village.example')
);

select tams_test.check(
  'REQ 31 — the applicant was never asked for a household or site code',
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'resident_account_requests'
      and column_name in ('household_code', 'household_id', 'site_code', 'residential_site_id'))
);

select tams_test.check(
  'REQ 29 — a second request while one is waiting is refused',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant(), 'id2.pdf', 100000)),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof2.pdf', 100000))))
  $sql$) = 'TA051'
);

select tams_test.check(
  'REQ 32 — an applicant cannot touch the review fields, or anything else',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    update public.resident_account_requests set request_status = 'approved'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    update public.user_accounts set account_status = 'active', resident_id = tams_test.resident_id_of('9001010000022')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    insert into public.resident_account_requests (user_account_id, first_name, last_name, id_number,
      date_of_birth, gender, cellphone_number, house_number, street_address,
      household_head_name, relationship_to_household_head)
    values (tams_test.account_id_of('applicant@village.example'), 'X', 'Y', 'Z',
            '1990-01-01', 'Male', '0730000000', '1', 'Somewhere', 'Someone', 'Son')
  $sql$) = '42501'
);

select tams_test.check(
  'DOC 26a — an applicant cannot read another applicant''s request or documents',
  tams_test.query_as('authenticated', tams_test.applicant('applicant2@village.example'),
    'select count(*)::text from public.resident_account_requests') = '0'
  and tams_test.query_as('authenticated', tams_test.applicant('applicant2@village.example'),
    'select count(*)::text from public.resident_request_documents') = '0'
);

select tams_test.check(
  'DOC 26b — but they can read their own',
  tams_test.query_as('authenticated', tams_test.applicant(),
    'select count(*)::text from public.resident_account_requests') = '1'
);

select tams_test.check(
  'DOC 26c — an applicant reaches only their own folder in the bucket',
  tams_test.query_as('authenticated', tams_test.applicant(),
    $sql$select count(*)::text from storage.objects
         where split_part(name, '/', 1) <> auth.uid()::text$sql$) = '0'
);

select tams_test.check(
  'DOC 27 — an active Registry Clerk can read the documents to review them',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from storage.objects
         where bucket_id = 'resident-verification-documents'$sql$)::int >= 2
  and tams_test.query_as('authenticated', tams_test.clerk(),
    'select count(*)::text from public.resident_request_documents') = '2'
);

select tams_test.check(
  'DOC 27a — other staff cannot read the documents at all',
  tams_test.query_as('authenticated', tams_test.uid_of('landofficer2@ta.example'),
    'select count(*)::text from public.resident_request_documents') = '0'
  and tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    $sql$select count(*)::text from storage.objects
         where bucket_id = 'resident-verification-documents'$sql$) = '0'
);


-- =====================================================================
-- THE REGISTRY CLERK'S REVIEW
-- =====================================================================

select tams_test.check(
  'APP 34 — the clerk sees the request waiting',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select full_name || ' / ' || id_number
         from public.registry_pending_resident_requests()$sql$) = 'Themba Ngwenya / 9001010000022'
);

select tams_test.check(
  'REQ 33 — no other staff role may see or decide these requests',
  tams_test.query_as('authenticated', tams_test.uid_of('landofficer2@ta.example'),
    'select count(*)::text from public.registry_pending_resident_requests()') = 'ERROR:42501'
  and tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    'select count(*)::text from public.registry_pending_resident_requests()') = 'ERROR:42501'
  and tams_test.run_as('authenticated', tams_test.uid_of('councilsec@ta.example'), $sql$
    select public.registry_approve_resident_request(
      (select id from public.resident_account_requests limit 1), tams_test.resident_id_of('9001010000022'))
  $sql$) = '42501'
);

select tams_test.check(
  'APP 35 — the resident whose identity number matches exactly is suggested first',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select id_number || ' (' || match_reason || ')'
    from public.registry_resident_candidates(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1))
    order by match_rank limit 1
  $sql$) = '9001010000022 (Identity number matches exactly)'
);

select tams_test.check(
  'APP 36 — the clerk can also search the register by hand',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.registry_search_residents('9001010000022')$sql$) = '1'
);

select tams_test.check(
  'APP 37 — approving without a real resident record is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_approve_resident_request(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1),
      '00000000-0000-0000-0000-000000000000'::uuid)
  $sql$) = 'TA031'
);

select tams_test.check(
  'APP 38 — a resident who is not active cannot be given an account',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_approve_resident_request(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1),
      tams_test.resident_id_of('SYN0000000058'))
  $sql$) = 'TA053'
);

-- Someone on the register who has not been linked to a household yet.
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_create_resident('SYN0000000950', 'Homeless', 'Record', '1980-01-01', 'Male', 'active')
$sql$);

select tams_test.check(
  'APP 39 — a resident with no household cannot be given an account yet',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_approve_resident_request(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1),
      tams_test.resident_id_of('SYN0000000950'))
  $sql$) = 'TA054'
);

select tams_test.check(
  'APP 39a — and the request is still waiting, not half-decided',
  (select count(*) = 1 from public.resident_account_requests where request_status = 'pending')
  and (select account_status = 'pending' from public.user_accounts where email = 'applicant@village.example')
);


-- =====================================================================
-- DECLINE, THEN REAPPLY WITH THE SAME ACCOUNT
-- =====================================================================

select tams_test.check(
  'DEC 45 — declining without a reason is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_decline_resident_request(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1), '   ')
  $sql$) = 'TA018'
);

select tams_test.check(
  'DEC 45a — the request is declined, with the reason given',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_decline_resident_request(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1),
      'Proof of residence could not be verified')
  $sql$) = 'OK'
);

select tams_test.check(
  'DEC 46/47 — the account is declined and still linked to no resident',
  (select account_status = 'declined' and resident_id is null
   from public.user_accounts where email = 'applicant@village.example')
);

select tams_test.check(
  'DEC 48/49 — the sign-in, the request and the documents all remain',
  (select count(*) = 1 from auth.users where email = 'applicant@village.example')
  and (select count(*) = 1 from public.resident_account_requests q
        join public.user_accounts ua on ua.id = q.user_account_id
        where ua.email = 'applicant@village.example' and q.request_status = 'declined')
  and (select count(*) = 2 from public.resident_request_documents d
        join public.resident_account_requests q on q.id = d.request_id
        join public.user_accounts ua on ua.id = q.user_account_id
        where ua.email = 'applicant@village.example')
);

select tams_test.check(
  'DEC 50/51 — they can still sign in, and are told why they were declined',
  tams_test.query_as('authenticated', tams_test.applicant(), $sql$
    select (public.resident_portal() ->> 'account_status') || ' :: ' ||
           (public.resident_portal() -> 'latest_request' ->> 'decline_reason')
  $sql$) = 'declined :: Proof of residence could not be verified'
);

select tams_test.check(
  'DEC 51a — and they are allowed to try again',
  tams_test.query_as('authenticated', tams_test.applicant(),
    $sql$select public.resident_portal() ->> 'may_submit'$sql$) = 'true'
);

select tams_test.check(
  'REA 52 — reapplying creates a new request, with corrected details',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01',
                      '31 Sekhukhune Street', 'Zanele Ndlovu'),
      jsonb_build_array(
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant(), 'id-again.pdf', 120000)),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof-again.pdf', 130000))))
  $sql$) = 'OK'
);

select tams_test.check(
  'REA 53 — the declined attempt is exactly as it was',
  (select count(*) = 1 from public.resident_account_requests q
    join public.user_accounts ua on ua.id = q.user_account_id
    where ua.email = 'applicant@village.example'
      and q.request_status = 'declined'
      and q.decline_reason = 'Proof of residence could not be verified'
      and q.street_address = '13 Marula Street')
);

select tams_test.check(
  'REA 52a — there are now two attempts on record, one of them waiting',
  (select count(*) = 2 from public.resident_account_requests q
    join public.user_accounts ua on ua.id = q.user_account_id
    where ua.email = 'applicant@village.example')
  and (select count(*) = 1 from public.resident_account_requests q
        join public.user_accounts ua on ua.id = q.user_account_id
        where ua.email = 'applicant@village.example' and q.request_status = 'pending')
);

select tams_test.check(
  'REA 54/55 — the same account and the same sign-in were reused',
  (select count(*) = 1 from public.user_accounts where email = 'applicant@village.example')
  and (select count(*) = 1 from auth.users where email = 'applicant@village.example')
);

select tams_test.check(
  'REA 56 — submitting again put the account back to pending',
  tams_test.account_status_of('applicant@village.example') = 'pending'
);

select tams_test.check(
  'REA 57 — and a third request, while that one waits, is refused',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant(), 'id3.pdf', 100000)),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof3.pdf', 100000))))
  $sql$) = 'TA051'
);

select tams_test.check(
  'REA 23 — the clerk can see the earlier attempt alongside this one',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select jsonb_array_length(public.registry_resident_request(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1))
      -> 'earlier_attempts')::text
  $sql$) = '1'
);


-- =====================================================================
-- APPROVAL
-- =====================================================================

create table tams_test.resident_before_approval as
  select * from public.residents where id_number = '9001010000022';

select tams_test.check(
  'APP 58 — the clerk approves, matching them to the official record',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_approve_resident_request(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1),
      tams_test.resident_id_of('9001010000022'))
  $sql$) = 'OK'
);

select tams_test.check(
  'APP 41/42 — the account is linked to that resident and is now active',
  (select resident_id = tams_test.resident_id_of('9001010000022') and account_status = 'active'
   from public.user_accounts where email = 'applicant@village.example')
);

select tams_test.check(
  'APP 43 — the request is approved, and records who decided it and when',
  (select q.request_status = 'approved'
          and q.matched_resident_id = tams_test.resident_id_of('9001010000022')
          and q.reviewed_by_staff_id = tams_test.staff_id_of('2026070')
          and q.reviewed_at is not null
   from public.resident_account_requests q
   join public.user_accounts ua on ua.id = q.user_account_id
   where ua.email = 'applicant@village.example' and q.request_status = 'approved')
);

select tams_test.check(
  'APP 44 — nothing the applicant typed was written into the official record',
  (select count(*) = 1
   from public.residents r, tams_test.resident_before_approval b
   where r.id = b.id
     and r.id_number = b.id_number and r.first_name = b.first_name
     and r.last_name = b.last_name and r.date_of_birth = b.date_of_birth
     and r.gender = b.gender and r.household_id is not distinct from b.household_id
     and r.contact_number is not distinct from b.contact_number
     and r.email is not distinct from b.email)
);

-- The applicant claimed to be "Themba Ngwenya"; the official record for
-- the identity number they gave is Zanele Ndlovu. The clerk matched
-- them to that record, and it is the OFFICIAL name the portal shows —
-- the claimed one was never treated as fact.
select tams_test.check(
  'APP 58a — the approved resident sees the official record, not what they typed',
  tams_test.query_as('authenticated', tams_test.applicant(), $sql$
    select (public.resident_portal() ->> 'account_status') || ' :: ' ||
           (public.resident_portal() -> 'resident' ->> 'full_name')
  $sql$) = 'active :: ' || (select first_name || ' ' || last_name
                            from public.residents where id_number = '9001010000022')
  and (select first_name <> 'Themba' from public.residents where id_number = '9001010000022')
);

select tams_test.check(
  'APP 58b — an approved account cannot submit another request',
  tams_test.run_as('authenticated', tams_test.applicant(), $sql$
    select public.resident_submit_verification_request(
      tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
      jsonb_build_array(
        tams_test.document('certified_id_copy',
          tams_test.put_document(tams_test.applicant(), 'id4.pdf', 100000)),
        tams_test.document('proof_of_residence',
          tams_test.put_document(tams_test.applicant(), 'proof4.pdf', 100000))))
  $sql$) = 'TA051'
);

select tams_test.check(
  'APP 43a — an already decided request cannot be decided again',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_decline_resident_request(
      (select id from public.resident_account_requests where request_status = 'approved' limit 1),
      'Changed my mind')
  $sql$) = 'TA052'
);

-- ---- a second applicant, for the already-linked rule ----------------

select tams_test.run_as('authenticated', tams_test.applicant('applicant2@village.example'),
  'select public.resident_ensure_account()');

select tams_test.run_as('authenticated', tams_test.applicant('applicant2@village.example'), $sql$
  select public.resident_submit_verification_request(
    tams_test.claim('9001010000022', 'Themba', 'Ngwenya', '1990-01-01'),
    jsonb_build_array(
      tams_test.document('certified_id_copy',
        tams_test.put_document(tams_test.applicant('applicant2@village.example'), 'id.pdf', 100000)),
      tams_test.document('proof_of_residence',
        tams_test.put_document(tams_test.applicant('applicant2@village.example'), 'proof.pdf', 100000))))
$sql$);

select tams_test.check(
  'APP 40 — a resident who already has an account cannot be given a second one',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_approve_resident_request(
      (select id from public.resident_account_requests where request_status = 'pending' limit 1),
      tams_test.resident_id_of('9001010000022'))
  $sql$) = 'TA055'
);

select tams_test.check(
  'APP 40a — the database would refuse it even if that check were missed',
  tams_test.run_as('service_role', null, $sql$
    update public.user_accounts set resident_id = tams_test.resident_id_of('9001010000022')
    where email = 'applicant2@village.example'
  $sql$) = '23505'
);

select tams_test.check(
  'APP 40b — the second applicant is still waiting, unlinked',
  (select account_status = 'pending' and resident_id is null
   from public.user_accounts where email = 'applicant2@village.example')
);
