import { useSession } from "../auth/SessionProvider";
import { AppShell } from "../components/AppShell";
import { StatusBadge } from "../components/ui";
import { formatDateTime } from "../lib/format";

/**
 * What a Registry Clerk, Land Officer or Council Secretary sees after
 * signing in. Their own job functions have not been built yet, so this
 * confirms the account is working and nothing more.
 */
export function StaffHome() {
  const { profile } = useSession();
  if (!profile) return null;

  return (
    <AppShell>
      <div className="page-head">
        <h1>Welcome, {profile.first_name}</h1>
        <p>{profile.role_name} · Employee no. {profile.employee_number}</p>
      </div>

      <div className="grid-2">
        <div className="card">
          <h2 className="card-title">Your account</h2>
          <div className="detail-list">
            <div className="detail-item">
              <span className="label">Full name</span>
              <span className="value">{profile.full_name}</span>
            </div>
            <div className="detail-item">
              <span className="label">Employee number</span>
              <span className="value">{profile.employee_number}</span>
            </div>
            <div className="detail-item">
              <span className="label">Email</span>
              <span className="value">{profile.email}</span>
            </div>
            <div className="detail-item">
              <span className="label">Contact number</span>
              <span className="value">{profile.contact_number}</span>
            </div>
            <div className="detail-item">
              <span className="label">Current role</span>
              <span className="value">{profile.role_name}</span>
            </div>
            <div className="detail-item">
              <span className="label">Account status</span>
              <span className="value"><StatusBadge status={profile.account_status} /></span>
            </div>
            <div className="detail-item">
              <span className="label">Last sign-in</span>
              <span className="value">{formatDateTime(profile.last_login)}</span>
            </div>
          </div>
        </div>

        <div className="card">
          <h2 className="card-title">Your work area</h2>
          <div className="bullet-list">
            <p>
              No work area is assigned to the <strong>{profile.role_name}</strong> role.
              Your account is active and in good standing.
            </p>
            <p style={{ color: "var(--muted)" }}>
              If you expected to see one, or any of your details above are wrong, ask the
              Council Administrator.
            </p>
          </div>
        </div>
      </div>
    </AppShell>
  );
}
