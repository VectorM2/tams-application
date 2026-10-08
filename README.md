# TAMS — Traditional Authority Management System

Built with React, Vite, Supabase (PostgreSQL, Supabase Auth and Row Level
Security).

The foundation, the Council Administrator's staff management, the
Registry Clerk's register, resident accounts, and the Land Officer's
land, allocations and permissions to occupy, the Council Secretary's
meetings, minutes, resolutions and community projects, the immutable
audit trail, and handing the administrator role over.

## What works today

| | |
| --- | --- |
| **First Council Administrator** | A one-time, secret-guarded server process. No registration page exists. |
| **Sign in** | One page for every role, checked against the database record, not the browser. |
| **Create Staff Account** | The Council Administrator invites a Registry Clerk, Land Officer or Council Secretary. |
| **Invitation** | The new staff member gets an email and chooses their own password. |
| **Forgot password** | Residents and every staff role reset a forgotten password through Supabase Auth. |
| **Staff sign-in** | All three roles can sign in and see their own account page. |
| **Change staff role** | The Council Administrator moves a staff member to a different one of the three ordinary roles. |
| **Deactivate / reactivate** | Access is withdrawn and given back, with a reason, without deleting anything. |
| **Legacy village import** | A one-time command loads the village's existing sites, residents, households, family relationships and land allocations. |
| **Registry Clerk** | Search and view the register, create and update residents, create households, link residents, designate heads, and record family relationships. |
| **Relationship history** | Lineage is permanent; marriages and guardianships begin, end and may begin again, each episode kept. |
| **Resident accounts** | Residents register, send documents to be verified, and are matched by a Registry Clerk to a record already on the register. |
| **Land applications** | A verified resident applies for residential, farming, business or burial land. They never choose a site. |
| **Land Officer** | Registers sites, reviews applications, allocates a site, issues the permission to occupy, and handles renewals, revocations and succession. |
| **Permission to occupy** | A printable document with a QR code, and a public page anyone can use to check that it is genuine. |
| **Council Secretary** | Meetings, attendance, draft and final minutes, amendments to final minutes, resolutions, projects and milestones. |
| **Community updates** | Residents read the published resolutions and projects, with each project's milestone progress. |
| **Audit trail** | Who changed what, when, from what, to what and why. Insert-only, and the Council Administrator's to read. |
| **Administrator transfer** | The only way the Council Administrator role ever moves, in one transaction, with an emergency way back in. |

## Getting started

Setting up a fresh Supabase project with demo data and the first two
accounts: see [docs/NEW-PROJECT.md](docs/NEW-PROJECT.md).

```bash
npm install
cp .env.example .env     # your Supabase URL and anon key
npm run dev
```

The full walkthrough, including the first administrator, is in
[docs/SETUP.md](docs/SETUP.md).

## The database

Only the tables the built functions need, and nothing more.

```
roles ───< staff ───< user_accounts >─── auth.users

land_sites ───< households ───< residents ───< family_relationships
     └───< land_allocations >─── residents

residents ───< land_applications ───< land_allocations ───< ptos ───< pto_renewal_requests

council_meetings ───< meeting_attendance
        ├───< meeting_minutes ───< meeting_minutes_amendments
        └───< council_resolutions ───< community_projects ───< project_milestones
                     └──────────────────────┴───< visibility_changes

audit_logs        (insert only, no relationships — it outlives what it describes)
```

* **roles** — the four roles, seeded by the migration: Registry Clerk,
  Land Officer, Council Secretary, Council Administrator.
* **staff** — the person and their *one* role (`staff.role_id`), plus
  when they were last deactivated or reactivated, by whom and why.
* **user_accounts** — the sign-in account. For staff,
  `account_status` (`active` / `deactivated`) is the single source of
  truth for whether they may use the system.

`user_accounts.resident_id` links a verified resident account to its
record on the village register.

Land is only ever **residential**, **farming**, **business** or
**burial**. Grazing land is not allocated by TAMS and no permission to
occupy is issued for it. See [docs/LAND.md](docs/LAND.md).

The council's own record — meetings, minutes, resolutions and projects —
is the Council Secretary's. Final minutes are locked and corrected by
amendment, and a resident sees only what has been published and
confirmed. See [docs/COUNCIL-SECRETARY.md](docs/COUNCIL-SECRETARY.md).

Notifications, official communications and internal staff messaging
have been removed from the app. Their database tables (from the
`notifications` and `communications` migrations) are still in place but
nothing in the app reads them.

Every change is recorded in an insert-only audit trail with its old and
new values, readable by the Council Administrator alone. See
[docs/AUDIT-AND-ADMINISTRATION.md](docs/AUDIT-AND-ADMINISTRATION.md).

The village records came from the legacy import. An active Registry Clerk
may read all five tables and write to residents, households and family
relationships through the `registry_*` functions; nobody else can read
them at all, and nobody can change land sites or land allocations, which
are the Land Officer's to change. A
household is identified by its `household_code`, never by surname, and
the head of a household is not assumed to be the person the land was
allocated to. See [docs/LEGACY-IMPORT.md](docs/LEGACY-IMPORT.md).

## How it is kept safe

* **The browser holds no secrets and makes no writes.** Only the `anon`
  key is used there, and it can reach only what Row Level Security
  allows.
* **Row Level Security is on for every table**, with no insert,
  update or delete policy at all. Every write goes through a
  `security definer` function that re-establishes the caller from
  `auth.uid()` and checks the rules for itself. A signed-in browser may
  *call* those functions; it cannot reach the tables behind them.
* **Roles are never trusted from the browser.** Every protected
  operation re-reads, from the database, that the caller has an active
  staff account and what role that account currently holds.
* **The Council Administrator role cannot be handed out** by any
  ordinary staff function, and the administrator's own account cannot be
  changed, deactivated or reactivated from the staff pages. The role
  moves only through Administrator Transfer, in one transaction; a
  database trigger refuses a second *active* administrator however the
  row is written.
* **Access can be withdrawn at once.** `account_status` is checked on
  every protected read and every privileged operation, so a staff member
  who is deactivated mid-session can do nothing further with the session
  they already have.
* **No half-created people.** The staff record and the user account are
  written in one transaction, and the invited auth user is deleted again
  if that transaction fails.
* **A session nobody is using ends by itself.** Thirty minutes for
  staff, sixty for a resident, with two minutes' warning first. Only a
  click, a key, a touch or a real navigation counts as use — a page
  sitting open, a tab regaining focus and the background account check
  do not. Signing out reaches every open tab at once.
* **Nothing secret is ever committed.** `npm test` scans every tracked
  file for anything shaped like a real key and fails the build rather
  than letting one be published.

## Layout

```
src/                      React app (pages, session, guards)
supabase/migrations/      the foundation, staff management, village records,
                          registry clerk, relationship history, resident accounts,
                          land model, land functions, council records,
                          council functions, notifications, audit trail,
                          communications, administrator transfer,
                          password reset audit, final hardening
data/legacy-import/       the village's existing records, as supplied
supabase/functions/       bootstrap-council-administrator, create-staff-account,
                          manage-staff-account, emergency-admin-recovery
supabase/tests/           database test suite (runs on plain PostgreSQL)
tests/                    edge function rule tests
scripts/                  one-time administrator bootstrap, legacy import
docs/                     SETUP.md, TESTING.md, LEGACY-IMPORT.md,
                          REGISTRY-CLERK.md, RESIDENT-ACCOUNTS.md, LAND.md,
                          COUNCIL-SECRETARY.md, AUDIT-AND-ADMINISTRATION.md, NAVIGATION.md,
                          PASSWORD-RESET.md, DEPLOYMENT.md, FINAL-QA.md,
                          DEMO.md, DEMO-RESET.md
```

## Tests

```bash
npm run test:all
```

969 automated checks: see [docs/TESTING.md](docs/TESTING.md).
