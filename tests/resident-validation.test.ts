import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeResidentDetails, validateResidentDetails } from "../src/registry/residentValidation.ts";
import type { ResidentDetails } from "../src/registry/api.ts";
import { validateVerificationDetails } from "../src/registry/verificationValidation.ts";

const TODAY = new Date(2026, 9, 8);
const VALID: ResidentDetails = {
  id_number: "8503125678089", first_name: "Tsakani", last_name: "Baloyi", date_of_birth: "1985-03-12",
  gender: "Female", resident_status: "active", contact_number: "072 123 4567", email: "",
};

test("a complete resident record is valid, with the optional fields blank", () => {
  assert.deepEqual(validateResidentDetails(VALID, TODAY), {});
  assert.deepEqual(validateResidentDetails({ ...VALID, contact_number: "" }, TODAY), {});
});

test("the ID number must be 13 digits whose first six are a real date", () => {
  for (const id_number of ["", "SYN0000000001", "850312567808", "85031256780899", "8513325678089"]) {
    assert.ok(validateResidentDetails({ ...VALID, id_number }, TODAY).id_number, id_number);
  }
  assert.deepEqual(validateResidentDetails({ ...VALID, id_number: "850312 5678 089" }, TODAY), {});
});

test("the date of birth must match the ID and cannot be in the future", () => {
  assert.ok(validateResidentDetails({ ...VALID, date_of_birth: "1985-03-13" }, TODAY).date_of_birth);
  assert.ok(validateResidentDetails({ ...VALID, date_of_birth: "" }, TODAY).date_of_birth);
  assert.ok(validateResidentDetails({ ...VALID, id_number: "2701015678089", date_of_birth: "2027-01-01" }, TODAY).date_of_birth);
});

test("gender is Male or Female, and names are letters", () => {
  for (const gender of ["", "male", "M", "Other"]) {
    assert.ok(validateResidentDetails({ ...VALID, gender }, TODAY).gender, gender);
  }
  assert.ok(validateResidentDetails({ ...VALID, first_name: "T" }, TODAY).first_name);
  assert.ok(validateResidentDetails({ ...VALID, last_name: "Baloyi2" }, TODAY).last_name);
  assert.deepEqual(validateResidentDetails({ ...VALID, first_name: "Mary-Jane", last_name: "O'Neil" }, TODAY), {});
});

test("contact number and email are checked only when given", () => {
  for (const contact_number of ["12345", "072-123", "abc0721234567"]) {
    assert.ok(validateResidentDetails({ ...VALID, contact_number }, TODAY).contact_number, contact_number);
  }
  for (const contact_number of ["0721234567", "+27 72 123 4567", "(072) 123-4567"]) {
    assert.equal(validateResidentDetails({ ...VALID, contact_number }, TODAY).contact_number, undefined, contact_number);
  }
  assert.ok(validateResidentDetails({ ...VALID, email: "not-an-email" }, TODAY).email);
});

test("what is sent is trimmed, with spaces taken out of the ID number", () => {
  const sent = normalizeResidentDetails({ ...VALID, id_number: " 850312 5678089 ", first_name: "  Tsakani " });
  assert.equal(sent.id_number, "8503125678089");
  assert.equal(sent.first_name, "Tsakani");
});

test("a resident's own cellphone number must look like a phone number", () => {
  const claim = {
    first_name: "Tsakani", middle_names: "", last_name: "Baloyi", previous_surname: "",
    id_number: "8503125678089", date_of_birth: "1985-03-12", gender: "Female",
    cellphone_number: "0721234567", house_number: "13", street_address: "Marula Street",
    household_head_name: "Hlulani Baloyi", relationship_to_household_head: "Spouse",
  };
  assert.deepEqual(validateVerificationDetails(claim, TODAY), {});
  assert.ok(validateVerificationDetails({ ...claim, cellphone_number: "12" }, TODAY).cellphone_number);
});
