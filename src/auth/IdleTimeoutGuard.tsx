import { useCallback, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { useSession } from "./SessionProvider";
import {
  ACTIVITY_EVENTS, ACTIVITY_THROTTLE_MS, IDLE_CHECK_INTERVAL_MS, IDLE_WARNING_MS,
  LAST_ACTIVITY_KEY, SIGNED_OUT_KEY,
  formatCountdown, idlePhase, idleSignOutPath, idleTimeoutFor, idleTimeoutOverrideMs,
  initialActivityAt, mergeActivity, msUntilTimeout, shouldRecordActivity,
} from "./idleTimeout";

/** Browser storage that never throws, because a private window will. */
function writeStored(key: string, value: string): void {
  try { window.localStorage.setItem(key, value); } catch { /* nothing depends on it */ }
}

function readStored(key: string): string | null {
  try { return window.localStorage.getItem(key); } catch { return null; }
}

function removeStored(key: string): void {
  try { window.localStorage.removeItem(key); } catch { /* nothing depends on it */ }
}

/**
 * Ends a session that nobody is using.
 *
 * Sits inside the router and above every page, so it covers staff and
 * residents alike without each page having to know about it. It renders
 * nothing at all until the last two minutes.
 *
 * What it does NOT do is as important as what it does. The account
 * re-check that runs every minute, a tab becoming visible, a pointer
 * crossing the window and this component's own clock are all invisible
 * to it. Only a click, a key, a touch or a real navigation moves the
 * timer.
 */
export function IdleTimeoutGuard({ children }: { children: ReactNode }) {
  const { loading, session, profile, signOut } = useSession();
  const navigate = useNavigate();
  const location = useLocation();

  const [warningRemainingMs, setWarningRemainingMs] = useState<number | null>(null);
  const [checkedSessionUserId, setCheckedSessionUserId] = useState<string | null>(null);

  // Kept in refs, not state: activity must not re-render anything.
  const lastActivityRef = useRef(Date.now());
  const lastWrittenRef = useRef(Number.NEGATIVE_INFINITY);
  const signingOutRef = useRef(false);

  const timeoutMs =
    idleTimeoutOverrideMs(location.search, import.meta.env.DEV)
    ?? idleTimeoutFor(profile?.account_type);

  /** Somebody did something. Move the timer, and tell the other tabs. */
  const noteActivity = useCallback(() => {
    const now = Date.now();
    lastActivityRef.current = now;
    if (shouldRecordActivity(now, lastWrittenRef.current, ACTIVITY_THROTTLE_MS)) {
      lastWrittenRef.current = now;
      writeStored(LAST_ACTIVITY_KEY, String(now));
    }
  }, []);

  const endSession = useCallback(async () => {
    if (signingOutRef.current) return;
    signingOutRef.current = true;
    setWarningRemainingMs(null);
    setCheckedSessionUserId(null);
    // Written before signing out, so a tab that is asleep still finds
    // out why it was signed out when it wakes.
    writeStored(SIGNED_OUT_KEY, String(Date.now()));
    await signOut();
    navigate(idleSignOutPath(), { replace: true });
  }, [signOut, navigate]);

  // ---- while there is a session to look after -------------------------
  useEffect(() => {
    // SessionProvider has not finished restoring browser authentication.
    // Do not erase the saved clock while that decision is still pending.
    if (loading) return;

    if (!session) {
      signingOutRef.current = false;
      setWarningRemainingMs(null);
      setCheckedSessionUserId(null);
      removeStored(LAST_ACTIVITY_KEY);
      return;
    }

    // Continue the clock across reloads and closed tabs. A genuinely new
    // sign-in has a newer last_sign_in_at and therefore starts a new clock.
    const now = Date.now();
    const initialActivity = initialActivityAt(
      readStored(LAST_ACTIVITY_KEY), session.user.last_sign_in_at, now,
    );
    lastActivityRef.current = initialActivity;
    lastWrittenRef.current = initialActivity;
    writeStored(LAST_ACTIVITY_KEY, String(initialActivity));

    // Check before the first five-second interval. An already expired
    // restored session must never render a fresh privileged window.
    const initialIdleMs = now - initialActivity;
    const initialPhase = idlePhase(
      initialIdleMs, timeoutMs, Math.min(IDLE_WARNING_MS, timeoutMs / 2),
    );
    if (initialPhase === "expired") { void endSession(); return; }
    setWarningRemainingMs(
      initialPhase === "warning" ? msUntilTimeout(initialIdleMs, timeoutMs) : null,
    );
    setCheckedSessionUserId(session.user.id);

    for (const name of ACTIVITY_EVENTS) {
      window.addEventListener(name, noteActivity, { passive: true });
    }

    // Another tab either was used, or signed out. Either way this tab
    // must agree with it rather than carry on by itself.
    const onStorage = (event: StorageEvent) => {
      if (event.key === LAST_ACTIVITY_KEY) {
        lastActivityRef.current = mergeActivity(
          lastActivityRef.current, event.newValue, Date.now(),
        );
        return;
      }
      if (event.key === SIGNED_OUT_KEY && event.newValue) {
        void endSession();
      }
    };
    window.addEventListener("storage", onStorage);

    // Reading the clock is not using the system, so this only looks.
    const tick = window.setInterval(() => {
      const idleMs = Date.now() - lastActivityRef.current;
      const phase = idlePhase(idleMs, timeoutMs, Math.min(IDLE_WARNING_MS, timeoutMs / 2));

      if (phase === "expired") { void endSession(); return; }
      setWarningRemainingMs(phase === "warning" ? msUntilTimeout(idleMs, timeoutMs) : null);
    }, IDLE_CHECK_INTERVAL_MS);

    return () => {
      for (const name of ACTIVITY_EVENTS) window.removeEventListener(name, noteActivity);
      window.removeEventListener("storage", onStorage);
      window.clearInterval(tick);
    };
  }, [loading, session, timeoutMs, noteActivity, endSession]);

  // Moving to another page is somebody working, so it counts. The first
  // render of a page is not a navigation, which is why this watches the
  // path rather than running unconditionally.
  const previousPath = useRef(location.pathname);
  useEffect(() => {
    if (previousPath.current === location.pathname) return;
    previousPath.current = location.pathname;
    if (session) noteActivity();
  }, [location.pathname, session, noteActivity]);

  // Do not mount protected pages until a restored session has passed the
  // inactivity check. This also prevents their data-loading effects from
  // running during the check.
  if (session && checkedSessionUserId !== session.user.id) return null;

  return (
    <>
      {children}
      {session && warningRemainingMs !== null ? (
      <div className="backdrop" role="presentation">
      <div
        className="dialog idle-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="idle-title"
        aria-describedby="idle-body"
      >
        <h2 id="idle-title">Still there?</h2>
        <p id="idle-body" className="dialog-intro">
          Your session will expire soon due to inactivity. You will be signed out in{" "}
          <strong>{formatCountdown(warningRemainingMs)}</strong>.
        </p>
        <p className="muted-note" style={{ marginTop: 12 }}>
          Anything you have typed but not saved will be lost, so save it now if you need it.
        </p>
        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={() => void endSession()}>
            Sign out
          </button>
          <button
            type="button"
            className="btn btn-primary"
            autoFocus
            onClick={() => { noteActivity(); setWarningRemainingMs(null); }}
          >
            Stay signed in
          </button>
        </div>
      </div>
      </div>
      ) : null}
    </>
  );
}
