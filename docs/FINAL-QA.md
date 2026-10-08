# Final manual QA

Everything a person has to check by hand, because a test cannot. The
automated suites cover the rules; this covers whether the thing is
usable.

Run it against a deployed address, not localhost, before saying TAMS is
ready. Tick as you go.

**Before you start:** five accounts, one per role, all signed in in
separate windows. Remember that staff sessions end after 30 minutes idle
and residents' after 60.

---

## Public and authentication

- [ ] Landing page loads signed out, and offers **Sign in** and **Create account**
- [ ] Landing page explains PTO verification, and nothing else
- [ ] The TAMS logo returns to the landing page from every page that shows it
- [ ] Sign in with a correct password reaches the right dashboard for the role
- [ ] Sign in with a wrong password says so, and does not say which part was wrong
- [ ] Sign in with an address that has no account gives the same message as a wrong password
- [ ] A deactivated account is refused, and the message does not say why
- [ ] **Forgot password?** is on the sign-in page and works for a resident
- [ ] It works for a staff member too
- [ ] The reset email arrives, and its link opens `/reset-password`
- [ ] A real address and an address that does not exist give word-for-word the same answer
- [ ] Two mismatched passwords are refused
- [ ] A password under 8 characters is refused
- [ ] A successful reset signs you out and lets you sign in with the new password
- [ ] The same reset link used a second time shows "This reset link cannot be used"
- [ ] That page offers three ways onward, and none of them is browser Back
- [ ] Visiting `/reset-password` directly shows the same usable page, not a blank one
- [ ] Resident registration works end to end, including the confirmation email
- [ ] A staff invitation email arrives and `/set-password` works
- [ ] An unknown address such as `/nowhere` shows the 404 page with a way home
- [ ] Signing out returns to the landing page, and Back does not restore the session

## Resident

- [ ] A pending account sees its status and can reach nothing else
- [ ] A declined account sees the reason and can reapply
- [ ] Reapplying works, and the earlier attempt is still listed
- [ ] An active account sees its official record and household
- [ ] Applying for land works, and the eligibility check refuses a second application for the same kind
- [ ] The application's progress is visible to the resident
- [ ] An allocation, once made, appears on the resident's portal
- [ ] The permission to occupy is visible and printable
- [ ] A renewal can be requested for farming or business land
- [ ] Community updates show public resolutions and projects, and nothing internal
- [ ] An official notice or summons arrives
- [ ] Sign out works

## Registry Clerk

- [ ] Dashboard shows counts and **Quick actions**, and no tutorial card
- [ ] Search by identity number, name, household code, site code and address each work
- [ ] A resident record opens, and can be edited
- [ ] A new resident can be created
- [ ] Households list, open and can be created
- [ ] A resident can be moved between households, with a confirmation first
- [ ] A household head can be designated, and must be a member of that household
- [ ] A family relationship can be recorded, and both sides appear
- [ ] Ending a relationship keeps it on the record rather than removing it
- [ ] Resident account requests list, and can be approved and declined
- [ ] Declining requires a reason, and the resident sees it

## Land Officer

- [ ] Dashboard shows counts, **Needs attention** and **Quick actions**
- [ ] Applications list and open
- [ ] Eligibility is shown at the moment of the decision
- [ ] An application can be approved, and declined with a reason
- [ ] Land sites list, and an available one can be allocated
- [ ] An allocated site no longer appears as available
- [ ] A PTO can be issued against an allocation
- [ ] A renewal can be approved, and the old permission stays on record
- [ ] A PTO can be revoked, with a reason, behind a confirmation
- [ ] An allocation can be released, and stays on record as ended
- [ ] Burial allocation works and follows its rules
- [ ] Residential succession appears when a holder is recorded as deceased

## Council Secretary

- [ ] Dashboard shows counts, **Needs attention** and **Quick actions**, and no "How the council record works" card
- [ ] A meeting can be created, and recorded as held or cancelled
- [ ] Cancelling requires a reason
- [ ] Attendance can be recorded
- [ ] Minutes can be drafted and finalised
- [ ] Final minutes cannot be edited
- [ ] An amendment can be recorded beside final minutes
- [ ] A resolution can be recorded from a meeting
- [ ] A public resolution reaches residents only once its minutes are final
- [ ] A project can be created, from a resolution or on its own
- [ ] Milestones can be added, and an overdue one shows as overdue without being set so
- [ ] A community announcement reaches every resident
- [ ] An official notice reaches named residents only
- [ ] Several residents can be selected for one notice

## Council Administrator

- [ ] Dashboard shows counts and **Quick actions**, and no "What you can do right now" card
- [ ] Every quick action goes somewhere that exists
- [ ] Staff accounts list, with search and filters
- [ ] A staff account can be created, and the invitation email arrives
- [ ] A role can be changed
- [ ] An account can be deactivated, with a reason, and reactivated
- [ ] A deactivated staff member is refused at sign-in
- [ ] Audit trail opens and can be filtered
- [ ] Administrator transfer works, and both sides are told
- [ ] My account shows the right details

## Audit trail

- [ ] Who, what, when, from what, to what and why are all present
- [ ] A resident contact update shows the old and the new value
- [ ] A household head change shows both
- [ ] A staff role change shows both
- [ ] A land application decision shows the reason
- [ ] An allocation, a PTO issue, a renewal and a revocation are each recorded
- [ ] A meeting finalisation is recorded
- [ ] An administrator transfer shows both administrators and both roles, on both sides
- [ ] No password, token, recovery link or file path appears anywhere in it
- [ ] An audit entry cannot be edited or deleted

## Security boundaries

Check these **against the database**, not by looking for a hidden button.
Sign in as the role named and try the thing directly.

- [ ] A resident cannot edit an official resident record
- [ ] A resident cannot edit a household
- [ ] A resident cannot approve their own verification
- [ ] A resident cannot allocate land or issue a PTO
- [ ] A resident cannot open the audit trail
- [ ] A Registry Clerk cannot allocate land or issue a PTO
- [ ] A Registry Clerk cannot create council records
- [ ] A Registry Clerk cannot administer staff or read the audit trail
- [ ] A Land Officer cannot edit resident, household or lineage data
- [ ] A Land Officer cannot perform Secretary writes
- [ ] A Land Officer cannot administer staff or read the audit trail
- [ ] A Council Secretary cannot edit registry data
- [ ] A Council Secretary cannot allocate land or issue a PTO
- [ ] A Council Secretary cannot administer staff or read the audit trail
- [ ] A Council Administrator can administer staff, read the audit trail and transfer the role
- [ ] A Council Administrator can **not** do Registry, Land or Secretary writes
- [ ] Deactivating an account takes its access away within a minute, in an open window

## Session security

- [ ] A staff window left alone warns after 28 minutes and signs out at 30
- [ ] A resident window warns after 58 minutes and signs out at 60
- [ ] **Stay signed in** dismisses the warning and the session continues
- [ ] Clicking or typing before the warning prevents it appearing
- [ ] Leaving the page open and untouched does **not** keep the session alive
- [ ] The sign-out reaches every open tab
- [ ] The sign-in page then says "You were signed out after a period of inactivity."
- [ ] Manual sign out still works
- [ ] A timeout does not change any account's role, type or standing

To check these in seconds instead of half an hour, run `npm run dev`
and add `?idle-timeout=45` to any address. It is ignored in a
production build.

## Mobile and responsive

Check at 390px, at tablet width, and on a real phone if you have one.

- [ ] No page scrolls sideways
- [ ] The navigation menu opens and closes, and every link is reachable
- [ ] Forms stack rather than squashing
- [ ] Tables scroll inside themselves, not the page
- [ ] Buttons stay large enough to tap
- [ ] Dialogs fit the screen and their buttons are reachable
- [ ] The permission to occupy is readable
- [ ] Every role's dashboard works

## Look and feel

- [ ] Every filter row lines up: labels on one line, controls on the next
- [ ] Text inputs, selects and date fields are all the same height
- [ ] Buttons in a row are the same height
- [ ] Cards in a grid have even gaps and no awkward empty space
- [ ] No text is clipped or overflowing
- [ ] Focus is visible on every control when tabbing
- [ ] No page explains how the application works
- [ ] No page says "coming soon", "for now" or "placeholder"

## Error, loading and empty states

- [ ] Every page that loads data shows something while it loads
- [ ] A submit button disables itself while the action runs
- [ ] Submitting twice quickly does not do it twice
- [ ] A dropped connection says so in plain language
- [ ] No screen ever shows raw SQL, a stack trace or a Supabase object
- [ ] Every empty list says what is empty, not "No data"
- [ ] A duplicate identity number is refused readably
- [ ] Two people allocating the same site at once is refused readably

## Production configuration

- [ ] `npm run typecheck` is clean
- [ ] `npm test` passes
- [ ] `npm run test:db` passes
- [ ] `npm run build` succeeds
- [ ] `.env` is not committed
- [ ] No secret appears in any tracked file
- [ ] `VITE_APP_URL` is set on the deployed site
- [ ] Password reset links point at the deployed address, not localhost
- [ ] A printed PTO's QR code points at the deployed address
- [ ] Supabase Redirect URLs include both `/set-password` and `/reset-password`
- [ ] Custom SMTP is configured and Auth email arrives
- [ ] Every edge function is deployed
- [ ] Both cron jobs are scheduled
- [ ] Storage buckets are private
- [ ] `TAMS_BOOTSTRAP_SECRET` has been unset since the first administrator was created
