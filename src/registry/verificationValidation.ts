export type VerificationDetails = {
  first_name: string;
  middle_names: string;
  last_name: string;
  previous_surname: string;
  id_number: string;
  date_of_birth: string;
  gender: string;
  cellphone_number: string;
  house_number: string;
  street_address: string;
  household_head_name: string;
  relationship_to_household_head: string;
};

export type VerificationErrors = Partial<Record<keyof VerificationDetails, string>>;

const ID_NUMBER = /^[0-9]{13}$/;
export const NAME = /^[\p{L}\p{M}]+(?:[ '’-]+[\p{L}\p{M}]+)*$/u;
const PHONE = /^(\+27|0)[0-9]{9}$/;

/** A South African phone number: 0XX XXX XXXX or +27 XX XXX XXXX, spaces allowed. */
export function isSouthAfricanPhone(value: string): boolean {
  return PHONE.test(value.replace(/[\s()-]/g, ""));
}

/** A local calendar date, without converting the user's day to UTC. */
export function todayForDateInput(today = new Date()): string {
  return `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
}

function isCalendarDate(value: string): boolean {
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value) || Number(value.slice(0, 4)) < 1) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

/**
 * The first six ID digits are YYMMDD. Suggest the most recent matching
 * birth date that is not in the future. The user can correct the century:
 * a two-digit birth year cannot distinguish, for example, 1920 from 2020.
 */
export function birthDateFromId(idNumber: string, today = new Date()): string | null {
  const id = idNumber.trim();
  if (!ID_NUMBER.test(id)) return null;
  const latestYear = Math.floor(today.getFullYear() / 100) * 100 + Number(id.slice(0, 2));
  for (const year of [latestYear, latestYear - 100]) {
    const date = `${year}-${id.slice(2, 4)}-${id.slice(4, 6)}`;
    if (isCalendarDate(date) && date <= todayForDateInput(today)) return date;
  }
  return null;
}

export function birthDateMatchesId(date: string, idNumber: string, today = new Date()): boolean {
  const id = idNumber.trim();
  return ID_NUMBER.test(id) && isCalendarDate(date) && date <= todayForDateInput(today)
    && `${date.slice(2, 4)}${date.slice(5, 7)}${date.slice(8, 10)}` === id.slice(0, 6);
}

/** Recalculate the date on ID edits, clearing it when the ID is incomplete. */
export function updateVerificationField(
  current: VerificationDetails,
  key: keyof VerificationDetails,
  value: string,
  today = new Date(),
): VerificationDetails {
  const next = { ...current, [key]: value };
  if (key !== "id_number") return next;
  const suggestedDate = birthDateFromId(value, today);
  next.date_of_birth = suggestedDate
    ? (birthDateMatchesId(current.date_of_birth, value, today) ? current.date_of_birth : suggestedDate)
    : "";
  return next;
}

export function normalizeVerificationDetails(details: VerificationDetails): VerificationDetails {
  const normalized = { ...details };
  for (const key of Object.keys(normalized) as (keyof VerificationDetails)[]) {
    normalized[key] = normalized[key].trim().normalize("NFC");
  }
  return normalized;
}

/** Used both by the form and before the document-upload boundary. */
export function validateVerificationDetails(details: VerificationDetails, today = new Date()): VerificationErrors {
  const values = normalizeVerificationDetails(details);
  const errors: VerificationErrors = {};
  const names: [keyof VerificationDetails, string, boolean][] = [
    ["first_name", "First name", true],
    ["middle_names", "Middle name(s)", false],
    ["last_name", "Surname", true],
    ["previous_surname", "Previous or maiden surname", false],
    ["household_head_name", "Household head's name", true],
  ];
  for (const [key, label, required] of names) {
    const name = values[key];
    if (!name && !required) continue;
    if ((name.match(/\p{L}/gu)?.length ?? 0) < 3) {
      errors[key] = `${label} must contain at least 3 letters.`;
    } else if (!NAME.test(name)) {
      errors[key] = `${label} may contain letters, spaces, apostrophes and hyphens only.`;
    }
  }

  if (!ID_NUMBER.test(values.id_number)) {
    errors.id_number = "Enter exactly 13 digits for your South African ID number.";
  } else if (!birthDateFromId(values.id_number, today)) {
    errors.id_number = "The first six ID digits must contain a valid date of birth.";
  }

  if (!values.date_of_birth) {
    errors.date_of_birth = "Enter your date of birth, or complete your ID number to fill it in.";
  } else if (!isCalendarDate(values.date_of_birth)) {
    errors.date_of_birth = "Enter a valid date of birth.";
  } else if (values.date_of_birth > todayForDateInput(today)) {
    errors.date_of_birth = "Date of birth cannot be in the future.";
  } else if (ID_NUMBER.test(values.id_number)
    && !birthDateMatchesId(values.date_of_birth, values.id_number, today)) {
    errors.date_of_birth = "Date of birth must match the first six digits of your ID number.";
  }

  if (values.gender !== "Male" && values.gender !== "Female") {
    errors.gender = "Select Male or Female.";
  }

  if (values.cellphone_number && !isSouthAfricanPhone(values.cellphone_number)) {
    errors.cellphone_number = "Enter a valid cellphone number, for example 072 123 4567.";
  }

  const required: [keyof VerificationDetails, string][] = [
    ["cellphone_number", "Enter your cellphone number."],
    ["house_number", "Enter your house number."],
    ["street_address", "Enter your street address."],
    ["relationship_to_household_head", "Enter your relationship to the household head."],
  ];
  for (const [key, message] of required) {
    if (!values[key]) errors[key] = message;
  }
  return errors;
}
