import { useState } from "react";
import { Link, Navigate, useLocation, useNavigate } from "react-router-dom";
import { homePathFor, useSession } from "../auth/SessionProvider";
import { supabase } from "../lib/supabaseClient";
import { Field, Loading, Notice } from "../components/ui";
import { IDLE_SIGN_OUT_MESSAGE, wasSignedOutForIdling } from "../auth/idleTimeout";
import { residentSelfRegistrationEnabled } from "../lib/featureFlags";

/**
 * The single sign-in page for every staff role.
 *
 * Signing in only proves the password was right. Whether the person may
 * use the system is decided afterwards by the database record:
 * account_type, account_status, the staff record and the current role.
 */
export function SignIn() {
  const { loading, session, profile, refresh } = useSession();
  const navigate = useNavigate();
  const location = useLocation();
  // Arriving here because a session timed out is not an error the
  // person made, so it is said plainly and only once.
  const timedOut = wasSignedOutForIdling(location.search);

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (loading) return <Loading />;
  if (session) return <Navigate to={homePathFor(profile)} replace />;

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);

    if (!email.trim() || !password) {
      setError("Enter your email address and password.");
      return;
    }

    setSubmitting(true);
    const { error: signInError } = await supabase.auth.signInWithPassword({
      email: email.trim().toLowerCase(),
      password,
    });

    if (signInError) {
      setSubmitting(false);
      setError("Those sign-in details were not recognised.");
      return;
    }

    // Read the account from the database, then send the person to the
    // area their current role allows.
    const { data: context } = await supabase.rpc("current_staff_context");
    await supabase.rpc("record_login");
    await refresh();
    setSubmitting(false);
    navigate(homePathFor(context ?? null), { replace: true });
  }

  return (
    <div className="centre">
      <div className="centre-card narrow">
        <Link to="/" className="brand brand-link" aria-label="TAMS home">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </Link>

        <Link to="/" className="back-link" style={{ marginTop: 20 }}>← Back to home</Link>

        <h1 style={{ fontSize: 26, marginTop: 12 }}>Sign in</h1>
        <p style={{ color: "var(--muted)", margin: "8px 0 22px", fontSize: 14.5 }}>
          Use your email address and password.
        </p>

        {timedOut && !error
          ? <div style={{ marginBottom: 18 }}><Notice kind="info">{IDLE_SIGN_OUT_MESSAGE}</Notice></div>
          : null}

        <form onSubmit={handleSubmit} className="stack" noValidate>
          {error ? <Notice kind="error">{error}</Notice> : null}

          <Field label="Email" htmlFor="email">
            <input
              id="email"
              type="email"
              autoComplete="username"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
            />
          </Field>

          <Field label="Password" htmlFor="password">
            <div className="input-with-button">
              <input
                id="password"
                type={showPassword ? "text" : "password"}
                autoComplete="current-password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
              />
              <button
                type="button"
                className="reveal"
                onClick={() => setShowPassword((visible) => !visible)}
                aria-label={showPassword ? "Hide password" : "Show password"}
              >
                {showPassword ? "Hide" : "Show"}
              </button>
            </div>
          </Field>

          <button type="submit" className="btn btn-primary btn-block" disabled={submitting}>
            {submitting ? "Signing in…" : "Sign in"}
          </button>
        </form>

        <p className="forgot-password-line">
          <Link to="/forgot-password">Forgot password?</Link>
        </p>

        <div className="auth-footer">
          {residentSelfRegistrationEnabled
            ? <p>Don't have an account? <Link to="/register">Create one</Link></p>
            : <p>Council Administrator access only.</p>}
          <p>
            <Link to="/">Back to home</Link> · <Link to="/verify/pto">Verify a PTO</Link>
          </p>
        </div>
      </div>
    </div>
  );
}
