# Deploying TAMS

TAMS is two halves. The database, the edge functions and the scheduled
jobs live in a Supabase project, and that half is already deployed the
moment you finish [SETUP.md](SETUP.md). The other half is a static
bundle of HTML, CSS and JavaScript that any host can serve.

This repository includes a production `netlify.toml`, so Netlify is the
ready-to-use path. The bundle remains a plain static site and can still
be deployed to another host if required.

## What "ready to deploy" means here

| | |
| --- | --- |
| Build | `npm run build` produces `dist/`, a plain static site |
| Routing | client-side; the host must rewrite unknown paths to `index.html` |
| Secrets in the bundle | none — browser configuration uses only `VITE_*` values that are public by design |
| Server needed | none for the front end |
| Node version at build time | 20 or newer |

## 1. Environment

### The browser bundle

Set these where your host keeps build-time environment variables. Vite
reads them at build time, so a change needs a rebuild, not a restart.

| Variable | Required | What it is |
| --- | --- | --- |
| `VITE_SUPABASE_URL` | yes | your project URL |
| `VITE_SUPABASE_ANON_KEY` | yes | the `anon` public key |
| `VITE_APP_URL` | on a deployed site | the site's own public address, e.g. `https://tams.example.org` |
| `VITE_RESIDENT_SELF_REGISTRATION` | yes | keep `false` while only the Council Administrator may have access |

`VITE_APP_URL` has one job: it is the address that leaves the browser.
Password-reset emails send people back to it, and it is printed as the
QR code on every permission to occupy. Left unset, TAMS uses whatever
address the browser is already on — right in development, wrong the
moment somebody prints a permission from a laptop.

**Never put a service-role key, a Brevo key or any `TAMS_*` secret in a
`VITE_` variable.** Everything Vite reads is compiled into the bundle
and is readable by anyone who opens the page. `npm test` fails if one
appears.

### The server side

These are Supabase secrets, set with `npx supabase secrets set`. They
never appear in this repository and never reach the browser.

| Secret | Used by |
| --- | --- |
| `BREVO_API_KEY` | the notification email worker |
| `TAMS_EMAIL_FROM` | the address email is sent from |
| `TAMS_EMAIL_FROM_NAME` | the name email is sent from |
| `TAMS_APP_URL` | the links inside notification emails |
| `TAMS_SITE_URL` | where a staff invitation link comes back to |
| `TAMS_WORKER_SECRET` | authorises the cron job to run the email worker |
| `TAMS_ADMIN_RECOVERY_SECRET` | authorises emergency administrator recovery |
| `TAMS_BOOTSTRAP_SECRET` | used once, to create the first administrator |

`SUPABASE_SERVICE_ROLE_KEY` is **not** in that list: Supabase gives it
to the edge functions itself. You never set it and never copy it.

On deployment, `TAMS_APP_URL` and `TAMS_SITE_URL` both become the
deployed address:

```bash
npx supabase secrets set TAMS_APP_URL=https://tams.example.org
npx supabase secrets set TAMS_SITE_URL=https://tams.example.org
npm run functions:deploy
```

## 2. Make the database administrator-only

The deployment switch is reversible and does not delete an account or
record:

1. Run `supabase/maintenance/preview_administrator_only.sql` in the
   Supabase SQL Editor. Continue only when it reports exactly one active
   Council Administrator.
2. Run `supabase/maintenance/enable_administrator_only.sql`. It
   deactivates every other account in one transaction and stores their
   prior statuses in the private schema.
3. In **Authentication → Sign In / Providers → Email**, turn **Allow
   new users to sign up** off. Supabase then permits existing users to
   sign in but refuses new public sign-ups.

To undo the database switch later, run
`supabase/maintenance/restore_administrator_only.sql`. Full operating
instructions are in `supabase/maintenance/README.md`.

## 3. Deploy the front end

Import the GitHub repository into Netlify. The committed configuration
runs `npm run build`, publishes `dist`, rewrites browser routes to the
single-page app and applies the production security headers. In the
Netlify environment settings, add all four browser variables listed
above, with `VITE_RESIDENT_SELF_REGISTRATION=false`.

Netlify automatically rebuilds after a push to the connected production
branch. For a one-off manual deployment, build locally with the same
environment values and upload `dist/`.

### Other static hosts

Any static host works, but it must rewrite unknown paths to `index.html`
and apply equivalent security headers.

### Vercel

Import the repository. Vercel detects Vite and needs no build settings.
Add the environment variables, then add `vercel.json`:

```json
{ "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }] }
```

### Cloudflare Pages

Build command `npm run build`, output directory `dist`. Cloudflare
serves `index.html` for unknown paths by default, so there is nothing
to configure for routing.

## 4. After the first deploy

In order, because two of these depend on the address existing:

1. **Supabase → Authentication → URL Configuration.** Set **Site URL**
   to the deployed address, and add both
   `https://<your-address>/set-password` and
   `https://<your-address>/reset-password` to **Redirect URLs**. Leave
   the localhost entries so development keeps working.
2. **Supabase secrets.** `TAMS_APP_URL` and `TAMS_SITE_URL`, then
   `npm run functions:deploy`.
3. **Rebuild the front end** with `VITE_APP_URL` set, so printed
   permissions carry the right QR code.
4. **Check the cron jobs are still scheduled** — Dashboard →
   Integrations → Cron. They are database-side and are unaffected by a
   front-end deploy, but it is worth confirming both are listed:
   `tams-notification-emails` every five minutes, and
   `tams-pto-expiry-warnings` daily.
5. **Walk the flows in [FINAL-QA.md](FINAL-QA.md)** against the
   deployed address, not localhost.

## 5. What is checked automatically

```bash
npm run typecheck   # no TypeScript errors
npm test            # the Node suite, including the secret scan
npm run build       # a clean production bundle
npm run test:db     # the database suite, against a local PostgreSQL
```

`npm test` includes a scan of every tracked file for anything shaped
like a real secret. It fails the build rather than letting one be
published, which is the check that would have caught the worker secret
that was once pasted into this repository's own setup guide.

## 6. What is not done, and deliberately

* **No custom domain, TLS or DNS.** Your host does these.
* **No CI/CD workflow.** There is no `.github/workflows`. Add one if you
  want the tests to run on every push; the four commands above are the
  whole of it.
* **No monitoring or error reporting.** Supabase's own logs are what
  there is.
* **No backups beyond Supabase's own.** Check your plan's retention
  before relying on it.
