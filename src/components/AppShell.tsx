import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { Link, NavLink, useLocation } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { initialsOf } from "../lib/format";
import { homeFor, navigationFor } from "./navigation";

/**
 * The workspace frame: the TAMS name (which is always the way home),
 * the navigation for this user's role, and sign out. Nothing in here is ever the only way to leave a page — but
 * it is always there.
 */
export function AppShell({ children }: { children: ReactNode }) {
  const { profile, session, signOut } = useSession();
  const location = useLocation();
  const [menuOpen, setMenuOpen] = useState(false);

  const items = navigationFor(profile);
  const home = homeFor(profile, Boolean(session));

  // Choosing something closes the menu again.
  useEffect(() => { setMenuOpen(false); }, [location.pathname]);

  return (
    <div className="page">
      <header className="topbar">
        <Link to={home} className="brand brand-link" aria-label="TAMS home">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </Link>

        <button
          type="button"
          className="menu-toggle"
          aria-expanded={menuOpen}
          aria-controls="main-navigation"
          onClick={() => setMenuOpen((open) => !open)}
        >
          {menuOpen ? "Close menu" : "Menu"}
        </button>

        <nav id="main-navigation" className={`topnav${menuOpen ? " open" : ""}`} aria-label="Main">
          {items.map((item) => (
            <NavLink key={item.to} to={item.to} end={item.end}
                     className={({ isActive }) => isActive ? "active" : ""}>
              {item.label}
            </NavLink>
          ))}
        </nav>

        <div className={`who${menuOpen ? " open" : ""}`}>
          <div className="avatar" aria-hidden="true">
            {initialsOf(profile?.full_name ?? null, profile?.email ?? "")}
          </div>
          <span className="who-email">{profile?.email}</span>
          <button type="button" className="btn btn-ghost" onClick={() => void signOut()}>
            Sign out
          </button>
        </div>
      </header>

      {children}
    </div>
  );
}
