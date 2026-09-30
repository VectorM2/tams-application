// =====================================================================
// The inactivity timeout.
//
// Every rule is a plain function over numbers, so the whole of this
// runs in a few milliseconds rather than the ninety minutes the real
// timeouts would take. The wiring that those rules drive is checked by
// reading IdleTimeoutGuard.tsx, which is how the rest of TAMS pins the
// parts that need a browser.
// =====================================================================

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  ACTIVITY_EVENTS, ACTIVITY_THROTTLE_MS, IDLE_SIGN_OUT_MESSAGE, IDLE_WARNING_MS,
  LAST_ACTIVITY_KEY, RESIDENT_IDLE_TIMEOUT_MS, SIGNED_OUT_KEY, STAFF_IDLE_TIMEOUT_MS,
  formatCountdown, idlePhase, idleSignOutPath, idleTimeoutFor, idleTimeoutOverrideMs,
  initialActivityAt, mergeActivity, msUntilTimeout, shouldRecordActivity, wasSignedOutForIdling,
} from "../src/auth/idleTimeout.ts";

const root = path.resolve(import.meta.dirname, "..");
const read = (file: string) => readFileSync(path.join(root, file), "utf8");

const MINUTE = 60 * 1000;

// ---------------------------------------------------------------------
// The two timeouts.
// ---------------------------------------------------------------------

test("a staff session times out after thirty minutes", () => {
  assert.equal(STAFF_IDLE_TIMEOUT_MS, 30 * MINUTE);
  for (const role of ["staff", "Registry Clerk", "Land Officer", "Council Secretary"]) {
    assert.equal(idleTimeoutFor(role), 30 * MINUTE, `${role} should time out in 30 minutes`);
  }
});

test("a resident session times out after sixty minutes", () => {
  assert.equal(RESIDENT_IDLE_TIMEOUT_MS, 60 * MINUTE);
  assert.equal(idleTimeoutFor("resident"), 60 * MINUTE);
});

test("an account of no known kind gets the shorter timeout, never the longer", () => {
  // Failing safe: an unrecognised account_type must not buy more time.
  for (const value of [null, undefined, "", "unknown", "RESIDENT"]) {
    assert.equal(idleTimeoutFor(value), STAFF_IDLE_TIMEOUT_MS, `${String(value)} got the wrong timeout`);
  }
});

// ---------------------------------------------------------------------
// The warning, two minutes out.
// ---------------------------------------------------------------------

test("the warning appears two minutes before the session ends", () => {
  assert.equal(IDLE_WARNING_MS, 2 * MINUTE);
});

test("a staff session is active, then warned, then expired", () => {
  const t = STAFF_IDLE_TIMEOUT_MS;
  assert.equal(idlePhase(0, t), "active");
  assert.equal(idlePhase(27 * MINUTE, t), "active");
  // The last moment before the warning window opens.
  assert.equal(idlePhase(28 * MINUTE - 1, t), "active");
  // The warning window itself.
  assert.equal(idlePhase(28 * MINUTE, t), "warning");
  assert.equal(idlePhase(29 * MINUTE, t), "warning");
  assert.equal(idlePhase(30 * MINUTE - 1, t), "warning");
  // And the end.
  assert.equal(idlePhase(30 * MINUTE, t), "expired");
  assert.equal(idlePhase(45 * MINUTE, t), "expired");
});

test("a resident session is warned at fifty-eight minutes", () => {
  const t = RESIDENT_IDLE_TIMEOUT_MS;
  assert.equal(idlePhase(57 * MINUTE, t), "active");
  assert.equal(idlePhase(58 * MINUTE, t), "warning");
  assert.equal(idlePhase(60 * MINUTE, t), "expired");
});

test("a timeout with no room for a warning expires without one", () => {
  // Only reachable through the development override. It must not warn
  // before the session has even started.
  assert.equal(idlePhase(0, 60 * 1000, 2 * MINUTE), "active");
  assert.equal(idlePhase(59 * 1000, 60 * 1000, 2 * MINUTE), "active");
  assert.equal(idlePhase(60 * 1000, 60 * 1000, 2 * MINUTE), "expired");
});

test("the countdown reads as minutes and seconds", () => {
  assert.equal(formatCountdown(2 * MINUTE), "2:00");
  assert.equal(formatCountdown(119_000), "1:59");
  assert.equal(formatCountdown(61_000), "1:01");
  assert.equal(formatCountdown(9_000), "0:09");
  assert.equal(formatCountdown(0), "0:00");
  assert.equal(formatCountdown(-5_000), "0:00", "a passed deadline never reads as negative");
});

test("the time remaining is never negative", () => {
  assert.equal(msUntilTimeout(10 * MINUTE, STAFF_IDLE_TIMEOUT_MS), 20 * MINUTE);
  assert.equal(msUntilTimeout(99 * MINUTE, STAFF_IDLE_TIMEOUT_MS), 0);
});

// ---------------------------------------------------------------------
// What counts as activity, and what does not.
// ---------------------------------------------------------------------

test("only a deliberate interaction is listened for", () => {
  assert.deepEqual([...ACTIVITY_EVENTS], ["pointerdown", "keydown", "touchstart"]);
});

test("nothing that happens on its own is treated as activity", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  // A pointer crossing the window, a page scrolling, a tab coming back
  // into view and a timer firing are all things that happen without
  // anybody deciding anything.
  for (const passive of ["mousemove", "mouseover", "scroll", "visibilitychange", "focus"]) {
    assert.ok(
      !guard.includes(`"${passive}"`),
      `${passive} must not reset the inactivity timer`,
    );
  }
});

test("the clock is only ever read, never treated as use of the system", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  const tick = guard.slice(guard.indexOf("const tick = window.setInterval"));
  const body = tick.slice(0, tick.indexOf("}, IDLE_CHECK_INTERVAL_MS)"));
  assert.ok(
    !body.includes("noteActivity"),
    "the interval that checks the clock must not also reset it",
  );
});

test("the account re-check that polls every minute does not hold a session open", () => {
  // SessionProvider re-reads the account from the database on a timer.
  // That is data polling, and the spec is explicit that polling must
  // not count as activity — so it must not touch the idle keys.
  const provider = read("src/auth/SessionProvider.tsx");
  assert.ok(!provider.includes(LAST_ACTIVITY_KEY));
  assert.ok(!provider.includes("noteActivity"));
  assert.ok(!provider.includes("idleTimeout"));
});

// ---------------------------------------------------------------------
// The throttle: activity is cheap to record.
// ---------------------------------------------------------------------

test("activity is written down at most once every thirty seconds", () => {
  assert.equal(ACTIVITY_THROTTLE_MS, 30 * 1000);

  const first = 1_000_000;
  assert.equal(shouldRecordActivity(first, Number.NEGATIVE_INFINITY), true, "the first one always counts");
  assert.equal(shouldRecordActivity(first + 1, first), false, "a keystroke later, nothing is written");
  assert.equal(shouldRecordActivity(first + 29_999, first), false);
  assert.equal(shouldRecordActivity(first + 30_000, first), true);
});

test("the throttle is far shorter than the shortest timeout", () => {
  // Otherwise somebody could be signed out while actively typing.
  assert.ok(ACTIVITY_THROTTLE_MS * 10 < STAFF_IDLE_TIMEOUT_MS);
});

// ---------------------------------------------------------------------
// More than one tab.
// ---------------------------------------------------------------------

test("a tab adopts another tab's more recent activity", () => {
  const now = 5_000_000;
  const mine = now - 20 * MINUTE;
  const theirs = now - 1 * MINUTE;
  assert.equal(mergeActivity(mine, String(theirs), now), theirs);
});

test("a tab keeps its own activity when it is the more recent one", () => {
  const now = 5_000_000;
  const mine = now - 1 * MINUTE;
  const theirs = now - 20 * MINUTE;
  assert.equal(mergeActivity(mine, String(theirs), now), mine);
});

test("a stored value from the future cannot hold a session open", () => {
  const now = 5_000_000;
  const mine = now - 10 * MINUTE;
  // A machine whose clock jumped, or a value somebody typed in.
  assert.equal(mergeActivity(mine, String(now + 24 * 60 * MINUTE), now), now);
});

test("unreadable stored activity is ignored rather than trusted", () => {
  const now = 5_000_000;
  const mine = now - 10 * MINUTE;
  for (const junk of [null, "", "soon", "NaN", undefined, {}]) {
    assert.equal(mergeActivity(mine, junk, now), mine, `${String(junk)} should be ignored`);
  }
});

// ---------------------------------------------------------------------
// Closing and reopening TAMS does not create activity.
// ---------------------------------------------------------------------

test("a restored session continues from its saved activity time", () => {
  const now = Date.parse("2026-09-30T08:30:00Z");
  const lastActivity = now - 45_000;
  const signedIn = new Date(now - 10 * MINUTE).toISOString();
  assert.equal(initialActivityAt(String(lastActivity), signedIn, now), lastActivity);
});

test("an expired restored session remains expired after reopening", () => {
  const now = Date.parse("2026-09-30T08:30:00Z");
  const lastActivity = now - 46_000;
  const initial = initialActivityAt(
    String(lastActivity), new Date(now - 10 * MINUTE).toISOString(), now,
  );
  assert.equal(idlePhase(now - initial, 45_000, 22_500), "expired");
});

test("a genuinely new sign-in starts later than stale activity", () => {
  const now = Date.parse("2026-09-30T08:30:00Z");
  const oldActivity = now - 20 * MINUTE;
  const newSignIn = now - 1_000;
  assert.equal(
    initialActivityAt(String(oldActivity), new Date(newSignIn).toISOString(), now),
    newSignIn,
  );
});

test("deleting activity storage cannot freshen an old restored session", () => {
  const now = Date.parse("2026-09-30T08:30:00Z");
  const signedIn = now - 2 * 60 * MINUTE;
  assert.equal(initialActivityAt(null, new Date(signedIn).toISOString(), now), signedIn);
});

test("a future or corrupt activity value cannot extend a session", () => {
  const now = Date.parse("2026-09-30T08:30:00Z");
  const signedIn = now - 5 * MINUTE;
  for (const stored of [String(now + MINUTE), "soon", "", null]) {
    assert.equal(
      initialActivityAt(stored, new Date(signedIn).toISOString(), now), signedIn,
    );
  }
});

test("the guard checks restored inactivity before starting its interval", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  const restore = guard.indexOf("const initialActivity = initialActivityAt");
  const expiry = guard.indexOf('initialPhase === "expired"');
  const interval = guard.indexOf("const tick = window.setInterval");
  assert.ok(restore >= 0 && restore < expiry && expiry < interval);
});

test("protected routes do not mount before a restored session is checked", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  const app = read("src/App.tsx");
  assert.match(guard, /checkedSessionUserId !== session\.user\.id\) return null/);
  assert.match(app, /<IdleTimeoutGuard>[\s\S]*<RecoverySessionBoundary>/);
  assert.match(app, /<\/RecoverySessionBoundary>[\s\S]*<\/IdleTimeoutGuard>/);
});

test("the guard preserves activity while authentication is still loading", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  assert.match(guard, /if \(loading\) return;/);
  assert.match(guard, /removeStored\(LAST_ACTIVITY_KEY\)/);
});

test("the tabs agree through two named keys and no others", () => {
  assert.equal(LAST_ACTIVITY_KEY, "tams.last-activity");
  assert.equal(SIGNED_OUT_KEY, "tams.signed-out-at");

  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  // A sign-out in one tab must reach the others.
  assert.match(guard, /window\.addEventListener\("storage", onStorage\)/);
  assert.match(guard, /event\.key === SIGNED_OUT_KEY/);
  assert.match(guard, /event\.key === LAST_ACTIVITY_KEY/);
});

test("signing out is written down before the session ends, so a sleeping tab still learns why", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  const endSession = guard.slice(guard.indexOf("const endSession"));
  const body = endSession.slice(0, endSession.indexOf("}, [signOut, navigate])"));
  assert.ok(
    body.indexOf("writeStored(SIGNED_OUT_KEY") < body.indexOf("await signOut()"),
    "the other tabs must be told before this one tears its session down",
  );
});

test("a tab that is already signing out does not do it twice", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  assert.match(guard, /if \(signingOutRef\.current\) return;/);
});

// ---------------------------------------------------------------------
// What happens at the end.
// ---------------------------------------------------------------------

test("the timeout signs out through Supabase and lands on sign in", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  assert.match(guard, /await signOut\(\)/, "it must go through the session provider's sign out");
  assert.match(guard, /navigate\(idleSignOutPath\(\), \{ replace: true \}\)/);

  // replace, so the page they were on is not left in the history for
  // the browser's Back button to return to.
  assert.ok(guard.includes("{ replace: true }"));
});

test("signOut in the session provider really does end the Supabase session", () => {
  const provider = read("src/auth/SessionProvider.tsx");
  const signOut = provider.slice(provider.indexOf("const signOut = useCallback"));
  const body = signOut.slice(0, signOut.indexOf("}, [])"));
  assert.match(body, /supabase\.auth\.signOut\(\)/);
  // And clears everything the browser was holding about the person.
  assert.match(body, /setSession\(null\)/);
  assert.match(body, /setProfile\(null\)/);
});

test("the sign-in page says why somebody was signed out", () => {
  assert.equal(idleSignOutPath(), "/auth?signed-out=idle");
  assert.equal(wasSignedOutForIdling("?signed-out=idle"), true);
  assert.equal(wasSignedOutForIdling("signed-out=idle"), true);
  assert.equal(wasSignedOutForIdling("?signed-out=something-else"), false);
  assert.equal(wasSignedOutForIdling(""), false);

  assert.equal(IDLE_SIGN_OUT_MESSAGE, "You were signed out after a period of inactivity.");
  assert.match(read("src/pages/SignIn.tsx"), /IDLE_SIGN_OUT_MESSAGE/);
});

test("manual sign out is untouched and still available", () => {
  const shell = read("src/components/AppShell.tsx");
  assert.match(shell, /signOut/, "the top bar must still offer a manual sign out");
});

// ---------------------------------------------------------------------
// The warning dialog itself.
// ---------------------------------------------------------------------

test("the warning offers exactly the two choices, and staying resets the timer", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  assert.match(guard, /Stay signed in/);
  assert.match(guard, /Sign out/);
  // Staying puts the timer back and takes the dialog away.
  assert.match(guard, /onClick=\{\(\) => \{ noteActivity\(\); setWarningRemainingMs\(null\); \}\}/);
});

test("the warning says what the spec asks it to say", () => {
  assert.match(
    read("src/auth/IdleTimeoutGuard.tsx"),
    /Your session will expire soon due to inactivity/,
  );
});

test("the warning warns about unsaved work rather than trying to keep it", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  assert.match(guard, /not saved will be lost/);
  // Sensitive half-finished work is never stashed anywhere.
  assert.ok(!/sessionStorage/.test(guard));
  assert.ok(!/draft/i.test(guard));
});

test("the warning never submits anything by itself", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  assert.ok(!guard.includes("requestSubmit"), "a timeout must never send a form");
  assert.ok(!guard.includes(".submit()"));
  assert.ok(!/<form/.test(guard));
});

test("the warning is a modal a screen reader announces", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  assert.match(guard, /role="alertdialog"/);
  assert.match(guard, /aria-modal="true"/);
  assert.match(guard, /aria-labelledby="idle-title"/);
  assert.match(guard, /aria-describedby="idle-body"/);
  assert.match(guard, /autoFocus/, "focus must land inside the dialog");
});

// ---------------------------------------------------------------------
// The timeout changes nothing but the session.
// ---------------------------------------------------------------------

test("a timeout never touches an account's role, type or standing", () => {
  // Comments stripped: what matters is the code, and the file's own
  // prose legitimately mentions staff and residents.
  const guard = read("src/auth/IdleTimeoutGuard.tsx")
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/^\s*\/\/.*$/gm, " ");

  for (const forbidden of [
    "account_status", "role_id", "user_accounts", "residents",
    "supabase.rpc", "supabase.from", "supabase.auth.updateUser",
  ]) {
    assert.ok(!guard.includes(forbidden), `the idle guard refers to ${forbidden}`);
  }

  // The only thing it reads from the profile is which kind of account
  // it is, and the only thing it does is end the session.
  const profileUses = [...guard.matchAll(/profile\??\.(\w+)/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(profileUses)], ["account_type"]);
});

test("a deactivated account stays blocked whatever the session does", () => {
  // Access is decided by the database on every read, not by how fresh
  // the session is. The guard has no say in it at all.
  const guards = read("src/components/guards.tsx");
  assert.match(guards, /!profile\.access_granted/);
  assert.ok(!guards.includes("idle"), "the route guards must not depend on the idle timer");
});

// ---------------------------------------------------------------------
// Trying it out without sitting still for half an hour.
// ---------------------------------------------------------------------

test("a development build honours a shortened timeout", () => {
  assert.equal(idleTimeoutOverrideMs("?idle-timeout=90", true), 90_000);
  assert.equal(idleTimeoutOverrideMs("idle-timeout=30", true), 30_000);
});

test("a production build ignores it completely", () => {
  assert.equal(idleTimeoutOverrideMs("?idle-timeout=90", false), null);
  assert.equal(idleTimeoutOverrideMs("?idle-timeout=999999", false), null);
});

test("a nonsensical override is ignored even in development", () => {
  for (const value of ["0", "-1", "abc", ""]) {
    assert.equal(idleTimeoutOverrideMs(`?idle-timeout=${value}`, true), null, `"${value}" was honoured`);
  }
  assert.equal(idleTimeoutOverrideMs("?other=1", true), null);
});

test("the override is gated on the build, not on anything a user controls", () => {
  const guard = read("src/auth/IdleTimeoutGuard.tsx");
  assert.match(guard, /idleTimeoutOverrideMs\(location\.search, import\.meta\.env\.DEV\)/);
});
