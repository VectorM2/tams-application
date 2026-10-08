import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { enabledOnlyWhenTrue } from "../src/lib/featureFlags.ts";

const source = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("resident self-registration is disabled unless explicitly enabled", () => {
  for (const value of [undefined, null, false, "", "false", "0", "no", "off", "unexpected"]) {
    assert.equal(enabledOnlyWhenTrue(value), false, String(value));
  }

  for (const value of [true, "true", "TRUE", "  yes  ", "on", "1"]) {
    assert.equal(enabledOnlyWhenTrue(value), true, String(value));
  }
});

test("every public registration entry point uses the deployment switch", () => {
  for (const path of [
    "src/pages/Landing.tsx",
    "src/pages/SignIn.tsx",
    "src/pages/ForgotPassword.tsx",
    "src/pages/resident/Register.tsx",
  ]) {
    assert.match(source(path), /residentSelfRegistrationEnabled/, `${path} is not gated`);
  }
});

test("the Netlify deployment has a build target, SPA rewrite and security headers", () => {
  const config = source("netlify.toml");
  assert.match(config, /command = "npm run build"/);
  assert.match(config, /publish = "dist"/);
  assert.match(config, /from = "\/\*"[\s\S]*to = "\/index\.html"[\s\S]*status = 200/);
  assert.match(config, /Content-Security-Policy/);
  assert.match(config, /X-Content-Type-Options = "nosniff"/);
});
