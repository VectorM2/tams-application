# Pre-presentation check: 8 October 2026

## What was run

| Check | Result |
| --- | --- |
| TypeScript (`tsc -b`) | no errors |
| Unit tests (`npm test`) | **255 / 255 passed** |
| Database test suite, all 17 migrations on a fresh PostgreSQL 16 (`npm run test:db`) | **765 / 765 passed** |
| Production build (`npm run build`) | builds |
| Demo import (`data/demo-seed`) into a fresh database | 145 residents, 32 households, 540 relationships, 32 allocations: no problems reported |
| `scripts/demo/01_create_accounts.sql` | creates the administrator and the Registry Clerk; a second run skips both |
| `scripts/demo/02_seed_demo_records.sql` | 15 free sites, 3 meetings, 4 resolutions, 2 projects; a second run refuses |
| App functions on the seeded database, signed in as the clerk and the administrator | register dashboard 145/32; search works; admin dashboard and audit trail show data |

## Routes

* All 45 routes in `src/App.tsx` were compared with every link,
  redirect and navigation item in `src/`. Every one of the 43 targets
  resolves to a real route.
* In a browser, against the production build:
  * all public pages render: `/`, `/auth`, `/register`, `/forgot-password`,
    `/verify/pto`, `/no-access`;
  * an unknown address shows *That page could not be found*;
  * every protected page sends a signed-out visitor to `/auth`;
  * the removed pages (`/messages`, `/notifications`) show Not Found;
  * there were no browser errors.

## Input validation

Every form posts to a database function that checks its input again.
The client checks only make the errors friendlier.

| Form | Checked |
| --- | --- |
| Sign in | empty fields; one generic message for wrong details, which by design does not reveal which emails exist |
| Register | **fixed:** an empty or malformed email used to reach Supabase and come back as "an account may already exist". It is now caught first. Password length and confirmation use the same rules as reset. |
| Forgot / reset / set password | email shape, length 8+, confirmation |
| Resident verification | names, 13-digit ID with a real date, date of birth matching the ID, gender, required address fields, PDF/JPG/PNG up to 2 MB. **Added:** cellphone number must be a valid SA number. |
| **Registry Clerk: create / update resident** | **fixed.** Previously any text was accepted as an ID number or gender, so a typo could stop that resident ever matching their own verification request. Now: 13-digit ID with a real date, date of birth filled in from the ID and checked against it, no future dates, a Male/Female choice, names in letters, phone and email checked when given. |
| Create staff account | employee number, names, email, contact number, validated by the edge function and shown per field |
| Land sites, applications, allocations, PTOs, renewals, succession | required reasons, status and type rules, all enforced in the database functions (78 checks) |
| Meetings, minutes, resolutions, projects, milestones | required fields, cancellation reasons, end date ≥ start date, milestone within the project (90 checks) |
| Administrator transfer, deactivate / reactivate | reason required, 500 characters at most |

## Also fixed

* `tests/secrets.test.ts` still expected the removed email worker in
  `docs/SETUP.md`, so it failed on `main` after notifications were
  removed. The test now checks the secrets the guide still names.

## Worth knowing on the day

* A new project's emails (invitations, sign-up confirmation) go through
  Supabase's built-in sender, which only sends a few an hour. The two
  starting accounts are created without email for that reason. See
  [NEW-PROJECT.md](NEW-PROJECT.md) step 3 about **Confirm email**.
* The original `data/legacy-import` residents have placeholder ID numbers
  (`SYN…`). Use the demo package for the presentation.
