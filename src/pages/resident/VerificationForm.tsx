import { useState } from "react";
import { Field, Notice } from "../../components/ui";
import {
  ACCEPTED_EXTENSIONS, DOCUMENT_LABELS, describeFileProblem, submitVerificationRequest,
} from "../../registry/residentApi";
import type { DocumentKind, VerificationDetails } from "../../registry/residentApi";
import {
  birthDateFromId, todayForDateInput, updateVerificationField, validateVerificationDetails,
} from "../../registry/verificationValidation";

const EMPTY: VerificationDetails = {
  first_name: "", middle_names: "", last_name: "", previous_surname: "",
  id_number: "", date_of_birth: "", gender: "",
  cellphone_number: "", house_number: "", street_address: "",
  household_head_name: "", relationship_to_household_head: "",
};

/**
 * What the applicant sends to be verified: who they say they are, where
 * they say they live, and the two documents that support it.
 *
 * They are never asked for a household code or a site code. Those are
 * the system's own references and no resident should be expected to
 * know them — the clerk works them out from the register.
 */
export function VerificationForm({
  authUserId,
  email,
  previous,
  onCancel,
  onDone,
}: {
  authUserId: string;
  email: string;
  previous: { first_name: string; last_name: string; id_number: string } | null;
  onCancel: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  // Reapplying starts from what was sent last time, so only the part
  // that was wrong has to be retyped.
  const [form, setForm] = useState<VerificationDetails>(
    previous
      ? { ...EMPTY, ...previous, date_of_birth: birthDateFromId(previous.id_number) ?? "" }
      : EMPTY,
  );
  const [files, setFiles] = useState<Partial<Record<DocumentKind, File>>>({});
  const [fileErrors, setFileErrors] = useState<Partial<Record<DocumentKind, string>>>({});
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [validationAttempted, setValidationAttempted] = useState(false);
  const fieldErrors = validationAttempted ? validateVerificationDetails(form) : {};

  function update(key: keyof VerificationDetails, value: string) {
    setForm((current) => updateVerificationField(current, key, value));
    setError(null);
  }

  function chooseFile(kind: DocumentKind, file: File | undefined) {
    if (!file) return;
    const problem = describeFileProblem(file);
    setFileErrors((current) => ({ ...current, [kind]: problem ?? undefined }));
    setFiles((current) => ({ ...current, [kind]: problem ? undefined : file }));
  }

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    if (submitting) return;
    setError(null);
    setValidationAttempted(true);

    const errors = validateVerificationDetails(form);
    const firstInvalid = Object.keys(errors)[0];
    if (firstInvalid) {
      setError("Please correct the highlighted fields before sending your details.");
      document.getElementById(firstInvalid)?.focus();
      return;
    }

    if (!files.certified_id_copy || !files.proof_of_residence) {
      setError("Both documents are needed: a certified copy of your ID and a proof of residence.");
      return;
    }

    setSubmitting(true);
    const result = await submitVerificationRequest(authUserId, form, {
      certified_id_copy: files.certified_id_copy,
      proof_of_residence: files.proof_of_residence,
    });
    setSubmitting(false);

    if (!result.ok) { setError(result.message); return; }
    await onDone("Your details have been sent to the Registry Clerk. You will see the outcome here.");
  }

  return (
    <div className="page">
      <div className="page-head">
        <h1>Verification details</h1>
        <p>
          {previous
            ? "Correct what was wrong and send it again. This uses the same account."
            : "Tell us who you are so the Registry Clerk can find you on the village register."}
        </p>
      </div>

      <form onSubmit={handleSubmit} noValidate style={{ maxWidth: 860 }}>
        {error ? <div style={{ marginBottom: 18 }}><Notice kind="error">{error}</Notice></div> : null}

        <div className="card">
          <h2 className="card-title">Who you are</h2>
          <div className="form-grid">
            <Field label="First name" htmlFor="first_name" error={fieldErrors.first_name} hint="At least 3 letters.">
              <input id="first_name" value={form.first_name} minLength={3} required
                     onChange={(e) => update("first_name", e.target.value)} />
            </Field>
            <Field label="Middle name(s)" htmlFor="middle_names" error={fieldErrors.middle_names}
                   hint="Optional. At least 3 letters if entered.">
              <input id="middle_names" value={form.middle_names} minLength={3}
                     onChange={(e) => update("middle_names", e.target.value)} />
            </Field>
            <Field label="Surname" htmlFor="last_name" error={fieldErrors.last_name} hint="At least 3 letters.">
              <input id="last_name" value={form.last_name} minLength={3} required
                     onChange={(e) => update("last_name", e.target.value)} />
            </Field>
            <Field label="Previous or maiden surname" htmlFor="previous_surname" error={fieldErrors.previous_surname}
                   hint="Optional. At least 3 letters if entered.">
              <input id="previous_surname" value={form.previous_surname} minLength={3}
                     onChange={(e) => update("previous_surname", e.target.value)} />
            </Field>
            <Field label="South African ID number" htmlFor="id_number" error={fieldErrors.id_number}
                   hint="Exactly 13 digits, with no spaces or letters.">
              <input id="id_number" type="text" inputMode="numeric" minLength={13} maxLength={13}
                     pattern="[0-9]{13}" value={form.id_number} required
                     onChange={(e) => update("id_number", e.target.value)} />
            </Field>
            <Field label="Date of birth" htmlFor="date_of_birth" error={fieldErrors.date_of_birth}
                   hint="Filled from your ID number. Check that the birth year is correct.">
              <input id="date_of_birth" type="date" value={form.date_of_birth} max={todayForDateInput()} required
                     onChange={(e) => update("date_of_birth", e.target.value)} />
            </Field>
            <Field label="Gender" htmlFor="gender" error={fieldErrors.gender}>
              <select id="gender" value={form.gender} required onChange={(e) => update("gender", e.target.value)}>
                <option value="" disabled>Select gender</option>
                <option value="Male">Male</option>
                <option value="Female">Female</option>
              </select>
            </Field>
          </div>
        </div>

        <div className="card">
          <h2 className="card-title">How to reach you</h2>
          <div className="form-grid">
            <Field label="Email address" htmlFor="email" hint="The address you signed in with.">
              <input id="email" value={email} readOnly />
            </Field>
            <Field label="Cellphone number" htmlFor="cellphone_number" error={fieldErrors.cellphone_number}>
              <input id="cellphone_number" value={form.cellphone_number} required
                     onChange={(e) => update("cellphone_number", e.target.value)} />
            </Field>
          </div>
        </div>

        <div className="card">
          <h2 className="card-title">Where you live</h2>
          <div className="form-grid">
            <Field label="House number" htmlFor="house_number" error={fieldErrors.house_number}>
              <input id="house_number" value={form.house_number} required
                     onChange={(e) => update("house_number", e.target.value)} />
            </Field>
            <Field label="Street address" htmlFor="street_address" error={fieldErrors.street_address}>
              <input id="street_address" value={form.street_address} required
                     onChange={(e) => update("street_address", e.target.value)} />
            </Field>
            <Field label="Full name of the head of your household" htmlFor="household_head_name"
                   error={fieldErrors.household_head_name} hint="At least 3 letters.">
              <input id="household_head_name" value={form.household_head_name} minLength={3} required
                     onChange={(e) => update("household_head_name", e.target.value)} />
            </Field>
            <Field label="Your relationship to them" htmlFor="relationship_to_household_head"
                   error={fieldErrors.relationship_to_household_head}
                   hint="For example: son, daughter, spouse, or head of the household yourself.">
              <input id="relationship_to_household_head" value={form.relationship_to_household_head} required
                     onChange={(e) => update("relationship_to_household_head", e.target.value)} />
            </Field>
          </div>
        </div>

        <div className="card">
          <h2 className="card-title">Your documents</h2>
          <p className="muted-note" style={{ marginBottom: 18 }}>
            PDF, JPG or PNG. Each file must be 2 MB or smaller. They are stored privately and
            are only ever seen by the Registry Clerk reviewing your application.
          </p>

          <div className="form-grid">
            {(["certified_id_copy", "proof_of_residence"] as DocumentKind[]).map((kind) => (
              <Field key={kind} label={DOCUMENT_LABELS[kind]} htmlFor={kind} error={fileErrors[kind]}
                     hint={files[kind] ? `${files[kind]!.name} — ready to send` : undefined}>
                <input id={kind} type="file" accept={ACCEPTED_EXTENSIONS}
                       onChange={(event) => chooseFile(kind, event.target.files?.[0])} />
              </Field>
            ))}
          </div>
        </div>

        <div className="row" style={{ marginTop: 22 }}>
          <button type="submit" className="btn btn-primary" disabled={submitting}>
            {submitting ? "Sending…" : "Send for verification"}
          </button>
          <button type="button" className="btn btn-ghost" onClick={onCancel} disabled={submitting}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}
