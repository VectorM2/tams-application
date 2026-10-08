// The Registry Clerk's resident record form, checked before it is sent.
//
// The database insists only that the identity fields are present. These
// are the rules a resident's own verification request is held to, so a
// record the clerk types in can later be matched to that resident.

import type { ResidentDetails } from "./api.ts";
import {
  NAME, birthDateFromId, birthDateMatchesId, isSouthAfricanPhone, todayForDateInput,
} from "./verificationValidation.ts";

export type ResidentErrors = Partial<Record<keyof ResidentDetails, string>>;

const ID_NUMBER = /^[0-9]{13}$/;
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export function normalizeResidentDetails(details: ResidentDetails): ResidentDetails {
  return {
    ...details,
    id_number: details.id_number.replace(/\s/g, ""),
    first_name: details.first_name.trim().normalize("NFC"),
    last_name: details.last_name.trim().normalize("NFC"),
    date_of_birth: details.date_of_birth.trim(),
    gender: details.gender.trim(),
    contact_number: details.contact_number.trim(),
    email: details.email.trim(),
  };
}

export function validateResidentDetails(details: ResidentDetails, today = new Date()): ResidentErrors {
  const values = normalizeResidentDetails(details);
  const errors: ResidentErrors = {};

  if (!ID_NUMBER.test(values.id_number)) {
    errors.id_number = "Enter exactly 13 digits for the South African ID number.";
  } else if (!birthDateFromId(values.id_number, today)) {
    errors.id_number = "The first six ID digits must be a valid date of birth.";
  }

  if (!values.date_of_birth) {
    errors.date_of_birth = "Enter the date of birth.";
  } else if (values.date_of_birth > todayForDateInput(today)) {
    errors.date_of_birth = "Date of birth cannot be in the future.";
  } else if (ID_NUMBER.test(values.id_number) && !birthDateMatchesId(values.date_of_birth, values.id_number, today)) {
    errors.date_of_birth = "Date of birth must match the first six digits of the ID number.";
  }

  for (const [key, label] of [["first_name", "First name"], ["last_name", "Surname"]] as const) {
    const name = values[key];
    if ((name.match(/\p{L}/gu)?.length ?? 0) < 2) errors[key] = `${label} must contain at least 2 letters.`;
    else if (!NAME.test(name)) errors[key] = `${label} may contain letters, spaces, apostrophes and hyphens only.`;
  }

  if (values.gender !== "Male" && values.gender !== "Female") errors.gender = "Select Male or Female.";

  if (values.contact_number && !isSouthAfricanPhone(values.contact_number)) {
    errors.contact_number = "Enter a valid phone number, for example 072 123 4567.";
  }
  if (values.email && !EMAIL.test(values.email)) errors.email = "Enter a valid email address.";

  return errors;
}
