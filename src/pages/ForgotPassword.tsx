import { useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../lib/supabaseClient";
import { passwordResetRedirect } from "../lib/appUrl";
import { looksLikeEmail, RESET_REQUESTED_MESSAGE } from "../auth/passwordRules";
import { Field, Notice } from "../components/ui";
import { residentSelfRegistrationEnabled } from "../lib/featureFlags";

/**
 * Asking for a password reset link. Open to everybody — residents and
 * every staff role sign in through the same Supabase Auth, so they all
 * recover a password the same way.
 *
 * The answer is the same whether the address belongs to an account or
 * not. Saying "no account with that address" would tell anybody who
 * asked which addresses are registered here, and there is no good
 * reason to do that.
 */
export function ForgotPassword() {
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);

    const address = email.trim().toLowerCase();
    if (!looksLikeEmail(address)) {
      setError("Enter the email address you sign in with.");
      return;
    }

    setSubmitting(true);
    // Supabase Auth's own password recovery. TAMS mints no token of its
    // own, stores none, and never learns whether this address exists:
    // the answer below is written before the call and does not depend
    // on it.
    await supabase.auth.resetPasswordForEmail(address, {
      redirectTo: passwordResetRedirect(),
    });
    setSubmitting(false);
    setSent(true);
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

        <Link to="/auth" className="back-link" style={{ marginTop: 20 }}>← Back to sign in</Link>

        <h1 style={{ fontSize: 24, marginTop: 12 }}>Forgot your password?</h1>

        {sent
          ? (
            <>
              <div style={{ marginTop: 18 }}>
                <Notice kind="success">{RESET_REQUESTED_MESSAGE}</Notice>
              </div>
              <p className="auth-intro" style={{ marginTop: 16 }}>
                The link is valid for a short time. If it expires before you use it, come back
                here and ask for another one.
              </p>
              <div className="row" style={{ justifyContent: "center", marginTop: 6 }}>
                <Link to="/auth" className="btn btn-primary">Go to sign in</Link>
                <button type="button" className="btn btn-ghost"
                        onClick={() => { setSent(false); setEmail(""); }}>
                  Send another link
                </button>
              </div>
            </>
          )
          : (
            <>
              <p className="auth-intro">
                Enter the email address you sign in with and we will send you a link to choose a
                new password. This works for residents and for every staff role.
              </p>

              <form onSubmit={handleSubmit} className="stack" noValidate>
                {error ? <Notice kind="error">{error}</Notice> : null}

                <Field label="Email address" htmlFor="reset-email">
                  <input
                    id="reset-email"
                    type="email"
                    autoComplete="username"
                    autoFocus
                    value={email}
                    onChange={(event) => setEmail(event.target.value)}
                  />
                </Field>

                <button type="submit" className="btn btn-primary btn-block" disabled={submitting}>
                  {submitting ? "Sending…" : "Send reset link"}
                </button>
              </form>
            </>
          )}

        <div className="auth-footer">
          <p>
            Remembered it? <Link to="/auth">Sign in</Link>.
          </p>
          {residentSelfRegistrationEnabled
            ? <p>Don't have an account? Residents can <Link to="/register">create one</Link>.</p>
            : null}
          <p>
            <Link to="/">Back to home</Link> · <Link to="/verify/pto">Verify a PTO</Link>
          </p>
        </div>
      </div>
    </div>
  );
}
