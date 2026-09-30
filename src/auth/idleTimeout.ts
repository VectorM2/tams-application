// =====================================================================
// Signing out somebody who has walked away.
//
// A TAMS window left open on a shared office machine is the same thing
// as an unlocked filing cabinet: the register, the land records and the
// audit trail are all one click away. So a session that nobody is using
// ends by itself.
//
// Everything here is a plain function over numbers and strings. The
// browser wiring lives in IdleTimeoutGuard.tsx, so that these rules can
// be tested in Node without waiting half an hour for anything.
// =====================================================================

/** Staff reach the whole register, so their window closes sooner. */
export const STAFF_IDLE_TIMEOUT_MS = 30 * 60 * 1000;

/** A resident sees only their own affairs, and is given longer. */
export const RESIDENT_IDLE_TIMEOUT_MS = 60 * 60 * 1000;

/** How long the warning is on screen before the session actually ends. */
export const IDLE_WARNING_MS = 2 * 60 * 1000;

/**
 * Activity is recorded at most this often.
 *
 * Somebody typing produces a keystroke every few hundred milliseconds.
 * Writing each one to storage would be thousands of writes an hour and
 * would wake every other tab each time. Half a minute of granularity
 * costs nothing: the shortest timeout is sixty times longer.
 */
export const ACTIVITY_THROTTLE_MS = 30 * 1000;

/** How often the clock is examined. Reading never counts as activity. */
export const IDLE_CHECK_INTERVAL_MS = 5 * 1000;

/**
 * What counts as a person using TAMS.
 *
 * Deliberately narrow. A pointer moving across the window, a page
 * scrolling on its own, a tab becoming visible again and the account
 * re-check that runs every minute are all things that happen without
 * anybody deciding anything, so none of them are here. A click, a key,
 * a touch and a real navigation are decisions.
 */
export const ACTIVITY_EVENTS = ["pointerdown", "keydown", "touchstart"] as const;

/** Where the tabs agree with each other. */
export const LAST_ACTIVITY_KEY = "tams.last-activity";
export const SIGNED_OUT_KEY = "tams.signed-out-at";

/** Why the sign-in page is showing a message. */
export const IDLE_SIGN_OUT_REASON = "idle";
export const IDLE_SIGN_OUT_MESSAGE =
  "You were signed out after a period of inactivity.";

/** What the database says this account is. Anything that is not a
 *  resident is treated as staff, which is the shorter timeout: an
 *  unrecognised value must never buy somebody more time. */
export type AccountType = string | null | undefined;

/** How long this kind of account may sit untouched. */
export function idleTimeoutFor(accountType: AccountType): number {
  return accountType === "resident" ? RESIDENT_IDLE_TIMEOUT_MS : STAFF_IDLE_TIMEOUT_MS;
}

export type IdlePhase = "active" | "warning" | "expired";

/**
 * Where a session stands, given how long it has been untouched.
 *
 * The warning window is the last `warningMs` before the timeout. If a
 * timeout were ever configured shorter than its own warning, the
 * warning would have to start before the session did; in that case the
 * session simply goes straight from active to expired rather than
 * showing a warning it has no room for.
 */
export function idlePhase(
  idleMs: number,
  timeoutMs: number,
  warningMs: number = IDLE_WARNING_MS,
): IdlePhase {
  if (idleMs >= timeoutMs) return "expired";
  if (warningMs >= timeoutMs) return "active";
  if (idleMs >= timeoutMs - warningMs) return "warning";
  return "active";
}

/** Milliseconds left before the session ends. Never negative. */
export function msUntilTimeout(idleMs: number, timeoutMs: number): number {
  return Math.max(0, timeoutMs - idleMs);
}

/** The countdown as it is read aloud on the warning: "1:59". */
export function formatCountdown(remainingMs: number): string {
  const total = Math.max(0, Math.ceil(remainingMs / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

/**
 * Whether this activity is recent enough to be worth writing down.
 *
 * Returning false is the throttle: the timer has not moved far enough
 * for the record to be stale, so nothing is written and no other tab is
 * disturbed.
 */
export function shouldRecordActivity(
  now: number,
  lastRecorded: number,
  throttleMs: number = ACTIVITY_THROTTLE_MS,
): boolean {
  if (!Number.isFinite(lastRecorded)) return true;
  return now - lastRecorded >= throttleMs;
}

/**
 * The most recent activity this tab knows about.
 *
 * Another tab may have been used more recently than this one, and it is
 * the same person at the same desk, so the later of the two wins. A
 * stored value from the future — a machine whose clock moved — is not
 * trusted to hold a session open, so it is clamped to now.
 */
export function mergeActivity(own: number, stored: unknown, now: number): number {
  const parsed = typeof stored === "string" ? Number.parseInt(stored, 10) : Number.NaN;
  const candidate = Number.isFinite(parsed) ? Math.min(parsed, now) : Number.NEGATIVE_INFINITY;
  return Math.max(own, candidate);
}

/**
 * Establish the activity time when TAMS opens around an existing session.
 *
 * Browser storage survives a closed tab and a stopped development server.
 * Reopening the app must therefore continue from the saved activity time,
 * not silently turn the reload into fresh activity.  The authentication
 * service's last sign-in time is the fallback when storage is absent, and
 * also separates a genuinely new sign-in from an older user's timestamp.
 */
export function initialActivityAt(
  storedActivity: unknown,
  lastSignInAt: unknown,
  now: number,
): number {
  const stored = typeof storedActivity === "string"
    ? Number.parseInt(storedActivity, 10)
    : Number.NaN;
  const signedIn = typeof lastSignInAt === "string"
    ? Date.parse(lastSignInAt)
    : Number.NaN;

  const safeStored = Number.isFinite(stored) && stored > 0 && stored <= now
    ? stored
    : Number.NEGATIVE_INFINITY;
  const safeSignIn = Number.isFinite(signedIn) && signedIn > 0 && signedIn <= now
    ? signedIn
    : Number.NEGATIVE_INFINITY;

  const activity = Math.max(safeStored, safeSignIn);
  return Number.isFinite(activity) ? activity : now;
}

/**
 * The sign-in address to land on after an automatic sign-out, so the
 * page can explain itself rather than appearing for no reason.
 */
export function idleSignOutPath(): string {
  return `/auth?signed-out=${IDLE_SIGN_OUT_REASON}`;
}

/** True when the sign-in page arrived here because a session timed out. */
export function wasSignedOutForIdling(search: string): boolean {
  return new URLSearchParams(search.replace(/^\?/, "")).get("signed-out") === IDLE_SIGN_OUT_REASON;
}

/**
 * A shorter timeout, for trying this out without sitting still for half
 * an hour. `?idle-timeout=90` makes the session last ninety seconds.
 *
 * Only ever honoured in a development build. In a production build the
 * parameter is ignored completely, so nobody can shorten — or lengthen
 * — a real session by editing the address bar.
 */
export function idleTimeoutOverrideMs(search: string, isDevelopment: boolean): number | null {
  if (!isDevelopment) return null;
  const raw = new URLSearchParams(search.replace(/^\?/, "")).get("idle-timeout");
  if (raw === null) return null;
  const seconds = Number.parseInt(raw, 10);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  return seconds * 1000;
}
