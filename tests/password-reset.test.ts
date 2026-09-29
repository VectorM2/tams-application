// Forgot password and password reset.
//
// The rules are pure and are tested directly. The pages themselves are
// checked by reading their source, which is how the rest of this suite
// checks things a browser would otherwise be needed for: that a route
// exists, that a link is offered, and — most importantly — that the
// reset uses Supabase Auth and touches nothing else.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  looksLikeEmail,
  MINIMUM_PASSWORD_LENGTH,
  recoveryLinkProblem,
  RESET_REQUESTED_MESSAGE,
  resetRedirectUrl,
  validateNewPassword,
} from "../src/auth/passwordRules.ts";

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

const app = read("src/App.tsx");
const signIn = read("src/pages/SignIn.tsx");
const forgot = read("src/pages/ForgotPassword.tsx");
const reset = read("src/pages/ResetPassword.tsx");
const setPassword = read("src/pages/SetPassword.tsx");
const sessionProvider = read("src/auth/SessionProvider.tsx");
const recoveryBoundary = read("src/auth/RecoverySessionBoundary.tsx");
const migration = read("supabase/migrations/20261003090000_password_reset_audit.sql");

const routes = new Set([...app.matchAll(/<Route path="([^"]+)"/g)].map((m) => m[1]));

// ---- 1, 2, 5: the way in exists ---------------------------------------

test("the sign-in page offers a forgot-password link", () => {
  assert.match(signIn, /to="\/forgot-password"/);
  assert.match(signIn, /Forgot password\?/);
});

test("the forgot-password and reset-password routes exist", () => {
  assert.ok(routes.has("/forgot-password"));
  assert.ok(routes.has("/reset-password"));
});

test("forgot password is reachable without signing in", () => {
  // Neither route sits behind a guard: a person who cannot sign in is
  // exactly the person who needs them.
  for (const path of ["/forgot-password", "/reset-password"]) {
    const line = app.split("\n").find((l) => l.includes(`path="${path}"`)) ?? "";
    assert.ok(!line.includes("Require"), `${path} is behind a guard`);
  }
});

// ---- 3, 4: Supabase Auth, and saying nothing about who has an account --

test("a request for a link calls Supabase Auth's own password recovery", () => {
  assert.match(forgot, /supabase\.auth\.resetPasswordForEmail\(/);
  assert.match(forgot, /redirectTo: passwordResetRedirect\(\)/);
});

test("TAMS mints, stores and checks no recovery token of its own", () => {
  for (const [name, source] of Object.entries({ forgot, reset })) {
    assert.ok(!/gen_random_bytes|randomUUID|createHash|reset_token/i.test(source),
      `${name} looks like it is making its own token`);
  }
  assert.ok(!/service_role|SERVICE_ROLE/.test(forgot + reset));
});

test("the answer never depends on whether the address exists", () => {
  // The one message is a constant, and the page shows it without ever
  // looking at what Supabase returned.
  assert.match(RESET_REQUESTED_MESSAGE, /If an account exists for that email address/);
  assert.match(forgot, /setSent\(true\)/);
  assert.ok(!/error.*resetPasswordForEmail|resetPasswordForEmail[\s\S]{0,200}if \(/.test(forgot),
    "the page branches on what the recovery call returned");
  // Exactly one place shows the answer, so there is no second wording
  // for the case where the address did turn out to exist.
  const body = forgot.split("\n").filter((line) => !line.startsWith("import")).join("\n");
  assert.equal((body.match(/RESET_REQUESTED_MESSAGE/g) ?? []).length, 1);
});

test("an obviously malformed address is caught before anything is sent", () => {
  assert.ok(looksLikeEmail("resident@village.example"));
  assert.ok(looksLikeEmail("  Clerk@TA.example  "));
  for (const bad of ["", "   ", "nobody", "no@body", "a b@c.example", "@example.com"]) {
    assert.ok(!looksLikeEmail(bad), `${JSON.stringify(bad)} was accepted`);
  }
});

// ---- 6, 7, 8: the password rules ---------------------------------------

test("a password shorter than the TAMS minimum is refused", () => {
  assert.equal(MINIMUM_PASSWORD_LENGTH, 8);
  const short = "a".repeat(MINIMUM_PASSWORD_LENGTH - 1);
  assert.match(validateNewPassword(short, short)!, /at least 8 characters/);
});

test("a confirmation that does not match is refused", () => {
  assert.equal(validateNewPassword("correct-horse", "correct-house"), "The two passwords do not match.");
});

test("both fields are required", () => {
  assert.match(validateNewPassword("", "")!, /Choose a new password/);
  assert.match(validateNewPassword("correct-horse", "")!, /a second time/);
});

test("a password that meets the rules is accepted", () => {
  assert.equal(validateNewPassword("correct-horse-battery", "correct-horse-battery"), null);
  const exactly = "a".repeat(MINIMUM_PASSWORD_LENGTH);
  assert.equal(validateNewPassword(exactly, exactly), null);
});

test("the invitation page and the reset page apply the same rules", () => {
  for (const [name, source] of Object.entries({ setPassword, reset })) {
    assert.match(source, /validateNewPassword\(password, confirmation\)/,
      `${name} does not use the shared rules`);
  }
});

// ---- 8, 9-12: the reset changes a password and nothing else ------------

test("the reset uses Supabase Auth to change the password", () => {
  assert.match(reset, /supabase\.auth\.updateUser\(\{ password \}\)/);
});

test("the reset writes to no TAMS record at all", () => {
  // Every business table and column the reset must not touch.
  for (const forbidden of [
    "user_accounts", "account_status", "account_type", "resident_id", "staff_id",
    "role_id", "residents", "households", "land_", "ptos", "staff",
  ]) {
    assert.ok(!reset.includes(forbidden), `the reset page mentions ${forbidden}`);
  }
  // The only call it makes besides the password change. Session cleanup
  // is owned by SessionProvider so its recovery marker is cleared too.
  const calls = [...reset.matchAll(/supabase\.(auth\.\w+|rpc)\(/g)].map((m) => m[1]);
  assert.deepEqual(calls.sort(), ["auth.updateUser", "rpc"]);
  assert.match(reset, /supabase\.rpc\("record_password_reset"\)/);
});

test("the recovery session is ended once the password has been changed", () => {
  assert.match(
    reset,
    /updateUser[\s\S]+record_password_reset[\s\S]+await cancelRecovery\(\)/,
    "the successful reset does not end its recovery session",
  );
  assert.match(reset, /Go to sign in/);
});

test("a recovery session cannot become an ordinary application session", () => {
  assert.match(sessionProvider, /event === "PASSWORD_RECOVERY"/);
  assert.match(sessionProvider, /rememberRecoveryUser\(nextSession\.user\.id\)/);
  assert.match(recoveryBoundary, /recoverySession/);
  assert.match(recoveryBoundary, /location\.pathname !== "\/reset-password"/);
  assert.match(recoveryBoundary, /<Navigate to="\/reset-password" replace/);
});

test("leaving a failed reset signs out before navigating away", () => {
  assert.match(reset, /async function leaveRecovery/);
  assert.ok(reset.indexOf("await cancelRecovery()") < reset.indexOf("navigate(destination"));
  assert.match(reset, /leaveRecovery\("\/auth"\)/);
  assert.match(reset, /leaveRecovery\("\/"\)/);
});

// ---- 13, 14: a link that cannot be used --------------------------------

test("Supabase's own complaint about a link is read out of the address", () => {
  assert.equal(
    recoveryLinkProblem("#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired", ""),
    "Email link is invalid or has expired",
  );
  assert.equal(
    recoveryLinkProblem("#error_code=otp_expired", ""),
    "That reset link has expired.",
  );
  assert.equal(
    recoveryLinkProblem("", "?error=access_denied"),
    "That reset link cannot be used (access_denied).",
  );
  assert.equal(recoveryLinkProblem("", ""), null);
  assert.equal(recoveryLinkProblem("#access_token=abc&type=recovery", ""), null);
});

test("a link that cannot be used explains itself and offers a way on", () => {
  assert.match(reset, /This reset link cannot be used/);
  assert.match(reset, /leaveRecovery\("\/forgot-password"\)[\s\S]{0,100}Request another reset link/);
  assert.match(reset, /Back to sign in/);
  assert.match(reset, /Back to TAMS home/);
  // No blank screen: a missing session takes the same route as a stale link.
  assert.match(reset, /if \(linkProblem \|\| !session\)/);
});

test("the success state is shown even though the session has just ended", () => {
  // `done` is checked before the no-session branch, or signing out would
  // throw the person back to the error page at the moment they succeed.
  assert.ok(reset.indexOf("if (done)") < reset.indexOf("if (linkProblem || !session)"));
});

// ---- the redirect address ---------------------------------------------

test("the reset redirect uses the configured address where there is one", () => {
  assert.equal(resetRedirectUrl("https://tams.example", "http://localhost:5173"),
    "https://tams.example/reset-password");
  assert.equal(resetRedirectUrl("https://tams.example/", "http://localhost:5173"),
    "https://tams.example/reset-password");
});

test("and the browser's own address otherwise, never a hard-coded one", () => {
  assert.equal(resetRedirectUrl(undefined, "http://localhost:5173"),
    "http://localhost:5173/reset-password");
  assert.equal(resetRedirectUrl("   ", "https://tams.example"),
    "https://tams.example/reset-password");
  // No address is written into the code: the only two sources are the
  // configured one and the browser's own.
  for (const path of ["src/auth/passwordRules.ts", "src/lib/appUrl.ts",
                      "src/pages/ForgotPassword.tsx"]) {
    assert.ok(!/["'`]https?:\/\//.test(read(path)), `${path} hard-codes an address`);
  }
});

// ---- 15: nothing secret reaches the audit trail ------------------------

test("the audit function takes no parameters, so no caller can name anything", () => {
  assert.match(migration, /create or replace function public\.record_password_reset\(\)/);
  assert.match(migration, /grant execute on function public\.record_password_reset\(\) to authenticated/);
});

test("the audit event carries no password, token or link — no values at all", () => {
  const call = migration.slice(migration.indexOf("perform public.audit_event"));
  assert.match(call, /'PASSWORD_RESET_COMPLETED'/);
  // old_values, new_values and reason are all null.
  assert.match(call, /null,\s*null,\s*null\);/);
  assert.ok(!/password|token|link/i.test(call.slice(0, call.indexOf(");"))
    .replace("PASSWORD_RESET_COMPLETED", "")));
});

// ---- 16, 17: what was already there still works ------------------------

test("the staff invitation flow is untouched", () => {
  assert.ok(routes.has("/set-password"));
  assert.match(setPassword, /supabase\.auth\.updateUser\(\{ password \}\)/);
  assert.match(setPassword, /Choose your password/);
  assert.match(setPassword, /This invitation cannot be used/);
});

test("resident registration and sign-in are untouched", () => {
  assert.ok(routes.has("/register"));
  assert.ok(routes.has("/auth"));
  assert.match(signIn, /supabase\.auth\.signInWithPassword/);
  assert.match(signIn, /to="\/register"/);
});

// ---- navigation: no dead ends -----------------------------------------

test("forgot password offers sign in, register and home", () => {
  assert.match(forgot, /to="\/auth"/);
  assert.match(forgot, /to="\/register"/);
  assert.match(forgot, /to="\/"/);
  assert.match(forgot, /← Back to sign in/);
});

test("both new pages carry the TAMS name as a link home", () => {
  for (const [name, source] of Object.entries({ forgot, reset })) {
    assert.match(source, /to="\/" className="brand brand-link"/, `${name} has no home link`);
  }
});

test("every state of the reset page offers somewhere to go", () => {
  // Three states — success, unusable link, and the form — and each one
  // has its own way on.
  assert.equal((reset.match(/btn btn-primary/g) ?? []).length >= 3, true);
  assert.equal((reset.match(/Go to sign in|Back to sign in/g) ?? []).length >= 3, true);
});
