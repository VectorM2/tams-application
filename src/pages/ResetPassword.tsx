import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { supabase } from "../lib/supabaseClient";
import {
  MINIMUM_PASSWORD_LENGTH, recoveryLinkProblem, validateNewPassword,
} from "../auth/passwordRules";
import { Field, Notice } from "../components/ui";

/**
 * Where a password reset link lands.
 *
 * The link signs the person in for this one purpose. All this page does
 * is give Supabase Auth a new password for that account. It changes no
 * TAMS record whatsoever: not the account type, not the account status,
 * not who the account is linked to, and not what role anybody holds. A
 * deactivated account is still deactivated afterwards, and will be
 * turned away at the door exactly as it was before.
 */
export function ResetPassword() {
  const { session, loading, cancelRecovery } = useSession();
  const navigate = useNavigate();

  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [linkProblem, setLinkProblem] = useState<string | null>(null);

  async function leaveRecovery(destination: string) {
    await cancelRecovery();
    navigate(destination, { replace: true });
  }

  // Supabase reports a stale or already-used link in the address itself.
  // Read it first, so the page can explain rather than sit blank.
  useEffect(() => {
    setLinkProblem(recoveryLinkProblem(window.location.hash, window.location.search));
  }, []);

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();

    const problem = validateNewPassword(password, confirmation);
    if (problem) { setError(problem); return; }
    setError(null);

    setSubmitting(true);
    const { error: updateError } = await supabase.auth.updateUser({ password });

    if (updateError) {
      setSubmitting(false);
      setError(
        updateError.message ||
        "The password could not be changed. The reset link may have expired — ask for another one.",
      );
      return;
    }

    // One line in the audit trail: who, and when. No password, no token,
    // no link. It is written while the recovery session is still alive.
    await supabase.rpc("record_password_reset");

    // The recovery session exists for this one job and is finished with.
    // Ending it means the next sign-in is an ordinary one, with the new
    // password, and settles their access the usual way.
    await cancelRecovery();
    setSubmitting(false);
    setDone(true);
  }

  if (done) {
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

          <h1 style={{ fontSize: 24, marginTop: 22 }}>Your password has been changed</h1>

          <div style={{ marginTop: 16 }}>
            <Notice kind="success">
              You can now sign in with your new password. Nothing else about your account has
              changed.
            </Notice>
          </div>

          <div className="row" style={{ justifyContent: "center", marginTop: 20 }}>
            <Link to="/auth" className="btn btn-primary">Go to sign in</Link>
            <Link to="/" className="btn btn-ghost">Back to home</Link>
          </div>
        </div>
      </div>
    );
  }

  if (loading) return <div className="loading">Checking your reset link…</div>;

  if (linkProblem || !session) {
    return (
      <div className="centre">
        <div className="centre-card narrow">
          <button type="button" className="brand brand-link brand-button" aria-label="TAMS home"
                  onClick={() => void leaveRecovery("/")}>
            <div className="brand-mark" aria-hidden="true">T</div>
            <div>
              <div className="brand-name">TAMS</div>
              <div className="brand-sub">Traditional Authority</div>
            </div>
          </button>

          <h1 style={{ fontSize: 24, marginTop: 22 }}>This reset link cannot be used</h1>

          <div style={{ marginTop: 16 }}>
            <Notice kind="error">
              {linkProblem ??
                "The link is missing, has already been used, or has expired. Reset links are " +
                "valid for a short time only."}
            </Notice>
          </div>

          <p className="auth-intro" style={{ marginTop: 16 }}>
            Ask for a new link and use it straight away. Opening it on the same device and browser
            you asked from works best.
          </p>

          <div className="row" style={{ justifyContent: "center" }}>
            <button type="button" className="btn btn-primary"
                    onClick={() => void leaveRecovery("/forgot-password")}>
              Request another reset link
            </button>
            <button type="button" className="btn btn-ghost"
                    onClick={() => void leaveRecovery("/auth")}>
              Back to sign in
            </button>
          </div>

          <div className="auth-footer">
            <p><button type="button" className="link-button"
                       onClick={() => void leaveRecovery("/")}>Back to TAMS home</button></p>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="centre">
      <div className="centre-card narrow">
        <button type="button" className="brand brand-link brand-button" aria-label="TAMS home"
                onClick={() => void leaveRecovery("/")}>
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </button>

        <h1 style={{ fontSize: 24, marginTop: 22 }}>Choose a new password</h1>
        <p className="auth-intro">
          You are resetting the password for <strong>{session.user.email}</strong>. Only your
          password changes — nothing else about your account.
        </p>

        <form onSubmit={handleSubmit} className="stack" noValidate>
          {error ? <Notice kind="error">{error}</Notice> : null}

          <Field
            label="New password"
            htmlFor="new-password"
            hint={`At least ${MINIMUM_PASSWORD_LENGTH} characters.`}
          >
            <div className="input-with-button">
              <input
                id="new-password"
                type={showPassword ? "text" : "password"}
                autoComplete="new-password"
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

          <Field label="Confirm new password" htmlFor="confirm-password">
            <input
              id="confirm-password"
              type={showPassword ? "text" : "password"}
              autoComplete="new-password"
              value={confirmation}
              onChange={(event) => setConfirmation(event.target.value)}
            />
          </Field>

          <button type="submit" className="btn btn-primary btn-block" disabled={submitting}>
            {submitting ? "Saving…" : "Save new password"}
          </button>
        </form>

        <div className="auth-footer">
          <p>
            Changed your mind?{" "}
            <button type="button" className="link-button"
                    onClick={() => void leaveRecovery("/auth")}>Back to sign in</button> ·{" "}
            <button type="button" className="link-button"
                    onClick={() => void leaveRecovery("/")}>Back to home</button>
          </p>
        </div>
      </div>
    </div>
  );
}
