# Getting around TAMS

Every route, who may open it, what it goes back to, and what home means
there. The rule behind all of it: **nobody should ever reach a screen and
have the browser's Back button as their only way out.**

---

## 1. The TAMS name is always the way home

The name in the header is a link.

* **Signed out** → the public landing page.
* **Signed in** → that person's own home, never somebody else's:

| Who | Home |
| --- | --- |
| Council Administrator | `/dashboard` |
| Registry Clerk | `/registry` |
| Land Officer | `/land` |
| Council Secretary | `/secretary` |
| Resident | `/resident` |
| Signed in with no access | `/no-access` |

## 2. Route inventory

### Public — no account needed

| Route | Page | Back / home | Onward |
| --- | --- | --- | --- |
| `/` | Landing | — (this is home) | Sign in, Register, Verify a PTO |
| `/auth` | Sign in | ← Back to home | Register, Verify a PTO |
| `/register` | Create a resident account | ← Back to home | Sign in, Verify a PTO |
| `/set-password` | Set password from an invitation | TAMS name → home | Sign in; on an expired link, Sign in and Home |
| `/verify/pto` | Check a permission by reference | ← Back to TAMS home | Enter a reference |
| `/verify/pto/:token` | The result of a check | ← Back to TAMS home | Verify another PTO |
| `/no-access` | Signed in, but not allowed | TAMS name → home | Sign out, Back to home, Sign in |
| `*` | Not found | — | Go to my dashboard (signed in) or Go to home, Sign in |

### Any active staff member

| Route | Page | Back |
| --- | --- | --- |
| `/home` | My account | navigation |

### Council Administrator

| Route | Page | Back |
| --- | --- | --- |
| `/dashboard` | Dashboard | — |
| `/staff` | Staff accounts | Back to dashboard |
| `/staff/new` | Create staff account | ← Back to staff accounts |
| `/admin/audit` | Audit trail | Back to dashboard |
| `/admin/audit/:id` | One audit event | ← Back to the audit trail |
| `/admin/transfer` | Transfer administrator | ← Back to dashboard, and Cancel |

### Registry Clerk

| Route | Page | Back |
| --- | --- | --- |
| `/registry` | Dashboard | — |
| `/registry/residents` | Residents | Back to dashboard |
| `/registry/residents/new` | Create resident | ← Back, and Cancel |
| `/registry/residents/:id` | Resident | ← Back to residents |
| `/registry/residents/:id/edit` | Update resident | ← Back, and Cancel |
| `/registry/households` | Households | Back to dashboard |
| `/registry/households/:id` | Household | ← Back to households |
| `/registry/lineage` | Family lineage picker | Back to dashboard |
| `/registry/lineage/:id` | One person's lineage | ← Back to the resident |
| `/registry/resident-accounts` | Resident requests | Back to dashboard |
| `/registry/resident-accounts/:id` | One request | ← Back to requests |

### Land Officer

| Route | Page | Back |
| --- | --- | --- |
| `/land` | Dashboard | — |
| `/land/applications` | Applications | Back to dashboard |
| `/land/applications/:id` | Review | Back to applications |
| `/land/sites` | Land sites | Back to dashboard |
| `/land/sites/:id` | Site history | Back to sites |
| `/land/allocations` | Allocations | Back to dashboard |
| `/land/ptos` | Permissions | Back to dashboard |
| `/land/renewals` | Renewals | Back to dashboard |
| `/land/succession` | Succession | Back to dashboard |
| `/pto/:id` | The permission document | ← Back to permissions (officer) or Back to my land (resident), and Home |

### Council Secretary

| Route | Page | Back |
| --- | --- | --- |
| `/secretary` | Dashboard | — |
| `/secretary/meetings` | Meetings | Back to dashboard |
| `/secretary/meetings/:id` | One meeting | Back to meetings |
| `/secretary/resolutions` | Resolutions | Back to dashboard |
| `/secretary/projects` | Projects | Back to dashboard |
| `/secretary/projects/:id` | One project | Back to projects |

### Resident

| Route | Page | Back |
| --- | --- | --- |
| `/resident` | Home — account, land, community updates | — |
| `/pto/:id` | Their permission document | ← Back to my land |

## 3. The rules this follows

* **Every detail page** carries a contextual `← Back to …` naming the
  list it came from, as well as the navigation.
* **Every form** has a primary action and a **Cancel** that returns to a
  sensible parent, so nobody has to abandon a form with browser Back.
* **Every dialog** has Cancel beside its action. No dialog offers only a
  destructive choice.
* **Successful actions land somewhere useful** — an issued permission to
  its document, an approved application to the page where a site is
  allocated.
* **Breadcrumbs** appear on deeper pages, and every crumb is clickable.
* **The current section is marked** in the navigation.
* **Errors are never dead ends.** A record that is gone, an audit event that does not exist and an invalid PTO
  token each say so plainly and offer the list and the dashboard.
* **Unknown addresses** reach a Not Found page whose Home means that
  person's own dashboard, or the public landing page when signed out.
* **A link is never permission.** Navigation was made easier without a
  single policy being widened: the Registry Clerk who receives a link to
  a land application sees the reference, is told they cannot open it, and
  is offered the way back.

## 4. Small screens

Below 900px the navigation collapses into a **Menu** button. It exposes
every destination that role has, plus the account and Sign out. Nothing is permanently hidden. The header's actions wrap
rather than run off the edge.

## 5. Accessibility

Navigation is real `<a>` and `<button>` elements with understandable
labels, reachable by keyboard, with a visible focus ring. The menu button carries
`aria-expanded` and `aria-controls`; breadcrumbs are a `<nav>` with the
current page marked `aria-current`.

## 6. Tests

`tests/navigation.test.ts` checks the rules that can be checked without a
browser, and reads `src/App.tsx` to compare them against the routes the
application actually serves:

* where each role's home is, signed in and signed out;
* that every role is offered Dashboard and My account, and no Messages,
  Notifications or Communications;
* that a resident is offered no staff area at all;
* that only the Council Administrator is offered the audit trail and the
  transfer;
* that **no role is offered another role's area**;
* that **every navigation link is a route that exists**, and so is every
  role's home;
* that a catch-all route exists and renders the Not Found page;
* that a permission can be checked with or without a reference;
* that no navigation offers the same destination twice.
