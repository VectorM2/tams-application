# The Council Secretary: meetings, minutes, resolutions and projects

The official record of what the traditional council did, and the small
part of it the community is shown.

Two rules run through everything here:

* **Official history is never rewritten.** Finalised minutes are locked
  and corrected by amendment. Cancelled meetings, withdrawn resolutions
  and cancelled projects are kept with their reason. Nothing in this
  part of TAMS is ever physically deleted.
* **What a resident may see is decided by the database.** Internal
  records are unreachable to them, not merely hidden by the browser.

---

## 1. Who the Council Secretary is

Every privileged action establishes its caller server-side, exactly as
the Registry Clerk's and the Land Officer's do:

```
auth.uid() → user_accounts (account_type = 'staff', account_status = 'active')
           → staff → the role that account holds now = 'Council Secretary'
```

`acting_council_secretary_staff_id()` does that walk and raises `42501`
if it does not end there. It is re-read on **every single call**, so a
Council Secretary whose account is deactivated loses access at once, in
the session they are already sitting in.

Nothing is taken from the browser — not the role, not a staff id, not a
route name.

* A **Registry Clerk**, a **Land Officer** and a **resident** are each
  refused every Secretary write.
* The **Council Administrator** is refused too. Being the administrator
  does not confer the Secretary's work; TAMS keeps one current role per
  staff member, and the administrator's is not this one.

The Council Secretary in turn manages **only** meetings, attendance,
minutes, amendments, resolutions, projects and milestones. Resident
records, household membership, family lineage, land applications,
allocations, permissions to occupy and staff accounts are not theirs and
are not reachable from here.

The Secretary's area is at `/secretary`: Dashboard, Meetings,
Resolutions, Projects, My account.

## 2. The dashboard

Counts what is actually waiting: upcoming meetings, meetings held with
no final minutes, minutes still in draft, active resolutions, active
projects, published resolutions and projects, and **overdue
milestones**.

The overdue count is worked out from each milestone's own due date at
the moment the dashboard is asked. Nobody marks anything overdue, and no
scheduled job has to run for the number to be right.

## 3. Meetings

`council_meetings`. A meeting has a generated reference (`MTG-2026-0001`),
a title, a kind, a date, a starting time, a venue and an agenda — all
required.

**Kinds:** `ordinary`, `special`, `emergency`. Nothing else is accepted.

**Statuses:** `scheduled`, `held`, `cancelled`.

The only moves allowed are:

```
scheduled → held
scheduled → cancelled
```

A held meeting cannot go back to being scheduled, and a cancelled one
cannot become held. Cancelling **requires a reason**, which is stored
with the moment and the Secretary who cancelled it; the meeting stays in
the record for ever.

**Dates** are validated properly: a date and a starting time are both
required, and a date more than ten years back or two years forward is
refused as one nobody meant.

**Editing:** a meeting can be corrected while it is still `scheduled`.
Once it is held or cancelled its own details are part of the official
record and the function refuses to rewrite them — a correction belongs
in the minutes.

## 4. Attendance

`meeting_attendance`. Name, the capacity they attended in, and whether
they were `present`, `absent` or an `apology`.

**Attendees need no TAMS account of any kind.** The Chief, a Headman or
Headwoman, council members, community representatives and invited guests
are simply written down. The table deliberately has no
`user_account_id`, no `resident_id` and no `staff_id`: attendance is an
official record of a meeting, not a way of signing anybody in.

Attendees can be added and corrected while the minutes are still a
draft. **Once the minutes are final the attendance list closes** — it is
part of them — and it is kept exactly as it is.

**Residents never see attendance**, by any route.

## 5. Minutes

`meeting_minutes`. A meeting may have **at most one** minutes record,
enforced by a unique constraint on `meeting_id` rather than by the
application.

**Statuses:** `draft`, `final`.

The Secretary writes a draft, saves it, comes back and edits it as often
as they like. Until final minutes exist, the meeting sits on the
dashboard under *Meetings awaiting minutes*.

**Finalising** is an explicit action behind a confirmation. It records:

```
minutes_status        = 'final'
finalized_at          = now()
finalized_by_staff_id = the acting Council Secretary
```

TAMS adds **no second digital approver**. The council confirms its
minutes the way it always has, in the room; the Secretary records that
this has happened.

**Final minutes are locked.** `secretary_save_minutes` refuses them, and
there is no insert, update or delete policy on the table at all, so
there is no other way in either. They cannot be edited and cannot be
deleted.

## 6. Amendments

`meeting_minutes_amendments`. When an error is found after finalisation
the original is **not** reopened and **not** overwritten. A correction is
recorded as a separate row, with its own reference (`AMD-2026-0001`), the
correction itself, a **required reason**, and who wrote it.

* An amendment may only be added to **final** minutes. A draft is simply
  edited, so amending one is refused.
* Both the correction and the reason are required.
* The original wording stays word for word what it was.
* Amendments are shown beneath the minutes they correct, for ever, and
  are never deleted.

## 7. Resolutions

`council_resolutions`. One meeting may produce many. Each gets a
generated reference (`RES-2026-0001`).

**The decision date comes from the meeting**, not from the browser — it
is not a parameter of `secretary_record_resolution` at all, so there is
nothing for a client to claim.

**Statuses:** `active`, `implemented`, `withdrawn`.

* `active → implemented` records the moment and the Secretary.
* Withdrawing **requires a reason**. The resolution is kept, with its
  wording, its reason and who withdrew it, and it cannot be made active
  again.
* Recording a resolution **does not create a project**. That is always a
  separate, deliberate act.

A resolution's wording can still be corrected while the minutes of its
meeting are a draft. Once they are final it cannot: the correction
belongs in an amendment to the minutes.

## 8. Visibility — internal and public

Both resolutions and projects carry `visibility`: `internal` or
`public`.

**A resident sees a resolution only when it is public *and* the minutes
of its meeting are final.** A decision from a meeting whose minutes are
still a draft has not been confirmed, so it never reaches the community,
whatever its visibility says. This is a condition inside the Row Level
Security policy, not a filter in the browser.

**A public project reaches residents straight away** — a project has no
minutes to wait for.

**Taking something back off the public record** — public → internal —
requires a reason and an explicit confirmation. The change is written to
`visibility_changes` with the direction, the reason, the moment and the
Secretary who made it. Both directions are recorded, including the
publication that happens when something is created public. Nothing that
was published ever silently disappears, and the Secretary can read the
whole publication history from the Resolutions and Projects screens.

## 9. Projects

`community_projects`. Reference `PRJ-2026-0001`, a name, a description,
a start date, an optional target completion date, and an **optional**
link to a resolution.

A project with a resolution behind it and a project with none are both
perfectly ordinary, and both are tested.

**Statuses:** `planned`, `active`, `completed`, `cancelled`.

* Cancelling **requires a reason**; the project is kept with it.
* A completed or cancelled project cannot be reopened or edited.
* **A target completion date before the start date is refused**, by a
  check constraint as well as by the function.
* Completing stores `completed_on` and `completed_at` with the Secretary
  who decided it.

**TAMS never completes a project by itself.** Finishing every milestone
changes nothing about the project's status: completion is the
Secretary's own explicit, confirmed decision.

## 10. Milestones and what "overdue" means

`project_milestones`. Title, an optional note, a due date, and a status.

**Only three statuses are ever stored:** `pending`, `in_progress`,
`completed`. Completing stores `completed_at` and the Secretary who did
it.

**`overdue` is not one of them, and cannot be chosen.** It is worked out:

```sql
milestone_effective_status(status, due_date) =
  'completed'  when the status is completed
  'overdue'    when due_date < current_date
  the status   otherwise
```

That function is `immutable` and depends on nothing but the stored
status and the date, so a milestone becomes overdue the moment its due
date passes — in the Secretary's project view, on the dashboard, and in
the resident's Community Updates alike. **No scheduler is involved, and
the answer cannot go stale because a nightly job failed to run.** The
function refuses `'overdue'` as an input, and a check constraint on the
table refuses to store it however the row is written.

A milestone due before its project's own start date is refused.
Completed milestones are never deleted.

## 11. Community Updates — what a resident sees

The active resident's portal carries a read-only **Community Updates**
section, served by `resident_community_updates()`.

It contains:

* **Public council resolutions** whose meeting's minutes are final —
  reference, wording, decision date and status. A withdrawn resolution
  that is still deliberately public is shown as withdrawn rather than
  hidden or presented as live.
* **Public community projects** — reference, name, description, start
  date, target completion date where there is one, and status.
* **Their milestones**, with the effective status:

  ```
  Borehole repairs
  Status: Active

  ✓ Purchase materials — Completed
  ! Borehole drilling  — Overdue
  • Install the pump   — Pending
  ```

A public project shows its resolution's **reference only**, and only
when that resolution is itself public and confirmed. **A public project
linked to an internal resolution exposes nothing of it** — not the
reference, not the wording.

It contains **none** of: meeting attendance, draft minutes, final
minutes, internal resolutions, internal projects, internal notes,
cancellation or withdrawal reasons for internal records, or anything
else belonging to staff.

Residents have read-only access. They cannot edit a project, a
resolution, a milestone, a meeting or minutes — each attempt is refused
with `42501`.

Only a **verified, active** resident account reaches any of it. A
resident still waiting for verification, or one whose verification was
declined, is refused.

## 12. Security

* **Row Level Security is enabled and forced** on all eight tables:
  `council_meetings`, `meeting_attendance`, `meeting_minutes`,
  `meeting_minutes_amendments`, `council_resolutions`,
  `community_projects`, `project_milestones` and `visibility_changes`.
* **There is no insert, update or delete policy on any of them**, and no
  broad "authenticated may write" policy anywhere. Table privileges for
  `authenticated` are `select` only. Every write goes through a
  `security definer` function that establishes its own caller.
* **Read policies are narrow.** Meetings, attendance, minutes,
  amendments and the visibility history are readable by an active
  Council Secretary and nobody else. Resolutions add exactly one more
  case — public, confirmed, and the caller is an active resident.
  Projects add public plus active resident; milestones add the
  milestones of public projects.
* **The resident function selects field by field.** It never reads a
  whole row and leaves the browser to hide the rest, which is why the
  list of keys a resident receives is itself a test.
* **Actors and timestamps are recorded** —
  `created_by_staff_id`, `finalized_by_staff_id`, `cancelled_by_staff_id`,
  `withdrawn_by_staff_id`, `completed_by_staff_id`,
  `changed_by_staff_id` and their timestamps — so the audit module that
  comes later has real history to build on. The system-wide audit trail
  itself is **not** built yet.

## 13. What came next

The audit trail was built afterwards — see
[AUDIT-AND-ADMINISTRATION.md](AUDIT-AND-ADMINISTRATION.md). Everything
in this document still holds, and every change described here is
recorded in the audit trail. (Notifications, official communications and
staff messaging were built later too, and have since been removed.)

## 14. Deliberately not built at the time

Notifications of any kind, the system-wide immutable audit trail,
Administrator Transfer, payments, GIS or mapping, Chief/Headman/
Headwoman user accounts, resident access to full meeting minutes, and
public attendance records are **not** part of this work.
