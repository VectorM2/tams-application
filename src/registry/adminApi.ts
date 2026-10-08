// The audit trail and Administrator Transfer.
//
// Every one of these is a database function that establishes its own
// caller from auth.uid() and rechecks the rules for itself. Nothing
// here is trusted; this layer only shapes the calls.

import { supabase } from "../lib/supabaseClient";
import { readableError } from "../lib/errorMessage";

export type Result<T> = { ok: true; data: T } | { ok: false; code: string; message: string };

function failure(error: { code?: string; message: string }): Result<never> {
  const message = readableError(error.message);
  if (error.code === "42501") {
    return { ok: false, code: "42501", message: "You are not allowed to do that." };
  }
  if (error.code === "PGRST202") {
    return {
      ok: false, code: "PGRST202",
      message: "This part of the system is not installed on the database yet. " +
        "The audit migrations need to be applied to the Supabase project.",
    };
  }
  return { ok: false, code: error.code ?? "unknown", message };
}

async function call<T>(name: string, args: Record<string, unknown> = {}): Promise<Result<T>> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) return failure(error);
  return { ok: true, data: data as T };
}

// ---- the audit trail -----------------------------------------------------

export type AuditRow = {
  audit_id: string;
  created_at: string;
  actor_label: string | null;
  actor_role: string | null;
  action: string;
  entity_type: string;
  entity_id: string | null;
  entity_reference: string | null;
  changed_fields: string[] | null;
  reason: string | null;
  event_group_id: string | null;
};

export type AuditDetail = {
  audit_id: string;
  created_at: string;
  actor_label: string | null;
  actor_role: string | null;
  actor_account_type: string | null;
  actor_employee_number: string | null;
  action: string;
  entity_type: string;
  entity_id: string | null;
  entity_reference: string | null;
  old_values: Record<string, unknown> | null;
  new_values: Record<string, unknown> | null;
  changed_fields: string[] | null;
  reason: string | null;
  event_group_id: string | null;
  related: { audit_id: string; action: string; entity_type: string; entity_reference: string | null }[];
};

export type AuditFilters = {
  actions: string[];
  entity_types: string[];
  actor_roles: string[];
  total: number;
};

export const auditLogs = (filters: {
  from?: string; to?: string; actor?: string; actorRole?: string;
  action?: string; entityType?: string; reference?: string; limit?: number;
}) =>
  call<AuditRow[]>("admin_audit_logs", {
    p_from: filters.from || null,
    p_to: filters.to || null,
    p_actor: filters.actor || null,
    p_actor_role: filters.actorRole || null,
    p_action: filters.action || null,
    p_entity_type: filters.entityType || null,
    p_reference: filters.reference || null,
    p_limit: filters.limit ?? 200,
  });

export const auditLog = (id: string) => call<AuditDetail>("admin_audit_log", { p_audit_id: id });
export const auditFilterValues = () => call<AuditFilters>("admin_audit_filters");

// ---- Administrator Transfer ----------------------------------------------

export type TransferCandidate = {
  staff_id: string;
  employee_number: string;
  full_name: string;
  email: string;
  role_name: string;
  account_status: string;
};

export const transferCandidates = () => call<TransferCandidate[]>("admin_transfer_candidates");

export const transferAdministrator = (
  incomingStaffId: string,
  outcome: "remain_staff" | "deactivate",
  reason: string,
  outgoingRoleId: string | null,
) =>
  call<{
    outgoing_name: string; outgoing_outcome: string; outgoing_new_role: string | null;
    incoming_name: string; incoming_previous_role: string; active_administrators: number;
  }>("transfer_council_administrator", {
    p_incoming_staff_id: incomingStaffId,
    p_outgoing_outcome: outcome,
    p_reason: reason,
    p_outgoing_role_id: outgoingRoleId,
  });
