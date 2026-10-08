# Demonstrating TAMS

A route through the system that shows what it actually does, in about
twenty minutes. It follows one thread — a person joining the village
register and ending up holding a permission to occupy — and then shows
the council side and the administrator's view of everything that
happened.

Rehearse it once before presenting it. Two steps depend on email
arriving, and one depends on a document you prepared earlier.

## What is already in the system

The register is loaded from `data/legacy-import/`. It is synthetic, but
it is a real village in shape rather than filler: **70 residents** in
**20 households** across **Mhinga Village**, with **20 land sites**,
**20 allocations** and **200 family relationships** between them. People
share surnames, households have heads, relationships have both sides
recorded, and allocations go back to 1989.

Do not replace any of it with `Test Test` rows. A demonstration is far
more convincing over Samuel Rachidi of household HH-0001 at 13 Marula
Street than over a register of placeholder names.

## Accounts you need

Five, one per role, plus one resident you create live. **Passwords are
not written down in this repository, and must not be.** Prepare them on
your own machine before the demonstration.

| Role | How it comes to exist |
| --- | --- |
| Council Administrator | `scripts/bootstrap-administrator.sh`, once, by hand |
| Registry Clerk | the administrator creates it, in the app |
| Land Officer | the administrator creates it, in the app |
| Council Secretary | the administrator creates it, in the app |
| Resident (prepared) | registered and approved before the demonstration, so you have a verified resident to work with |
| Resident (live) | you register this one during step 2 |

Preparing them:

1. Create the first administrator with the bootstrap script, then
   **unset `TAMS_BOOTSTRAP_SECRET`** so that door is shut again.
2. Sign in as the administrator and create the three staff accounts.
   Each gets an invitation email and chooses its own password — so use
   three addresses you can actually open.
3. Write the five passwords on paper, or keep them in your password
   manager. Not in the repository, not in a file in the project, not in
   the slides.
4. Have all five signed in, in separate browser profiles or windows,
   before you start. Switching roles by signing in and out in front of
   an audience wastes several minutes and risks a typo.

**Remember the inactivity timeout.** Staff sessions end after 30 minutes
of no interaction and residents' after 60. If you set your windows up an
hour before presenting, they will have signed themselves out. Either set
up shortly beforehand, or click once in each window before you begin.

## The demonstration

### 1. The public face — 1 minute

Open the site signed out.

The landing page offers two things and explains a third: **Sign in**,
**Create account**, and verifying a permission to occupy without an
account at all. Say that last part out loud — it is the only part of
TAMS a member of the public uses, and it comes back at step 8.

### 2. A resident joins — 2 minutes

**Create account** → register with a real address you can open.
Confirm the email, sign in, and submit a verification request with an
identity number and the two documents.

Show the portal afterwards: it says **pending**, and there is nothing
else to do. Point out that this account can reach nothing — it is a
sign-in, not an entitlement.

### 3. The Registry Clerk verifies them — 3 minutes

In the clerk's window: **Resident requests** → the new one.

The clerk does not type the resident's details in. They **search the
register** for the record that is already there and match the account to
it. This is the point worth dwelling on: the register is the authority,
and an online account is only a way of reaching a record that already
exists.

Approve it. Back in the resident's window, refresh: the account is
active and now shows their official record.

### 4. The official record — 2 minutes

Still as the clerk, open the resident's record, then their household,
then their family lineage.

Show that the lineage has both sides of each relationship, and that
ending one keeps it on the record rather than deleting it. Show the
household head, and that a head must be a member of the household they
head.

### 5. The resident applies for land — 1 minute

In the resident's window: apply for **residential** land.

They apply for a *kind* of land, never a particular site. Show the
eligibility check refusing something — try applying twice for the same
kind, and let it refuse.

### 6. The Land Officer decides — 3 minutes

In the officer's window: **Applications** → the new one.

Eligibility is re-checked in front of you, at the moment of the
decision. Approve it. Then **allocate a site** from those available.
Show that an allocated site disappears from the list — the same site
cannot be given to two people.

### 7. The permission is issued — 2 minutes

Issue the PTO. Open the document.

It is a real printable certificate with a reference, the holder, the
site and a QR code. **Print or save as PDF** in front of the audience —
this is the artefact the whole system exists to produce.

### 8. Anyone can check it — 2 minutes

Sign out completely, or use a private window.

Scan the QR code with a phone, or go to **Verify a PTO** and type the
reference. The permission comes back as valid, with the holder and the
site, and nothing else. Try a made-up reference and show that it says
so without hinting at what a real one looks like.

This is the strongest single moment in the demonstration: a signed-out
stranger with a phone can confirm a document is genuine, and can learn
nothing else.

### 9. The council record — 3 minutes

In the secretary's window: a meeting, its attendance, and its minutes.

**Finalise the minutes**, then try to edit them. They are locked. Show
that a correction is made by an **amendment** recorded beside them,
never by rewriting what was agreed.

Record a **resolution** from the meeting and make it public. Create a
**project** from it and add a milestone with a due date in the past, so
it shows as overdue — and point out nobody set it to overdue; the date
did.

### 10. What the community sees — 1 minute

Back in the resident's window: **Community updates**.

The resolution is there, because its minutes are final. Show an
internal resolution that is not there.

### 11. The audit trail — 3 minutes

In the administrator's window: **Audit trail**.

Everything from the last twenty minutes is there. Open the resident
record you changed at step 4 and show the **from** and **to** columns —
who, what, when, from what, to what, and why.

Then try to change an audit entry. There is no way to: the table refuses
updates and deletes at the database, whoever attempts them.

### 12. Passing the office on — 2 minutes

**Transfer administrator.** Hand the role to the Registry Clerk, giving
a reason.

Show that the outgoing administrator's audit trail access is gone
immediately, that the incoming one's works immediately, and that the
transfer is itself an audit entry with both sides recorded.

Transfer it back before you continue.

### 13. On a phone — 1 minute

Open the same site on a phone, or narrow the window to about 390px.

The navigation becomes a menu, forms stack, tables scroll inside
themselves rather than pushing the page sideways, and every button
stays usable. Sign in and reach the same resident record.

### 14. Walking away — 1 minute

If the timing suits, leave a staff window untouched and come back to
the warning. If it does not, say what it does: 30 minutes for staff, 60
for a resident, a warning two minutes out, and a sign-out that reaches
every open tab at once.

To show it in seconds rather than half an hour, run the development
server and add `?idle-timeout=45` to any address. It is ignored
entirely in a production build.

## If something goes wrong

| What happens | What to do |
| --- | --- |
| A page says a function is not in the schema cache | A migration has not reached the project. Run `notify pgrst, 'reload schema';` in the SQL Editor. |
| A window has signed itself out | The inactivity timeout. Sign in again; nothing is lost. |
| A site will not allocate | It is already held. That is the constraint working — say so, and pick another. |

## Afterwards

Nothing needs undoing. Everything the demonstration created is a real
record and the system is designed to keep it. See
[DEMO-RESET.md](DEMO-RESET.md) before running the demonstration a second
time.
