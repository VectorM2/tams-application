import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabaseClient";
import type { StaffContext } from "../lib/types";

type SessionState = {
  /** Still working out who the user is. Nothing should be decided yet. */
  loading: boolean;
  session: Session | null;
  /** Read from the database on every load — never from the browser. */
  profile: StaffContext | null;
  /** The auth user signed in but has no user_accounts record at all. */
  accountMissing: boolean;
  /** A password-recovery session may change a password, but may not enter TAMS. */
  recoverySession: boolean;
  refresh: () => Promise<void>;
  signOut: () => Promise<void>;
  cancelRecovery: () => Promise<void>;
};

const SessionContext = createContext<SessionState | undefined>(undefined);

/** How often an open window re-checks that its account is still active. */
const ACCESS_RECHECK_INTERVAL_MS = 60_000;
const RECOVERY_SESSION_USER_KEY = "tams:password-recovery-user";

function storedRecoveryUser(): string | null {
  try { return window.localStorage.getItem(RECOVERY_SESSION_USER_KEY); }
  catch { return null; }
}

function rememberRecoveryUser(userId: string | null) {
  try {
    if (userId) window.localStorage.setItem(RECOVERY_SESSION_USER_KEY, userId);
    else window.localStorage.removeItem(RECOVERY_SESSION_USER_KEY);
  } catch { /* the route guard still protects this tab */ }
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<StaffContext | null>(null);
  const [accountMissing, setAccountMissing] = useState(false);
  const [recoverySession, setRecoverySession] = useState(false);

  // Ask the database who this user is. current_staff_context() works
  // from auth.uid(), so a tampered browser cannot change the answer.
  const loadProfile = useCallback(async (activeSession: Session | null) => {
    if (!activeSession) {
      setProfile(null);
      setAccountMissing(false);
      return;
    }
    const { data, error } = await supabase.rpc("current_staff_context");
    if (error) {
      setProfile(null);
      setAccountMissing(true);
      return;
    }
    setProfile((data as StaffContext) ?? null);
    setAccountMissing(data === null);
  }, []);

  useEffect(() => {
    let cancelled = false;

    supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled) return;
      setSession(data.session);
      const recovering = Boolean(
        data.session && storedRecoveryUser() === data.session.user.id,
      );
      setRecoverySession(recovering);
      if (recovering) {
        setProfile(null);
        setAccountMissing(false);
      } else {
        if (!data.session) rememberRecoveryUser(null);
        await loadProfile(data.session);
      }
      if (!cancelled) setLoading(false);
    });

    const { data: listener } = supabase.auth.onAuthStateChange(async (event, nextSession) => {
      if (cancelled) return;
      setSession(nextSession);
      setLoading(true);
      const recovering = Boolean(
        nextSession && (
          event === "PASSWORD_RECOVERY" || storedRecoveryUser() === nextSession.user.id
        ),
      );
      if (event === "PASSWORD_RECOVERY" && nextSession) {
        rememberRecoveryUser(nextSession.user.id);
      }
      if (!nextSession) rememberRecoveryUser(null);
      setRecoverySession(recovering);
      if (recovering) {
        setProfile(null);
        setAccountMissing(false);
      } else {
        await loadProfile(nextSession);
      }
      if (!cancelled) setLoading(false);
    });

    const adoptRecoveryFromAnotherTab = () => {
      void supabase.auth.getSession().then(({ data }) => {
        setRecoverySession(Boolean(
          data.session && storedRecoveryUser() === data.session.user.id,
        ));
      });
    };
    window.addEventListener("storage", adoptRecoveryFromAnotherTab);

    return () => {
      cancelled = true;
      listener.subscription.unsubscribe();
      window.removeEventListener("storage", adoptRecoveryFromAnotherTab);
    };
  }, [loadProfile]);

  // Access can be taken away while someone is sitting on a page. Their
  // browser is told nothing, so re-read the account from the database
  // whenever the window is used again, and periodically while it is
  // open. The moment account_status is no longer 'active', the route
  // guards send them to /no-access.
  //
  // This is a courtesy, not the enforcement: a deactivated session can
  // already read nothing and do nothing, because every protected
  // function and every Row Level Security policy checks the live
  // account_status for itself.
  useEffect(() => {
    if (!session) return;

    let cancelled = false;
    const revalidate = () => {
      if (cancelled || document.visibilityState === "hidden") return;
      void loadProfile(session);
    };

    window.addEventListener("focus", revalidate);
    document.addEventListener("visibilitychange", revalidate);
    const timer = window.setInterval(revalidate, ACCESS_RECHECK_INTERVAL_MS);

    return () => {
      cancelled = true;
      window.removeEventListener("focus", revalidate);
      document.removeEventListener("visibilitychange", revalidate);
      window.clearInterval(timer);
    };
  }, [session, loadProfile]);

  const refresh = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    setSession(data.session);
    await loadProfile(data.session);
  }, [loadProfile]);

  const signOut = useCallback(async () => {
    rememberRecoveryUser(null);
    setRecoverySession(false);
    await supabase.auth.signOut();
    setSession(null);
    setProfile(null);
    setAccountMissing(false);
  }, []);

  const cancelRecovery = useCallback(async () => {
    rememberRecoveryUser(null);
    setRecoverySession(false);
    await supabase.auth.signOut();
    setSession(null);
    setProfile(null);
    setAccountMissing(false);
  }, []);

  const value = useMemo<SessionState>(
    () => ({
      loading, session, profile, accountMissing, recoverySession,
      refresh, signOut, cancelRecovery,
    }),
    [
      loading, session, profile, accountMissing, recoverySession,
      refresh, signOut, cancelRecovery,
    ],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionState {
  const context = useContext(SessionContext);
  if (!context) throw new Error("useSession must be used inside a SessionProvider.");
  return context;
}

/** Where a signed-in user belongs, decided by their role in the database. */
export function homePathFor(profile: StaffContext | null): string {
  // A resident account is not staff and never has access_granted: where
  // it goes depends on its verification, which the portal shows.
  if (profile?.account_type === "resident") return "/resident";
  if (!profile || !profile.access_granted) return "/no-access";
  if (profile.is_council_administrator) return "/dashboard";
  if (profile.role_name === "Registry Clerk") return "/registry";
  if (profile.role_name === "Land Officer") return "/land";
  if (profile.role_name === "Council Secretary") return "/secretary";
  return "/home";
}
