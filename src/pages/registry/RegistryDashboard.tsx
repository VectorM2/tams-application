import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice } from "../../components/ui";
import { dashboardStats } from "../../registry/api";
import type { RegistryStats } from "../../registry/types";

export function RegistryDashboard() {
  const { profile } = useSession();
  const [stats, setStats] = useState<RegistryStats | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    dashboardStats().then((result) => {
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
          <Link to="/registry/residents" className="btn btn-ghost">Residents</Link>
          <Link to="/registry/residents/new" className="btn btn-primary">Create resident</Link>
        </div>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {!stats && !error ? <Loading what="Loading the register" /> : null}

      {stats
        ? (
          <>
            <div className="grid-4">
              <div className="stat">
                <div className="stat-label">Residents</div>
                <div className="stat-value">{stats.residents}</div>
                <div className="stat-note">On the village register</div>
              </div>
              <div className="stat">
                <div className="stat-label">Active residents</div>
                <div className="stat-value">{stats.active_residents}</div>
                <div className="stat-note">Not inactive or deceased</div>
              </div>
              <div className="stat">
                <div className="stat-label">Households</div>
                <div className="stat-value">{stats.households}</div>
                <div className="stat-note">Each on its own site</div>
              </div>
              <div className="stat">
                <div className="stat-label">Without a household</div>
                <div className="stat-value">{stats.residents_without_household}</div>
                <div className="stat-note">Waiting to be linked</div>
              </div>
            </div>

            <div className="grid-2" style={{ marginTop: 22 }}>
              <div className="card">
                <h2 className="card-title">Needs attention</h2>
                <div className="role-row">
                  <span>Residents not linked to a household</span>
                  <span className="count">{stats.residents_without_household}</span>
                </div>
                <div className="role-row">
                  <span>Households with no head designated</span>
                  <span className="count">{stats.households_without_head}</span>
                </div>
                <div className="role-row">
                  <span>Current family relationships recorded</span>
                  <span className="count">{stats.family_relationships}</span>
                </div>
              </div>

              <div className="card">
                <h2 className="card-title">Quick actions</h2>
                <div className="quick-actions">
                  <Link to="/registry/residents" className="btn btn-primary">Search the register</Link>
                  <Link to="/registry/households" className="btn btn-ghost">Households</Link>
                  <Link to="/registry/lineage" className="btn btn-ghost">Family lineage</Link>
                  <Link to="/registry/resident-accounts" className="btn btn-ghost">Resident requests</Link>
                </div>
              </div>
            </div>
          </>
        )
        : null}
    </AppShell>
  );
}
