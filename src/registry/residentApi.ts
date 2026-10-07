// Everything a resident does with their own account: registering,
// submitting a verification request, and seeing where it stands.
//
// None of this makes anybody a resident of the village. The register is
// the authority on that, and only a Registry Clerk approving a request
// links an account to a record on it.

import { supabase } from "../lib/supabaseClient";
import { readableError } from "../lib/errorMessage";
import { normalizeVerificationDetails, validateVerificationDetails } from "./verificationValidation";
import type { VerificationDetails } from "./verificationValidation";
export type { VerificationDetails } from "./verificationValidation";

export const DOCUMENT_BUCKET = "resident-verification-documents";
export const MAXIMUM_DOCUMENT_BYTES = 2 * 1024 * 1024;
export const ACCEPTED_DOCUMENT_TYPES = ["application/pdf", "image/jpeg", "image/png"] as const;
export const ACCEPTED_EXTENSIONS = ".pdf,.jpg,.jpeg,.png";

export type DocumentKind = "certified_id_copy" | "proof_of_residence";

export const DOCUMENT_LABELS: Record<DocumentKind, string> = {
  certified_id_copy: "Certified copy of your ID",
  proof_of_residence: "Proof of residence",
};

export type ResidentPortal = {
  account_id: string;
  email: string;
  account_status: "pending" | "active" | "declined" | "deactivated";
  resident_id: string | null;
  resident: {
    full_name: string;
    id_number: string;
    household_code: string | null;
    street_address: string | null;
  } | null;
  latest_request: {
    request_id: string;
    request_status: "pending" | "approved" | "declined";
    submitted_at: string;
    reviewed_at: string | null;
    decline_reason: string | null;
    first_name: string;
    last_name: string;
    id_number: string;
  } | null;
  attempts: {
    request_status: string;
    submitted_at: string;
    reviewed_at: string | null;
    decline_reason: string | null;
  }[];
  may_submit: boolean;
};

export type ResidentResult<T> =
  | { ok: true; data: T }
  | { ok: false; code: string; message: string };

function failure(error: { code?: string; message: string }): ResidentResult<never> {
  const message = readableError(error.message);
  if (error.code === "PGRST202") {
    return {
      ok: false,
      code: "PGRST202",
      message: "This part of the system is not installed on the database yet. " +
        "The resident account migration needs to be applied to the Supabase project.",
    };
  }
  return { ok: false, code: error.code ?? "unknown", message };
}

async function call<T>(name: string, args: Record<string, unknown> = {}): Promise<ResidentResult<T>> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) return failure(error);
  return { ok: true, data: data as T };
}

/** Creates the resident account for a newly confirmed sign-in, once. */
export const ensureResidentAccount = () =>
  call<{ account_id: string; account_type: string; account_status: string; created: boolean }>(
    "resident_ensure_account");

export const residentPortal = () => call<ResidentPortal>("resident_portal");

/** What the browser refuses before a byte is uploaded. The database and
 *  the storage bucket both check again, so this is only courtesy. */
export function describeFileProblem(file: File): string | null {
  if (!ACCEPTED_DOCUMENT_TYPES.includes(file.type as typeof ACCEPTED_DOCUMENT_TYPES[number])) {
    return "That file must be a PDF, a JPG or a PNG.";
  }
  if (file.size > MAXIMUM_DOCUMENT_BYTES) {
    return `That file is ${(file.size / 1024 / 1024).toFixed(1)} MB. Each document must be 2 MB or smaller.`;
  }
  if (file.size === 0) return "That file is empty.";
  return null;
}

type UploadedDocument = {
  document_type: DocumentKind;
  storage_path: string;
  file_name: string;
  mime_type: string;
  file_size_bytes: number;
};

/**
 * Uploads one document into the applicant's own folder in the private
 * bucket. The folder is their auth user id, which is what the storage
 * policy checks, so nobody can write into anybody else's.
 */
async function uploadDocument(
  authUserId: string,
  kind: DocumentKind,
  file: File,
): Promise<ResidentResult<UploadedDocument>> {
  const problem = describeFileProblem(file);
  if (problem) return { ok: false, code: "file", message: problem };

  const extension = file.name.includes(".") ? file.name.split(".").pop() : "dat";
  const path = `${authUserId}/${kind}-${Date.now()}.${extension}`;

  const { error } = await supabase.storage
    .from(DOCUMENT_BUCKET)
    .upload(path, file, { contentType: file.type, upsert: false });

  if (error) {
    // Whatever storage said is for the log, not the screen.
    return { ok: false, code: "upload",
             message: `${file.name} could not be uploaded. Check the file and your connection, then try again.` };
  }

  return {
    ok: true,
    data: {
      document_type: kind,
      storage_path: path,
      file_name: file.name,
      mime_type: file.type,
      file_size_bytes: file.size,
    },
  };
}

/** Uploads both documents, then submits the request as one call. */
export async function submitVerificationRequest(
  authUserId: string,
  details: VerificationDetails,
  files: Record<DocumentKind, File>,
): Promise<ResidentResult<{ request_id: string; account_status: string }>> {
  const normalized = normalizeVerificationDetails(details);
  const problem = Object.values(validateVerificationDetails(normalized))[0];
  if (problem) return { ok: false, code: "validation", message: problem };

  const uploads: UploadedDocument[] = [];

  for (const kind of ["certified_id_copy", "proof_of_residence"] as DocumentKind[]) {
    const result = await uploadDocument(authUserId, kind, files[kind]);
    if (!result.ok) return result;
    uploads.push(result.data);
  }

  return call<{ request_id: string; account_status: string }>("resident_submit_verification_request", {
    p_details: normalized,
    p_documents: uploads,
  });
}

/**
 * A link that works for a few minutes and then stops. The bucket is
 * private, so there is no permanent address for any of these files.
 */
export async function signedDocumentUrl(storagePath: string): Promise<string | null> {
  const { data, error } = await supabase.storage
    .from(DOCUMENT_BUCKET)
    .createSignedUrl(storagePath, 120);
  if (error) return null;
  return data?.signedUrl ?? null;
}
