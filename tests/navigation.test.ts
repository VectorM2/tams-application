// Navigation rules: where the TAMS name takes each user, what their
// navigation offers, and that every offer is a route that exists.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { homeFor, navigationFor } from "../src/components/navigation.ts";
import type { StaffContext } from "../src/lib/types.ts";

function staff(role: string, overrides: Partial<StaffContext> = {}): StaffContext {
  return {
    account_type: "staff",
    access_granted: true,
    is_council_administrator: role === "Council Administrator",
    role_name: role,
    account_status: "active",
    first_name: "A",
    last_name: "Person",
    full_name: "A Person",
    email: "a.person@ta.example",
    employee_number: "2026099",
  } as unknown as StaffContext;
}

function resident(status = "active"): StaffContext {
  return {
    account_type: "resident",
    access_granted: false,
    is_council_administrator: false,
    role_name: null,
    account_status: status,
    email: "resident@village.example",
  } as unknown as StaffContext;
}

/** Every path the application actually serves. */
const routes = (() => {
  const source = readFileSync(new URL("../src/App.tsx", import.meta.url), "utf8");
  return new Set(
    [...source.matchAll(/<Route path="([^"]+)"/g)].map((match) => match[1]),
  );
})();

test("a signed-out visitor is sent to the public landing page", () => {
  assert.equal(homeFor(null, false), "/");
  assert.equal(homeFor(staff("Registry Clerk"), false), "/");
});

test("each role's home is its own dashboard, and never somebody else's", () => {
  assert.equal(homeFor(staff("Council Administrator"), true), "/dashboard");
  assert.equal(homeFor(staff("Registry Clerk"), true), "/registry");
  assert.equal(homeFor(staff("Land Officer"), true), "/land");
  assert.equal(homeFor(staff("Council Secretary"), true), "/secretary");
  assert.equal(homeFor(resident(), true), "/resident");
});

test("a signed-in account with no access goes somewhere that explains why", () => {
  const blocked = { ...staff("Registry Clerk"), access_granted: false } as StaffContext;
  assert.equal(homeFor(blocked, true), "/no-access");
  assert.equal(homeFor(null, true), "/no-access");
});

test("a pending or declined resident still lands on their own portal", () => {
  assert.equal(homeFor(resident("pending"), true), "/resident");
  assert.equal(homeFor(resident("declined"), true), "/resident");
});

test("every role is offered a dashboard and their own account, and no messages or notifications", () => {
  for (const role of ["Council Administrator", "Registry Clerk", "Land Officer", "Council Secretary"]) {
    const items = navigationFor(staff(role));
    const labels = items.map((item) => item.label);
    assert.ok(labels.includes("My account"), `${role} has no My account`);
    assert.ok(labels.includes("Dashboard"), `${role} has no Dashboard`);
    assert.ok(!items.some((item) => item.to.startsWith("/messages")), `${role} was offered Messages`);
    assert.ok(!items.some((item) => item.to.includes("notifications")), `${role} was offered Notifications`);
    assert.ok(!items.some((item) => item.to.includes("communications")), `${role} was offered Communications`);
  }
});

test("a resident is offered their home, and no staff area", () => {
  const items = navigationFor(resident());
  assert.deepEqual(items.map((item) => item.to), ["/resident"]);
  assert.ok(!items.some((item) => item.to.startsWith("/registry")));
  assert.ok(!items.some((item) => item.to.startsWith("/land")));
  assert.ok(!items.some((item) => item.to.startsWith("/secretary")));
  assert.ok(!items.some((item) => item.to.startsWith("/admin")));
});

test("only the Council Administrator is offered the audit trail and the transfer", () => {
  const admin = navigationFor(staff("Council Administrator")).map((item) => item.to);
  assert.ok(admin.includes("/admin/audit"));
  assert.ok(admin.includes("/admin/transfer"));

  for (const role of ["Registry Clerk", "Land Officer", "Council Secretary"]) {
    const items = navigationFor(staff(role)).map((item) => item.to);
    assert.ok(!items.includes("/admin/audit"), `${role} was offered the audit trail`);
    assert.ok(!items.includes("/admin/transfer"), `${role} was offered the transfer`);
  }
});

test("no role is offered another role's area", () => {
  const areas: Record<string, string> = {
    "Council Administrator": "/dashboard",
    "Registry Clerk": "/registry",
    "Land Officer": "/land",
    "Council Secretary": "/secretary",
  };
  for (const [role, own] of Object.entries(areas)) {
    for (const item of navigationFor(staff(role))) {
      const foreign = Object.entries(areas).find(
        ([otherRole, prefix]) => otherRole !== role && item.to.startsWith(prefix),
      );
      assert.equal(foreign, undefined,
        `${role} was offered ${item.to}, which belongs to ${foreign?.[0]}`);
    }
  }
});

test("every navigation link is a route the application actually serves", () => {
  const roles = [
    staff("Council Administrator"), staff("Registry Clerk"),
    staff("Land Officer"), staff("Council Secretary"), resident(),
  ];
  for (const profile of roles) {
    for (const item of navigationFor(profile)) {
      assert.ok(routes.has(item.to), `${item.to} is offered but is not a route`);
    }
  }
});

test("every role's home is a route the application actually serves", () => {
  for (const profile of [
    staff("Council Administrator"), staff("Registry Clerk"),
    staff("Land Officer"), staff("Council Secretary"), resident(),
  ]) {
    assert.ok(routes.has(homeFor(profile, true)), `${homeFor(profile, true)} is not a route`);
  }
  assert.ok(routes.has("/"));
  assert.ok(routes.has("/no-access"));
});

test("an unknown address is caught rather than left blank", () => {
  assert.ok(routes.has("*"), "there is no catch-all route");
  const source = readFileSync(new URL("../src/App.tsx", import.meta.url), "utf8");
  assert.match(source, /path="\*" element=\{<NotFound \/>\}/);
});

test("a permission to occupy can be checked with or without a reference", () => {
  assert.ok(routes.has("/verify/pto"), "there is no way to start a verification");
  assert.ok(routes.has("/verify/pto/:token"));
});

test("no navigation offers the same destination twice", () => {
  for (const profile of [
    staff("Council Administrator"), staff("Registry Clerk"),
    staff("Land Officer"), staff("Council Secretary"), resident(),
  ]) {
    const paths = navigationFor(profile).map((item) => item.to);
    assert.equal(new Set(paths).size, paths.length, `duplicate navigation for ${profile.role_name}`);
  }
});

test("nothing is offered to somebody with no profile at all", () => {
  assert.deepEqual(navigationFor(null), []);
});
