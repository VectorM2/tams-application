import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice } from "../../components/ui";
import { officerDashboard } from "../../registry/landApi";
import type { OfficerDashboard } from "../../registry/landTypes";

/** What the Land Officer has waiting for them. */
export function LandDashboard() {
  const { profile } = useSession();
  const [stats, setStats] = useState<OfficerDashboard | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    officerDashboard().then((result) => {
      if (cancelled) return;
      if (result.ok) setStats(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, []);

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>Welcome, {profile?.first_name}</h1>
          <p>{profile?.role_name} · Employee no. {profile?.employee_number}</p>
        </div>
        <div className="row">
          <Link to="/land/sites" className="btn btn-ghost">Land sites</Link>
          <Link to="/land/applications" className="btn btn-primary">Applications</Link>
        </div>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {!stats && !error ? <Loading what="Loading the land register" /> : null}

      {stats
        ? (
          <>
            <div className="grid-4">
              <div className="stat">
                <div className="stat-label">Waiting for review</div>
                <div className="stat-value">{stats.pending_applications}</div>
                <div className="stat-note">Applications nobody has looked at</div>
              </div>
              <div className="stat">
                <div className="stat-label">Approved, not allocated</div>
                <div className="stat-value">{stats.awaiting_allocation}</div>
                <div className="stat-note">Approved and waiting for a site</div>
              </div>
              <div className="stat">
                <div className="stat-label">Available sites</div>
                <div className="stat-value">{stats.available_sites}</div>
                <div className="stat-note">Free to allocate</div>
              </div>
              <div className="stat">
                <div className="stat-label">Active allocations</div>
                <div className="stat-value">{stats.active_allocations}</div>
                <div className="stat-note">Land currently held</div>
              </div>
            </div>

            <div className="grid-4" style={{ marginTop: 18 }}>
              <div className="stat">
                <div className="stat-label">Active permissions</div>
                <div className="stat-value">{stats.active_ptos}</div>
                <div className="stat-note">PTOs that are current today</div>
              </div>
              <div className="stat">
                <div className="stat-label">Lapsed permissions</div>
                <div className="stat-value">{stats.expired_ptos}</div>
                <div className="stat-note">Past their expiry date</div>
              </div>
              <div className="stat">
                <div className="stat-label">Renewal requests</div>
                <div className="stat-value">{stats.pending_renewals}</div>
                <div className="stat-note">Farming and business only</div>
              </div>
              <div className="stat">
                <div className="stat-label">Waiting for succession</div>
                <div className="stat-value">{stats.succession_pending}</div>
                <div className="stat-note">Holder recorded as deceased</div>
              </div>
            </div>

            <div className="grid-2" style={{ marginTop: 22 }}>
              <div className="card">
                <h2 className="card-title">Needs attention</h2>
                <div className="role-row">
                  <span><Link to="/land/applications">Applications waiting for review</Link></span>
                  <span className="count">{stats.pending_applications}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/land/applications?status=approved">Approved, waiting for a site</Link></span>
                  <span className="count">{stats.awaiting_allocation}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/land/renewals">Renewal requests</Link></span>
                  <span className="count">{stats.pending_renewals}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/land/succession">Residential succession</Link></span>
                  <span className="count">{stats.succession_pending}</span>
                </div>
                <div className="role-row">
                  <span>Burial plots still usable</span>
                  <span className="count">{stats.burial_plots_usable}</span>
                </div>
              </div>

              <div className="card">
                <h2 className="card-title">Quick actions</h2>
                <div className="quick-actions">
                  <Link to="/land/applications" className="btn btn-primary">Applications</Link>
                  <Link to="/land/sites" className="btn btn-ghost">Land sites</Link>
                  <Link to="/land/allocations" className="btn btn-ghost">Allocations</Link>
                  <Link to="/land/ptos" className="btn btn-ghost">Permissions to occupy</Link>
                  <Link to="/land/renewals" className="btn btn-ghost">Renewals</Link>
                </div>
              </div>
            </div>
          </>
        )
        : null}
    </AppShell>
  );
}
