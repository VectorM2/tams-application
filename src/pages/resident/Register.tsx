import { useState } from "react";
import { Link, Navigate } from "react-router-dom";
import { homePathFor, useSession } from "../../auth/SessionProvider";
import { supabase } from "../../lib/supabaseClient";
import { Field, Loading, Notice } from "../../components/ui";
import { residentSelfRegistrationEnabled } from "../../lib/featureFlags";

const MINIMUM_PASSWORD_LENGTH = 8;

/**
 * Registering for a resident account.
 *
 * This creates a sign-in and nothing more. Being on the village
 * register is a separate matter, decided by a Registry Clerk against
 * the official records — so nothing here writes to that register.
 */
export function Register() {
  const { loading, session, profile } = useSession();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  if (loading) return <Loading />;
  if (session) return <Navigate to={homePathFor(profile)} replace />;
  if (!residentSelfRegistrationEnabled) return <Navigate to="/auth" replace />;

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);

    if (password.length < MINIMUM_PASSWORD_LENGTH) {
      setError(`Your password must be at least ${MINIMUM_PASSWORD_LENGTH} characters.`);
      return;
    }
    if (password !== confirmation) {
      setError("The two passwords do not match.");
      return;
    }

    setSubmitting(true);
    const { data, error: signUpError } = await supabase.auth.signUp({
      email: email.trim().toLowerCase(),
      password,
      options: { emailRedirectTo: `${window.location.origin}/resident` },
    });
    setSubmitting(false);

    if (signUpError) {
      // Never confirm or deny that an address is already registered.
      setError(
        "An account with this email may already exist. Sign in to continue, or use " +
          "Forgot password to recover it.",
      );
      return;
    }

    // Supabase returns a user with no identities when the address is
    // already taken, rather than saying so. Same wording either way.
    if (data.user && (data.user.identities?.length ?? 0) === 0) {
      setError(
        "An account with this email may already exist. Sign in to continue, or use " +
          "Forgot password to recover it.",
      );
      return;
    }

    setDone(true);
  }

  if (done) {
    return (
      <div className="centre">
        <div className="centre-card narrow">
          <h1 style={{ fontSize: 24 }}>Check your email</h1>
          <p style={{ color: "var(--muted)", margin: "12px 0 20px", fontSize: 14.5 }}>
            We have sent a message to <strong>{email.trim().toLowerCase()}</strong>. Open it to
            confirm your address, then sign in to send us your verification details.
          </p>
          <div className="row" style={{ justifyContent: "center" }}>
            <Link to="/auth" className="btn btn-primary">Go to sign in</Link>
            <Link to="/" className="btn btn-ghost">Back to home</Link>
          </div>
        </div>
      </div>
    );
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

        <h1 style={{ fontSize: 26, marginTop: 12 }}>Create a resident account</h1>
        <p style={{ color: "var(--muted)", margin: "8px 0 22px", fontSize: 14.5 }}>
          First create your sign-in. You will then send your details and documents to the
          Registry Clerk, who checks them against the village register.
        </p>

        <form onSubmit={handleSubmit} className="stack" noValidate>
          {error ? <Notice kind="error">{error}</Notice> : null}

          <Field label="Email" htmlFor="email">
            <input id="email" type="email" autoComplete="username" value={email}
                   onChange={(event) => setEmail(event.target.value)} />
          </Field>

          <Field label="Password" htmlFor="password" hint={`At least ${MINIMUM_PASSWORD_LENGTH} characters.`}>
            <div className="input-with-button">
              <input id="password" type={showPassword ? "text" : "password"} autoComplete="new-password"
                     value={password} onChange={(event) => setPassword(event.target.value)} />
              <button type="button" className="reveal" onClick={() => setShowPassword((v) => !v)}
                      aria-label={showPassword ? "Hide password" : "Show password"}>
                {showPassword ? "Hide" : "Show"}
              </button>
            </div>
          </Field>

          <Field label="Confirm password" htmlFor="confirm">
            <input id="confirm" type={showPassword ? "text" : "password"} autoComplete="new-password"
                   value={confirmation} onChange={(event) => setConfirmation(event.target.value)} />
          </Field>

          <button type="submit" className="btn btn-primary btn-block" disabled={submitting}>
            {submitting ? "Creating your account…" : "Create account"}
          </button>
        </form>

        <div className="auth-footer">
          <p>Already have an account? <Link to="/auth">Sign in</Link>.</p>
          <p><Link to="/">Back to home</Link> · <Link to="/verify/pto">Verify a PTO</Link></p>
        </div>
      </div>
    </div>
  );
}
