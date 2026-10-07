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
