/**
 * Browser-visible feature switches. A sensitive feature stays off unless
 * deployment configuration opts in with an unambiguous true value.
 */
export function enabledOnlyWhenTrue(value: unknown): boolean {
  if (value === true) return true;
  if (typeof value !== "string") return false;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

/** Resident self-registration is closed for an administrator-only deployment. */
export const residentSelfRegistrationEnabled = enabledOnlyWhenTrue(
  import.meta.env?.VITE_RESIDENT_SELF_REGISTRATION,
);
