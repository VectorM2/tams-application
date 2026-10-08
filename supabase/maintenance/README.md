# Administrator-only deployment

These scripts leave the active Council Administrator as the only usable TAMS
account. They do not delete accounts, Auth identities, residents, staff, land,
households or council records.

Run them in the Supabase SQL Editor in this order:

1. `preview_administrator_only.sql` — confirm that
   `active_council_administrators` is exactly `1` and inspect every planned
   account change.
2. `enable_administrator_only.sql` — deactivate every non-administrator
   account in one transaction and save the prior state in the private schema.
3. Run the preview again. The Council Administrator must be the only account
   whose status is not `deactivated`.

Also turn off **Allow new users to sign up** in **Supabase → Authentication →
Sign In / Providers → Email**. The web deployment must set
`VITE_RESIDENT_SELF_REGISTRATION=false`.

To undo the database part later, run `restore_administrator_only.sql`. It
restores the exact statuses and staff deactivation details saved by the latest
enable batch. Accounts that were already deactivated before the batch remain
deactivated.

