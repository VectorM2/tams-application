# Preparing TAMS for another demonstration

There is no reset button, and there should not be. TAMS is a system of
record: a button that emptied it would be the single most dangerous
thing in the application, and every safeguard in the database exists
precisely to stop records disappearing.

So this is a checklist for getting back to a clean starting point
*without* destroying anything, and a short list of the few things that
are genuinely safe to remove.

## Keep all of this

**The synthetic village.** 70 residents, 20 households, 20 sites, 20
allocations, 200 family relationships. It is the backdrop that makes
every demonstration look like a real place. Loaded once from
`data/legacy-import/`, and reloading it is neither necessary nor safe.

**Every historical record**, including anything an earlier
demonstration created. An ended allocation, a revoked permission, a
cancelled meeting and a declined application are all *supposed* to still
be there. They are what the audit trail refers to.

**The audit trail, in full.** It cannot be edited or deleted anyway —
the table raises on any update or delete, whoever attempts it. If a
demonstration produced entries you would rather not show, filter the
view by date or action rather than trying to remove them.

**The five staff accounts.** Creating them again means three more
invitation emails and three more passwords.

## Safe to tidy

Only these, and only if the clutter is actually in the way:

| What | How | Why it is safe |
| --- | --- | --- |
| A resident account you registered during a demonstration | Council Administrator → deactivate it | Deactivating keeps the record and removes the access. Nothing is lost. |
| A test resolution or project | mark it **cancelled** or **withdrawn**, with a reason | This is what the system is for. Cancelling is a real state, not a deletion. |
| A test meeting | mark it **cancelled**, with a reason | Same. A cancelled meeting is kept deliberately. |

Notice that none of these is a delete. That is the point.

## Before the next demonstration

A checklist, in order:

- [ ] **Sign in as each of the five accounts** and confirm the password
      still works. An expired invitation is the commonest surprise.
- [ ] **Check the Council Administrator is the one you expect.** If the
      last demonstration ended at step 14 without transferring the role
      back, it is someone else. Fix it now, not in front of an audience.
- [ ] **Confirm every account is active.** Council Administrator →
      Staff accounts. Anything deactivated during a demonstration needs
      reactivating.
- [ ] **Prepare one verified resident**, so you have somebody to work
      with at steps 4 to 7 without waiting for a verification.
- [ ] **Free one land site of each kind**, so step 6 has something to
      allocate. Land Officer → Land sites, filtered to available. If
      there is nothing available, release an allocation made by an
      earlier demonstration — releasing is a recorded action, not a
      deletion, and the allocation stays on the record as ended.
- [ ] **Have one meeting scheduled but not yet held**, so step 9 has
      somewhere to go.
- [ ] **Empty the inbox you register from** at step 2, or use a fresh
      address, so the confirmation email is easy to find.
- [ ] **Click once in every window you have set up**, so the inactivity
      timeout has not signed them out while you were preparing.

## What must never be done to tidy up

* **Never `truncate` or `delete from` a TAMS table.** Foreign keys will
  stop most of it, the audit trail will refuse outright, and what does
  succeed will leave the register referring to people who are no longer
  there.
* **Never re-run the legacy import.** It is a one-time load and it
  refuses to run twice, but do not go looking for a way around that.
* **Never edit `auth.users` by hand.** Accounts are managed through the
  application, which keeps `user_accounts` in step with them.
* **Never add a "reset" edge function**, however convenient it would be.
  A function that can empty the register is a function that can be
  called by mistake.

## Starting genuinely fresh

If you truly need an empty system — a second demonstration environment,
say — make a **new Supabase project** and run
[SETUP.md](SETUP.md) against it. That takes about fifteen minutes and
leaves the real one untouched, which is the whole reason to do it that
way.
