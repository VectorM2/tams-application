# Resident verification form validation

The `/resident` verification form checks identity details before uploading any
documents. The same rules apply in the database to new verification claims.

- The South African ID number must contain exactly 13 digits. It remains text
  so leading zeroes are preserved.
- A complete ID fills the date of birth from its first six digits (`YYMMDD`).
  An incomplete ID clears the suggested date. Impossible dates are refused.
- Confirm the full birth year. The ID contains only two year digits, so the
  suggestion uses the most recent matching date that is not in the future.
  A different century is allowed when the date is real, not in the future,
  and still matches the ID.
- Gender is selected from Male and Female.
- First name, surname and the household head's name require at least three
  letters. Middle names and previous/maiden surname are optional; if entered,
  they require at least three letters too. Names can include accented letters,
  spaces, apostrophes and hyphens.
- The existing required contact, address and relationship fields must be filled.

The ID date format is documented in the Department of Basic Education's
[Activity 6.6](https://www.education.gov.za/LinkClick.aspx?fileticket=PIamIKz2ba8%3D&mid=10537&portalid=0&tabid=3137).

## Apply the change

1. Update the application to the revision containing this change. If using
   the downloadable patch instead, apply `tams-verification-validation.patch`
   from the project root using `git apply --check --ignore-space-change`
   followed by `git apply --ignore-space-change` with the patch path.
2. Run `npm run build` and `npm test`.
3. Apply the new migration
   `supabase/migrations/20261007180000_resident_verification_validation.sql`
   to the Supabase project through the SQL Editor, or your normal migration
   workflow. The database checks become active once that migration is applied.
4. Start the application with `npm run dev` and open the verification form.

The migration validates new requests and identity edits. Existing applications
can still be approved or declined, and no existing resident record is rewritten.

## Check the form

1. Submit an empty form: field errors appear and the first invalid field receives focus.
2. Enter `0002290000000`: the suggested date is `2000-02-29` and the leading
   zeroes remain in the ID field. This is a synthetic example for testing.
3. Replace it with `9001010000000`: the date becomes `1990-01-01`.
4. Remove a digit: the old date clears and submission is refused.
5. Try `0002300000000`: February 30 is rejected.
6. Change the birth date so it does not match the ID: submission is refused.
7. Enter `Al` or `Alice123` for a name: submission is refused.
8. Enter `Alice`, `Anne-Marie` or `Zoë`: the name passes validation.
9. Select Male or Female; leaving gender empty is refused.
10. Leave both optional name fields blank: they pass validation.
11. Fill the required fields and attach the two accepted documents: the request submits.

Focused TypeScript tests: `node --test tests/verification-validation.test.ts`.
The local database suite includes `13_verification_validation_tests.sql` and
can be run with `npm run test:db` where the documented PostgreSQL setup exists.
