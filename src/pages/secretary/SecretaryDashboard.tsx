import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { secretaryDashboard } from "../../registry/secretaryApi";
import type { SecretaryDashboard as Dashboard } from "../../registry/secretaryTypes";

/** What the Council Secretary has waiting for them. */
export function SecretaryDashboard() {
  const { profile } = useSession();
  const [stats, setStats] = useState<Dashboard | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    secretaryDashboard().then((result) => {
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
          <Link to="/secretary/projects" className="btn btn-ghost">Projects</Link>
          <Link to="/secretary/meetings" className="btn btn-primary">Meetings</Link>
        </div>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {!stats && !error ? <Loading what="Loading the council records" /> : null}

      {stats
        ? (
          <>
            <div className="grid-4">
              <div className="stat">
                <div className="stat-label">Upcoming meetings</div>
                <div className="stat-value">{stats.upcoming_meetings}</div>
                <div className="stat-note">Scheduled, today or later</div>
              </div>
              <div className="stat">
                <div className="stat-label">Awaiting minutes</div>
                <div className="stat-value">{stats.meetings_awaiting_minutes}</div>
                <div className="stat-note">Held, with no final minutes yet</div>
              </div>
              <div className="stat">
                <div className="stat-label">Draft minutes</div>
                <div className="stat-value">{stats.draft_minutes}</div>
                <div className="stat-note">Started but not confirmed</div>
              </div>
              <div className="stat">
                <div className="stat-label">Overdue milestones</div>
                <div className="stat-value">{stats.overdue_milestones}</div>
                <div className="stat-note">Past their due date, unfinished</div>
              </div>
            </div>

            <div className="grid-4" style={{ marginTop: 18 }}>
              <div className="stat">
                <div className="stat-label">Active resolutions</div>
                <div className="stat-value">{stats.active_resolutions}</div>
                <div className="stat-note">Decided and not yet carried out</div>
              </div>
              <div className="stat">
                <div className="stat-label">Active projects</div>
                <div className="stat-value">{stats.active_projects}</div>
                <div className="stat-note">Under way now</div>
              </div>
              <div className="stat">
                <div className="stat-label">Published resolutions</div>
                <div className="stat-value">{stats.public_resolutions}</div>
                <div className="stat-note">Public, from confirmed minutes</div>
              </div>
              <div className="stat">
                <div className="stat-label">Published projects</div>
                <div className="stat-value">{stats.public_projects}</div>
                <div className="stat-note">Visible in Community Updates</div>
              </div>
            </div>

            <div className="grid-2" style={{ marginTop: 22 }}>
              <div className="card">
                <h2 className="card-title">Needs attention</h2>
                <div className="role-row">
                  <span><Link to="/secretary/meetings?status=held">Meetings awaiting minutes</Link></span>
                  <span className="count">{stats.meetings_awaiting_minutes}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/secretary/meetings?status=held">Minutes still in draft</Link></span>
                  <span className="count">{stats.draft_minutes}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/secretary/projects?status=active">Overdue milestones</Link></span>
                  <span className="count">{stats.overdue_milestones}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/secretary/projects?status=planned">Projects not yet started</Link></span>
                  <span className="count">{stats.planned_projects}</span>
                </div>

                {stats.next_meeting
                  ? (
                    <div style={{ marginTop: 18 }}>
                      <div className="section-heading">Next meeting</div>
                      <Link to={`/secretary/meetings/${stats.next_meeting.meeting_id}`}
                            className="name">
                        {stats.next_meeting.meeting_reference} · {stats.next_meeting.title}
                      </Link>
                      <div className="status-note">
                        {formatDate(stats.next_meeting.meeting_date)} at{" "}
                        {stats.next_meeting.start_time.slice(0, 5)} · {stats.next_meeting.venue}
                      </div>
                    </div>
                  )
                  : <p className="muted-note" style={{ marginTop: 18 }}>No meeting is scheduled.</p>}
              </div>

              <div className="card">
                <h2 className="card-title">Quick actions</h2>
                <div className="quick-actions">
                  <Link to="/secretary/meetings" className="btn btn-primary">Meetings</Link>
                  <Link to="/secretary/resolutions" className="btn btn-ghost">Resolutions</Link>
                  <Link to="/secretary/projects" className="btn btn-ghost">Projects</Link>
                </div>
              </div>
            </div>
          </>
        )
        : null}
    </AppShell>
  );
}
