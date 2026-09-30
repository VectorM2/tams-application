import type { ReactNode } from "react";
import { Navigate, useLocation } from "react-router-dom";
import { useSession } from "./SessionProvider";

/**
 * Supabase recovery links create an authenticated session so the password
 * can be changed. That session is limited to the reset page and must never
 * become an ordinary TAMS sign-in when validation or updating fails.
 */
export function RecoverySessionBoundary({ children }: { children: ReactNode }) {
  const { loading, recoverySession } = useSession();
  const location = useLocation();

  if (!loading && recoverySession && location.pathname !== "/reset-password") {
    return <Navigate to="/reset-password" replace />;
  }

  return <>{children}</>;
}
