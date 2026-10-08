# Setting TAMS up

Everything below is done once, in order. It takes about fifteen minutes.

## 1. A Supabase project

Create a project at <https://supabase.com/dashboard>, then note from
**Project Settings → API**:

| Value | Where it goes |
| --- | --- |
| Project URL | `.env` as `VITE_SUPABASE_URL` |
| `anon` public key | `.env` as `VITE_SUPABASE_ANON_KEY` |
| `service_role` secret key | **nowhere in this repository** — Supabase gives it to the edge functions automatically |

```bash
cp .env.example .env     # then fill in the two values
npm install
```

## 2. The database

```bash
npx supabase link --project-ref <your-project-ref>
npm run db:push
```

That applies every migration:

* `20260919090000_tams_foundation.sql` — the three tables, the four
  seeded roles, and Row Level Security.
* `20260920100000_staff_role_and_status_management.sql` — the columns
  recording who deactivated or reactivated an account, when and why,
  and the three staff management functions.
* `20260921090000_village_records.sql` — the village's own records
  (land sites, residents, households, family relationships, land
  allocations) and the one-time legacy import.
* `20260922090000_registry_clerk.sql` — the Registry Clerk's read
  access and the functions behind every change they make.
* `20260923090000_relationship_history.sql` — when a relationship began
  and ended, and the change from one relationship per pair to one
  *current* relationship per pair.
* `20260924090000_resident_accounts.sql` — resident accounts,
  verification requests, their documents, and the private storage
  bucket the documents live in.
* `20260925090000_land_model.sql` — the land model: grazing removed as a
  kind of land TAMS allocates (existing grazing rows, if any, are kept
  as legacy records and never deleted), land applications, the extended
  land allocations, permissions to occupy, renewal requests, and the
  unique indexes that make the allocation limits impossible to break.
* `20260926090000_land_functions.sql` — eligibility, the resident's land
  portal, and every Land Officer function: sites, applications,
  allocation, issuing, renewal, revocation, release, burial status,
  succession, and the public verification of a permission.
* `20260927090000_council_records.sql` — the council's own record:
  meetings, attendance, minutes, amendments to final minutes,
  resolutions, projects, milestones, and the history of every change of
  visibility.
* `20260928090000_council_functions.sql` — Council Secretary
  authorisation, every function behind those records, the narrow read
  policies, and the resident's Community Updates.
* `20260929090000_notifications.sql` — one notification system for the
  whole application, the email delivery queue beside it, the expiry
  warnings for permissions that have a term, and the triggers that tell
  people what has happened to them.
* `20260930090000_audit_trail.sql` — the insert-only audit trail, the
  triggers that write it, and the Council Administrator's way of reading
  it.
* `20261001090000_communications.sql` — official notices to residents,
  internal staff messaging and work requests.
* `20261002090000_administrator_transfer.sql` — Administrator Transfer,
  emergency recovery, and the single-active-administrator rule.
* `20261003090000_password_reset_audit.sql` — the one safe line a
  completed password reset leaves in the audit trail.
* `20261004090000_final_hardening.sql` — the final security pass: the
  trigger functions' EXECUTE revoked from PUBLIC, and the two
  hand-written audit events corrected so each reads as a real before
  and after.

If a page reports that a function is "not found in the schema cache", a
migration has not reached the project yet — run
`scripts/check-registry-functions.sql` in the SQL Editor to see which.

`db:push` applies only the migrations your project has not seen yet.

Once the database is up, the village's existing records are loaded with
a one-time command — see [LEGACY-IMPORT.md](LEGACY-IMPORT.md).

## 3. Sign-in settings

For an **administrator-only deployment**, open **Authentication → Sign
In / Providers → Email** and turn **Allow new users to sign up** off.
Only existing Auth identities can then sign in. Keep
`VITE_RESIDENT_SELF_REGISTRATION=false` on the deployed front end.

If the resident portal is opened later, turn **Allow new users to sign
up** on, turn **Confirm email** on, and set
`VITE_RESIDENT_SELF_REGISTRATION=true`. Residents then create their own
sign-ins and confirm their address; that only ever produces a resident
account, pending verification, with no access to anything. Staff
accounts are still created solely by the Council Administrator's
invitation, and nothing a member of the public can do produces one.

In **Authentication → URL Configuration**, set the **Site URL** to where
the app runs (`http://localhost:5173` while developing) and add **both**
of these to the **Redirect URLs**:

| Redirect URL | What lands there |
| --- | --- |
| `<site-url>/set-password` | a staff invitation |
| `<site-url>/reset-password` | a password reset |

While developing that means `http://localhost:5173/set-password` and
`http://localhost:5173/reset-password`. Add the deployed equivalents
when you deploy, and leave the localhost ones in place so development
keeps working. If a URL is not listed here, Supabase refuses to send
anybody back to it and the link fails.

### Email delivery — set this up before creating any staff

**Staff creation fails without it.** Supabase's built-in email service is
for demonstration only: it is heavily rate limited and it refuses
addresses that do not belong to your own Supabase team. Inviting anyone
else comes back as:

> The invitation email could not be sent, so no staff account was
> created.

Nothing is created when that happens, so it is safe to fix the mail
settings and create the account again.

Set up your own SMTP server under **Project Settings → Authentication →
SMTP Settings**. Any provider works. Two that need no domain of your own:

**Brevo** (300 emails a day, free) — sign up, verify the sender address
you want mail to come from (your own Gmail address is fine), then under
**SMTP & API → SMTP** take:

| Field | Value |
| --- | --- |
| Host | `smtp-relay.brevo.com` |
| Port | `587` |
| Username | the login Brevo shows you |
| Password | the SMTP key Brevo generates |
| Sender email | the address you verified |
| Sender name | e.g. `TAMS` |

**Gmail** — in your Google account, turn on 2-Step Verification, create an
**App password**, then use host `smtp.gmail.com`, port `465`, your Gmail
address as the username, and the 16-character app password as the
password. Fine for a handful of staff; use a real provider for more.

Afterwards, raise the invite allowance under **Authentication → Rate
Limits** if you plan to create several accounts in one sitting.

Add `<site-url>/resident` to the **Redirect URLs** as well: that is
where a resident's confirmation email returns them.

Invitation links land on `/set-password`, a route inside the app. When
you host TAMS somewhere, make sure unknown paths serve `index.html`
(Netlify `_redirects`, Vercel rewrites, or `try_files` on nginx) or that
link will 404. `npm run dev` already does this.

## 3b. Email, the worker and the recovery secret

Three things have to be set on the server before email leaves TAMS.
**None of them is ever referenced from `src/`, and none reaches the
browser.**

1. **An email provider.** Brevo's free tier is enough. Create an account,
   verify your sending address, and make an API key.

2. **The secrets**, set from the project folder:

```bash
npx supabase secrets set BREVO_API_KEY=your-brevo-api-key
npx supabase secrets set TAMS_EMAIL_FROM=no-reply@your-domain.example
npx supabase secrets set TAMS_EMAIL_FROM_NAME="TAMS"
npx supabase secrets set TAMS_APP_URL=https://your-tams-address.example
npx supabase secrets set TAMS_WORKER_SECRET="$(openssl rand -hex 32)"
npx supabase secrets set TAMS_ADMIN_RECOVERY_SECRET="$(openssl rand -hex 32)"
```

   Keep the last two somewhere safe and out of the repository. The worker
   refuses every request until `TAMS_WORKER_SECRET` is set, and emergency
   recovery is off entirely until `TAMS_ADMIN_RECOVERY_SECRET` is.

3. **A schedule for the worker.** In the Supabase Dashboard, open
   **Integrations → Cron** (or **Database → Extensions** and enable
   `pg_cron` and `pg_net`), then add a job that runs every five minutes:

Fill in your own project reference, anon key and worker secret where the
placeholders are. Run this in the SQL Editor, where nothing is written to
a file — never commit the finished statement.

```sql
select cron.schedule(
  'tams-notification-emails', '*/5 * * * *',
  $$
  select net.http_post(
    url     := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/process-notification-emails',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer YOUR-SUPABASE-ANON-KEY',
                 'x-worker-secret', 'YOUR-TAMS-WORKER-SECRET'),
    body    := '{"limit": 50}'::jsonb);
  $$);
```

   And a daily one for the expiry warnings:

```sql
select cron.schedule(
  'tams-pto-expiry-warnings', '0 6 * * *',
  $$ select public.queue_pto_expiry_warnings(); $$);
```

   Running either more often than that is harmless: the worker never
   sends a delivery twice, and each permission receives each threshold
   exactly once.

## 4. The edge functions

```bash
npx supabase secrets set TAMS_SITE_URL="http://localhost:5173"
npx supabase secrets set TAMS_BOOTSTRAP_SECRET="$(openssl rand -hex 32)"
npm run functions:deploy
```

`TAMS_SITE_URL` is the address invitation links come back to.
`TAMS_BOOTSTRAP_SECRET` is used once, in the next step.

`npm run functions:deploy` deploys all five: the three that were already
there, plus `process-notification-emails` (the email worker) and
`emergency-admin-recovery`. Neither of the new two is reachable from any
page in the application, and both require a secret only you hold.

## 5. The first Council Administrator

There is no registration page for this, by design. Two steps:

**a. Create the sign-in user by hand.** Dashboard →
**Authentication → Users → Add user**: their email address, a password
you give them, and **Auto Confirm User** ticked.

**b. Run the bootstrap once:**

```bash
export SUPABASE_URL="https://<your-ref>.supabase.co"
export SUPABASE_ANON_KEY="<anon key>"
export TAMS_BOOTSTRAP_SECRET="<the same secret you set above>"

./scripts/bootstrap-administrator.sh 2026011 Nature Khosa admin@example.com 0728217377
```

This creates their staff record with the Council Administrator role and
their active user account, in one transaction. Run it again and it
refuses: a Council Administrator already exists.

**c. Shut the door:**

```bash
npx supabase secrets unset TAMS_BOOTSTRAP_SECRET
```

## 6. Run it

```bash
npm run dev
```

Sign in at <http://localhost:5173> with the administrator's email and the
password you set in step 5a.

---

## Checking it end to end

These are the checks to run against your own project once it is set up.
The parts that can be tested without a Supabase project are automated —
see [TESTING.md](TESTING.md) — and `npm run test:all` runs them.

| # | Check | Expected |
| --- | --- | --- |
| 1 | Run the bootstrap (step 5) | Staff record + active account, role Council Administrator |
| 2 | Run the bootstrap a second time | Refused: "A Council Administrator already exists" |
| 3 | Sign in as the administrator | Lands on the dashboard |
| 4 | Create a Registry Clerk | "An invitation has been emailed to …" |
| 5 | Open the invitation email | Lands on `/set-password` |
| 6 | Set a password under 8 characters | Refused |
| 7 | Set two passwords that differ | Refused |
| 8 | Set a valid password | "Your account is ready" |
| 9 | Sign in as the Registry Clerk | Lands on their account page with name, employee number, email, role, status |
| 10 | Repeat 4–9 for a Land Officer and a Council Secretary | Same |
| 11 | Create staff with an employee number already in use | Refused on that field; no invitation sent |
| 12 | Create staff with an email already in use | Refused on that field; no invitation sent |
| 13 | As a Registry Clerk, open `/staff/new` | Sent back to their own account page |
| 14 | As a Registry Clerk, POST to the `create-staff-account` function | `403` |
| 15 | Set someone's `account_status` to `deactivated`, then sign in as them | "Your staff account has been deactivated" |

### Checking staff management

| # | Check | Expected |
| --- | --- | --- |
| 16 | As the administrator, open Staff accounts | Active staff show **Change role** and **Deactivate**; deactivated staff show **Reactivate**; your own row shows "Managed separately" |
| 17 | Change a Registry Clerk to Land Officer | Saved; the row shows the new role at once |
| 18 | Change them to the role they already hold | "That staff member already holds the role you chose" |
| 19 | Sign in as that staff member | Their account page shows the **new** role |
| 20 | Deactivate a staff member without a reason | Refused; the reason is required |
| 21 | Deactivate them with a reason | Row shows **Deactivated**, the date and the reason; their role is unchanged |
| 22 | While they are signed in elsewhere, deactivate them | Within a minute — or the moment they return to the tab — they are sent to "Your staff account has been deactivated" |
| 23 | Try to sign in as them | They reach the same refusal, not the system |
| 24 | Reactivate them with a reason | Row shows **Active** again; same employee number, email and role |
| 25 | Sign in as them again | Same password as before; their account page works |
| 26 | As an ordinary staff member, call the function by hand (below) | `403` |

For 26, from a signed-in Registry Clerk's browser console:

```js
const { data: { session } } = await supabase.auth.getSession();
await fetch(`${SUPABASE_URL}/functions/v1/manage-staff-account`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    apikey: ANON_KEY,
    Authorization: `Bearer ${session.access_token}`,
  },
  body: JSON.stringify({ action: "deactivate", staff_id: "<any staff id>", reason: "test" }),
}).then((response) => response.status);   // 403
```

The same request with `action: "change_role"` and the Council
Administrator's role id is refused too, as is any attempt to act on the
Council Administrator's own account.

### Checking resident accounts end to end

| # | Check | Expected |
| --- | --- | --- |
| 27 | Register at `/register` with a new email | "Check your email"; a confirmation arrives |
| 28 | Confirm, then sign in | The resident portal, status **Pending**, nothing else reachable |
| 29 | Look for the person in Supabase → residents | Nothing was added to the register |
| 30 | Register again with the same email | "An account with this email may already exist" — no second account |
| 31 | Send verification with a 3 MB file | Refused before anything is submitted |
| 32 | Send verification with a .docx | Refused |
| 33 | Send valid details and both documents | Status stays **Pending**, now showing the submitted date |
| 34 | Try to send a second request | Refused: one is already waiting |
| 35 | As Registry Clerk, open **Resident accounts** | The application is listed |
| 36 | Open it | Claimed details on the left, likely matches on the right, both documents with **View** |
| 37 | Click **View** on a document | Opens; the link stops working after two minutes |
| 38 | Approve against a resident with no household | Refused, telling you to link the household first |
| 39 | Approve against a valid resident | Account becomes **Active** and linked |
| 40 | Check that resident's record on the register | Unchanged — nothing the applicant typed was copied in |
| 41 | Decline another application without a reason | Refused |
| 42 | Decline with a reason | Applicant's account becomes **Declined** |
| 43 | Sign in as the declined applicant | Sees the reason and an **Apply again** button |
| 44 | Apply again with corrected details | New request created; the declined one still on record; same account, same sign-in |
| 45 | As a Land Officer, open `/registry/resident-accounts` | Sent away; the API returns `403` |

### Checking relationship history

| # | Check | Expected |
| --- | --- | --- |
| 46 | Open a resident's family lineage | Three sections: lineage, current, former |
| 47 | Look at a parent or sibling | No **End** button — lineage is permanent |
| 48 | Record a spouse without a date | Refused; a start date is required |
| 49 | Record a spouse with a start date, then **End** it | Moves to **Former spouse**, with both dates, on both people |
| 50 | Record the same spouse again with a later date | A second episode; the first stays under Former |

### Checking land end to end

Sign in as a **Land Officer** for 51–62, and as a verified **resident**
for the rest.

| # | Check | Expected |
| --- | --- | --- |
| 51 | Open `/land` | The Land Officer dashboard, with counts |
| 52 | **Land sites** → **Register a site** | Only residential, farming, business and burial are offered — no grazing |
| 53 | Register `RES-9001` as residential | Listed as **available** |
| 54 | Register `RES-9001` again | Refused: the site code is already in use |
| 55 | As a resident, apply for residential land | No site picker anywhere; no document upload |
| 56 | Apply again for residential land | Refused: an application is already open |
| 57 | As the officer, open the application | The applicant, household, land already held, and the eligibility check |
| 58 | **Decline** with no reason | Refused |
| 59 | **Approve**, then allocate `RES-9001` | Site becomes **allocated**, application **allocated** |
| 60 | **Issue the permission** | A PTO number; expiry shows **Perpetual** |
| 61 | Open the document, print preview | The certificate only — no buttons, no navigation |
| 62 | Scan the QR code with a phone | The public page, showing valid — and no identity number or birth date |
| 63 | Open `/verify/pto/<wrong-token>` signed out | "No permission to occupy matches this code" |
| 64 | As the resident, look at **My permissions** | The residential PTO, with no **Renew** button |
| 65 | Repeat 55–60 for **business** land | Expiry is exactly two years from today |
| 66 | As the resident, **Renew** the business PTO | Sent; a second request is refused |
| 67 | As the officer, **Renewals** → **Approve** | A *new* PTO number; the old one now reads **renewed** |
| 68 | As a Registry Clerk, open `/land` | Sent away; the API returns `403` |
| 69 | As a resident, open `/land/applications` | Sent away; the API returns `403` |

### Checking the Council Secretary end to end

Sign in as a **Council Secretary** for 70–86, and as a verified
**resident** for 87–91.

| # | Check | Expected |
| --- | --- | --- |
| 70 | Sign in as the Council Secretary | You land on `/secretary`; the navigation shows Dashboard, Meetings, Resolutions, Projects |
| 71 | **Meetings** → **Schedule a meeting** | Only ordinary, special and emergency are offered |
| 72 | Leave the agenda blank and try to save | The button stays disabled — every field is required |
| 73 | Schedule an *ordinary* meeting for today | Listed as **scheduled**, with an `MTG-<year>-0001` style reference you did not type |
| 74 | Open it → **Record as held** | Status becomes **held** |
| 75 | Add three attendees — a Chief, a Headman, a guest | All three saved; **none of them needed an account** |
| 76 | Type minutes → **Save draft** | Saved; the dashboard still counts it under *awaiting minutes* |
| 77 | Reload, edit the draft, save again | The later wording is kept |
| 78 | **Finalise minutes** → confirm | Green banner naming you and the moment; the text box is gone |
| 79 | Try to edit the minutes again | There is no way to; the attendance list now says **Closed** |
| 80 | **Record an amendment** with a blank reason | The button stays disabled |
| 81 | Record an amendment with both fields | `AMD-<year>-0001` appears beneath the minutes; the minutes above are unchanged |
| 82 | **Record a resolution**, visibility **public** | `RES-<year>-0001`, decided on the meeting's own date — you never typed a date |
| 83 | Record a second resolution, **internal** | Both listed against this meeting |
| 84 | **Withdraw** the internal one with no reason | Refused; with a reason it is kept, marked withdrawn |
| 85 | **Projects** → **Create a project**, target date *before* the start date | Refused |
| 86 | Create a public project with a start date a month ago, link the public resolution, then add three milestones — one due last week, one due next week | The past one shows **Overdue** with no action from you; the dashboard's overdue count goes up |
| 87 | Sign in as a verified resident | The portal, with **Community updates** below your land |
| 88 | Look at Council resolutions | Only `RES-<year>-0001` — the public one from confirmed minutes |
| 89 | Look at Community projects | The public project, with ✓ / • / ! against its milestones and **Overdue** on the right one |
| 90 | Confirm what is **missing** | No attendance, no minutes (draft or final), no internal resolution, no internal project |
| 91 | Type `/secretary` into the address bar as the resident | Bounced back to `/resident`; the API returns `403` |
| 92 | As a Registry Clerk or Land Officer, open `/secretary` | Bounced to their own area |

### Checking notifications, messaging, the audit trail and the transfer

| # | Check | Expected |
| --- | --- | --- |
| 93 | Sign in as any role | A bell in the header, and **Notifications** in the navigation |
| 94 | As a Land Officer, approve a resident's land application | That resident's bell shows one more unread |
| 95 | Sign in as that resident → **Notifications** | The approval, with its reference; **Mark all as read** empties the count |
| 96 | **Archive** one, then open the **Archived** tab | It is there; **Everything** still shows it. Nothing was deleted |
| 97 | As the Council Secretary, **Communications → Send a notice**, a **Summons** to one resident with a date, time, venue and *Chief* | Sent; the list shows one recipient |
| 98 | Sign in as that resident | The summons is in their notifications, with the date, time, venue and capacity |
| 99 | Sign in as a different resident | They do not have it |
| 100 | Send a **Community announcement** to all active residents | Every active resident receives it; the recipient count matches |
| 101 | Verify a new resident afterwards, then sign in as them | They do **not** have the earlier announcement |
| 102 | As a Land Officer, **Messages → Compose**, direct to the Registry Clerk, kind **Action required**, linked to a household | Sent, and it appears in the clerk's inbox marked *Action required* |
| 103 | As the Registry Clerk, open it → **Acknowledge and take it on** → **Mark resolved** | Both recorded with your name and the time; the sender is notified of each |
| 104 | As a third staff member, open that message's address directly | Refused — it is not theirs |
| 105 | Compose a **role** work request to Council Secretary with two active secretaries | Both receive it; the first to acknowledge claims it, the second is told who has it and cannot resolve it |
| 106 | As the Council Administrator, **Audit trail** | Every change, newest first |
| 107 | Filter by **Action = PTO revoked** and open one | Old beside new: `pto_status` *active* → *revoked*, with the reason |
| 108 | Look for a password, a token or a document path anywhere in it | There are none, ever |
| 109 | **Export this view as CSV** | Exactly the rows on screen |
| 110 | As a Registry Clerk, open `/admin/audit` | Bounced to their own dashboard; the API returns `403` |
| 111 | **Transfer administrator** → choose a staff member, choose what becomes of you, give a reason, type **TRANSFER** | Done; you are no longer the administrator and they are, immediately |
| 112 | Sign in as the new administrator → **Audit trail** | The transfer is recorded with the outgoing and incoming names, the outcome and the reason |

### If the invitation email fails

The message says no staff account was created, and none was: the staff
record and user account are only written after the invitation has been
accepted for delivery. Fix the SMTP settings above and create the
account again with the same details.

One thing to check afterwards: if the second attempt says *"That email
address already has a sign-in account"*, a sign-in user was left behind
by the failed attempt. Remove it under **Authentication → Users**, then
create the staff account again.

For 14, from a signed-in Registry Clerk's browser console:

```js
const { data: { session } } = await supabase.auth.getSession();
await fetch(`${SUPABASE_URL}/functions/v1/create-staff-account`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    apikey: ANON_KEY,
    Authorization: `Bearer ${session.access_token}`,
  },
  body: JSON.stringify({
    employee_number: "9999", first_name: "Not", last_name: "Allowed",
    email: "not-allowed@example.com", contact_number: "0728217377",
    role_id: "<any role id>",
  }),
}).then((response) => response.status);   // 403
```
