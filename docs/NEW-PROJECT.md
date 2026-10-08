# Moving TAMS to a new Supabase project (with demo data)

The application code does not change. Only the project URL and the keys
it reads change. What matters is that the new database is built **from
the migrations in this repository**, not from a copy of the table list:
TAMS also depends on the SQL functions every page calls, Row Level
Security, the audit and land triggers, the four seeded roles and the
private document bucket. All of those are in `supabase/migrations/`, and
none of them is in a table-only schema dump.

About 20 minutes, done once, in this order.

## 1. Create the project and build the database

Create a project at <https://supabase.com/dashboard>, then from this folder:

```bash
npm install
npx supabase login
npx supabase link --project-ref <your-new-project-ref>
npm run db:push          # applies all 17 migrations
```

**Or, without the command line:** paste these into the Supabase **SQL
Editor** and run them one at a time, in order. They are the same 17
migrations, split into three parts so the editor accepts them:

1. `scripts/demo/00a_schema_part1.sql`
2. `scripts/demo/00b_schema_part2.sql`
3. `scripts/demo/00c_schema_part3.sql`

Use one way or the other, not both. If you built the schema in the SQL
Editor and later want `db:push` to work, mark the migrations as applied
first with `npx supabase migration repair --status applied <version>`
for each file in `supabase/migrations/`.

Do **not** run anything in `supabase/maintenance/` on the new project.
That folder is for locking an existing deployment down to the administrator only.

## 2. Edge functions (staff invitations and staff management)

```bash
npx supabase secrets set TAMS_SITE_URL=https://<your-tams-site>.netlify.app
npm run functions:deploy
```

## 3. Authentication settings

In the Supabase Dashboard:

* **Authentication → URL Configuration**
  * **Site URL**: `https://<your-tams-site>.netlify.app`
  * **Redirect URLs**: add `https://<your-tams-site>.netlify.app/set-password`,
    `https://<your-tams-site>.netlify.app/reset-password`, and the same two
    on `http://localhost:5173` for local use.
* **Authentication → Sign In / Providers → Email**
  * **Allow new users to sign up**: **on**. The Mhinga site's *Apply for
    land online* button sends residents to `/register`.
  * **Confirm email**: for a live demonstration, consider turning this
    **off**. Supabase's built-in email service only sends a few emails an
    hour, so a confirmation email can arrive late or not at all. With it
    off, a resident who registers can sign in straight away. Turn it back
    on for real use.

## 4. The two staff accounts

1. **Authentication → Users → Add user → Create new user**, twice, ticking
   **Auto Confirm User** each time:
   * `vectormediax@gmail.com`, which becomes the Council Administrator
   * `mathabelavector@gmail.com`, which becomes the Registry Clerk
2. Open `scripts/demo/01_create_accounts.sql`, set the names, employee
   numbers and phone numbers at the top, paste it into the **SQL Editor**
   and run it. It ends by listing both staff accounts.

The Council Administrator can then create the Land Officer and Council
Secretary from **Create staff account**. Those are sent invitation
emails, which go through step 2's edge function.

## 5. Demo data

**The village register.** About 145 residents in 32 households, with
family links, homes and the allocation of each home. Every person is
invented. ID numbers have the real South African format, so they pass
validation, but they belong to nobody. Run it from this folder, with the
service role key from **Project Settings → API**. Use it in this
terminal only, and never put it in `.env`:

```bash
npm run import:demo:dry-run      # checks the files, sends nothing

SUPABASE_URL=https://<your-new-project-ref>.supabase.co \
SUPABASE_SERVICE_ROLE_KEY=<service role key> \
npm run import:demo
```

The import only runs into an empty register. It refuses to run a second time.

**Free land and the council's record.** Paste
`scripts/demo/02_seed_demo_records.sql` into the SQL Editor and run it.
It adds:

* 15 sites ready to allocate: residential, farming, business and burial
* 3 council meetings, with attendance and final minutes
* 4 resolutions (3 public)
* 2 community projects with milestones

To regenerate the register with different people, run
`npm run demo:generate` before importing.

## 6. Point the website at the new project

On Netlify (TAMS site) → **Site configuration → Environment variables**:

| Variable | Value |
| --- | --- |
| `VITE_SUPABASE_URL` | `https://<your-new-project-ref>.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | the new project's `anon` key |
| `VITE_APP_URL` | `https://<your-tams-site>.netlify.app` |
| `VITE_RESIDENT_SELF_REGISTRATION` | `true` |

Then **Deploys → Trigger deploy**. Vite reads these at build time, so they
only take effect after a rebuild. For local use, put the same values in `.env`.

## 7. Check it

* Sign in as `vectormediax@gmail.com`. The dashboard shows two active staff.
* Sign in as `mathabelavector@gmail.com` → **Residents**. 145 residents appear.
  Search "Baloyi".
* Register a new resident from `/register`. They can sign in and send
  their verification details.
