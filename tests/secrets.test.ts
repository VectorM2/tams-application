// The shared-secret comparison must not leak the secret through timing.

import { test } from "node:test";
import assert from "node:assert/strict";
import { secretsMatch } from "../supabase/functions/_shared/http.ts";

test("identical secrets match", () => {
  assert.equal(secretsMatch("abc123", "abc123"), true);
});

test("different secrets of the same length do not match", () => {
  assert.equal(secretsMatch("abc123", "abc124"), false);
});

test("secrets of different lengths do not match", () => {
  assert.equal(secretsMatch("abc", "abc123"), false);
});

test("an empty secret never matches a real one", () => {
  assert.equal(secretsMatch("", "abc123"), false);
});

// =====================================================================
// Nothing that is actually a secret may be committed.
//
// This exists because one was: an earlier version of docs/SETUP.md
// pasted a working TAMS_WORKER_SECRET, a project's real anon key and
// its project reference straight into the cron example. A setup
// document is exactly where that happens, because it is written while
// looking at a live project. So the whole repository is scanned, every
// time the tests run.
// =====================================================================

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");

/** Every file git tracks, which is exactly what would be published. */
function trackedFiles(): string[] {
  return execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8" })
    .split("\0")
    .filter(Boolean)
    .filter((file) => !file.startsWith("data/legacy-import/"))
    .filter((file) => !file.endsWith("package-lock.json"));
}

function read(file: string): string {
  try {
    return readFileSync(path.join(root, file), "utf8");
  } catch {
    return ""; // a binary or unreadable file carries no pasted secret
  }
}

const SHAPES: { name: string; pattern: RegExp }[] = [
  // A Supabase or any other JWT. Even the anon key is a real project
  // credential and belongs in .env, not in a document.
  { name: "a JSON web token", pattern: /eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{16,}\./ },
  // Brevo hands these out for the mail API.
  { name: "a Brevo API key", pattern: /xkeysib-[A-Za-z0-9]{16,}/ },
  // Supabase's newer secret-key format.
  { name: "a Supabase secret key", pattern: /sb_secret_[A-Za-z0-9_-]{16,}/ },
  // What `openssl rand -hex 32` and `-base64 32` produce, which is how
  // the setup guide tells you to make the worker and recovery secrets.
  { name: "a 32-byte hex secret", pattern: /\b[0-9a-f]{64}\b/ },
  { name: "a 32-byte base64 secret", pattern: /['"][A-Za-z0-9+/]{40,}={0,2}['"]/ },
];

/** The header of any file that is allowed to hold something secret-shaped. */
const ALLOWED = [
  // Test fixtures deliberately contain token-shaped strings.
  "supabase/tests/",
  "tests/",
  // Hashes of dependencies, not credentials.
  "package-lock.json",
];

test("no committed file contains anything shaped like a real secret", () => {
  const found: string[] = [];

  for (const file of trackedFiles()) {
    if (ALLOWED.some((prefix) => file.startsWith(prefix))) continue;
    const contents = read(file);
    for (const { name, pattern } of SHAPES) {
      const hit = contents.match(pattern);
      if (!hit) continue;
      const line = contents.slice(0, hit.index).split("\n").length;
      found.push(`${file}:${line} looks like ${name}`);
    }
  }

  assert.deepEqual(found, [], `secrets must never be committed:\n${found.join("\n")}`);
});

test("the setup guide asks for secrets by name and never shows one", () => {
  const setup = read("docs/SETUP.md");

  // It must still tell the reader which secrets the server needs…
  assert.match(setup, /TAMS_ADMIN_RECOVERY_SECRET/);
  assert.match(setup, /TAMS_BOOTSTRAP_SECRET/);

  // …generated on the spot or left as a placeholder, never written out.
  assert.match(setup, /TAMS_ADMIN_RECOVERY_SECRET="\$\(openssl rand -hex 32\)"/);
  assert.match(setup, /TAMS_BOOTSTRAP_SECRET="\$\(openssl rand -hex 32\)"/);
  assert.match(setup, /<your-project-ref>/);
});

test(".env is ignored and never tracked", () => {
  const tracked = trackedFiles();
  assert.ok(!tracked.includes(".env"), ".env must never be committed");
  assert.ok(tracked.includes(".env.example"), ".env.example should be committed");
  assert.match(read(".gitignore"), /^\.env$/m);
});

test("the example environment file names variables but sets no real value", () => {
  const example = read(".env.example");

  // The anon key and URL are named, but only as placeholders.
  assert.match(example, /VITE_SUPABASE_URL=/);
  assert.match(example, /VITE_SUPABASE_ANON_KEY=/);
  assert.ok(!/eyJ[A-Za-z0-9_-]{8,}\./.test(example), ".env.example holds a real key");

  // A server-side secret must never be *set* here: this file is read by
  // Vite, and everything Vite reads can reach the browser. Naming one in
  // a comment is fine, and is how the file says where it does belong.
  const settings = example
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("#"));

  for (const name of [
    "SUPABASE_SERVICE_ROLE_KEY", "BREVO_API_KEY",
    "TAMS_WORKER_SECRET", "TAMS_ADMIN_RECOVERY_SECRET", "TAMS_BOOTSTRAP_SECRET",
  ]) {
    assert.ok(
      !settings.some((line) => line.includes(`${name}=`)),
      `${name} must not be set in .env.example`,
    );
  }
});

test("no server-side secret is ever read from browser code", () => {
  for (const file of trackedFiles().filter((f) => f.startsWith("src/"))) {
    const contents = read(file);
    for (const name of [
      "SERVICE_ROLE", "BREVO_API_KEY", "TAMS_WORKER_SECRET",
      "TAMS_ADMIN_RECOVERY_SECRET", "TAMS_BOOTSTRAP_SECRET",
    ]) {
      assert.ok(!contents.includes(name), `${file} refers to ${name}`);
    }
  }
});
