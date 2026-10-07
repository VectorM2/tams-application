import { test } from "node:test";
import assert from "node:assert/strict";
import {
  birthDateFromId, birthDateMatchesId, normalizeVerificationDetails,
  updateVerificationField, validateVerificationDetails,
} from "../src/registry/verificationValidation.ts";
import type { VerificationDetails } from "../src/registry/verificationValidation.ts";

const TODAY = new Date(2026, 9, 7);
const VALID: VerificationDetails = {
  first_name: "Alice", middle_names: "", last_name: "Nkosi", previous_surname: "",
  id_number: "0002290000000", date_of_birth: "2000-02-29", gender: "Female",
  cellphone_number: "0730000001", house_number: "13", street_address: "Marula Street",
  household_head_name: "Samuel Nkosi", relationship_to_household_head: "Daughter",
};

test("a complete claim is valid with both optional name fields blank", () => {
  assert.deepEqual(validateVerificationDetails(VALID, TODAY), {});
});

test("ID numbers require exactly thirteen ASCII digits and preserve leading zeroes", () => {
  for (const id_number of ["", "000229000000", "00022900000000", "000229000000x", "000229 000000", "０００２２９０００００００"]) {
    assert.ok(validateVerificationDetails({ ...VALID, id_number }, TODAY).id_number, id_number);
    assert.equal(birthDateFromId(id_number, TODAY), null);
  }
  assert.equal(birthDateFromId(VALID.id_number, TODAY), "2000-02-29");
});

test("ID dates reject impossible calendar dates rather than rolling into the next month", () => {
  for (const prefix of ["000230", "010229", "901301", "900001", "900100", "900431"]) {
    assert.equal(birthDateFromId(`${prefix}0000000`, TODAY), null, prefix);
    assert.ok(validateVerificationDetails({ ...VALID, id_number: `${prefix}0000000` }, TODAY).id_number);
  }
});

test("birth dates are suggested correctly for twentieth and twenty-first century IDs", () => {
  assert.equal(birthDateFromId("9001010000000", TODAY), "1990-01-01");
  assert.equal(birthDateFromId("0402290000000", TODAY), "2004-02-29");
  assert.equal(birthDateFromId("2610080000000", TODAY), "1926-10-08");
});

test("a manually corrected century is accepted only when the full calendar date is real and matches", () => {
  assert.equal(birthDateMatchesId("1920-01-01", "2001010000000", TODAY), true);
  assert.equal(birthDateMatchesId("2020-01-01", "2001010000000", TODAY), true);
  assert.equal(birthDateMatchesId("1900-02-29", VALID.id_number, TODAY), false);
  assert.ok(validateVerificationDetails({ ...VALID, date_of_birth: "1900-02-29" }, TODAY).date_of_birth);
});

test("missing, invalid, future and mismatched dates cannot be submitted", () => {
  for (const date_of_birth of ["", "2000-02-30", "2000-03-01", "26-10-07", "0000-01-01"]) {
    assert.ok(validateVerificationDetails({ ...VALID, date_of_birth }, TODAY).date_of_birth, date_of_birth);
  }
  assert.match(validateVerificationDetails({ ...VALID, id_number: "2610080000000", date_of_birth: "2026-10-08" }, TODAY).date_of_birth!, /future/);
});

test("finishing or replacing an ID fills the matching date; an incomplete or invalid ID clears the old date", () => {
  const filled = updateVerificationField({ ...VALID, date_of_birth: "" }, "id_number", "9001010000000", TODAY);
  assert.equal(filled.date_of_birth, "1990-01-01");
  assert.equal(updateVerificationField(filled, "id_number", "0402290000000", TODAY).date_of_birth, "2004-02-29");
  assert.equal(updateVerificationField(filled, "id_number", "900101", TODAY).date_of_birth, "");
  assert.equal(updateVerificationField(filled, "id_number", "9002300000000", TODAY).date_of_birth, "");
});

test("ID edits preserve a matching birth year that the applicant has already confirmed", () => {
  const older = { ...VALID, id_number: "2001010000000", date_of_birth: "1920-01-01" };
  assert.equal(updateVerificationField(older, "id_number", "2001010000001", TODAY).date_of_birth, "1920-01-01");
  assert.equal(updateVerificationField(older, "first_name", "Anne", TODAY).date_of_birth, "1920-01-01");
});

test("name minimums count letters, not padding, apostrophes, hyphens or digits", () => {
  for (const key of ["first_name", "middle_names", "last_name", "previous_surname", "household_head_name"] as const) {
    for (const value of ["Al", "  Al  ", "A-B", "123", "Alice1", "<Alice>"]) {
      assert.ok(validateVerificationDetails({ ...VALID, [key]: value }, TODAY)[key], `${key}: ${value}`);
    }
  }
});

test("three-letter, accented, hyphenated and apostrophe names remain valid", () => {
  for (const first_name of ["Amy", "Zoë", "Zoe\u0308", "Anne-Marie", "O’Neil", "O'Neil", "Anna Maria"]) {
    assert.equal(validateVerificationDetails({ ...VALID, first_name }, TODAY).first_name, undefined, first_name);
  }
});

test("only Male and Female are valid choices and gender cannot be left blank", () => {
  for (const gender of ["", "unknown", "male", "123"]) {
    assert.ok(validateVerificationDetails({ ...VALID, gender }, TODAY).gender);
  }
  for (const gender of ["Male", "Female"]) {
    assert.equal(validateVerificationDetails({ ...VALID, gender }, TODAY).gender, undefined);
  }
});

test("the existing required contact and address fields are checked before uploads", () => {
  for (const key of ["cellphone_number", "house_number", "street_address", "relationship_to_household_head"] as const) {
    assert.ok(validateVerificationDetails({ ...VALID, [key]: "   " }, TODAY)[key]);
  }
});

test("normalizing a submission trims values and composes accents without changing the input object", () => {
  const input = { ...VALID, first_name: " Zoe\u0308 ", id_number: ` ${VALID.id_number} ` };
  const normalized = normalizeVerificationDetails(input);
  assert.equal(normalized.first_name, "Zoë");
  assert.equal(normalized.id_number, VALID.id_number);
  assert.equal(input.first_name, " Zoe\u0308 ");
  assert.deepEqual(validateVerificationDetails(input, TODAY), {});
});
