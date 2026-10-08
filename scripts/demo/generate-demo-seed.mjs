#!/usr/bin/env node
// Builds the demonstration village in data/demo-seed — the same six-file
// package as data/legacy-import, so it goes through the same importer:
//
//   node scripts/demo/generate-demo-seed.mjs        (writes data/demo-seed)
//   npm run import:demo:dry-run                     (checks it, sends nothing)
//   SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… npm run import:demo
//
// Every person is invented. Names are common Xitsonga and Tshivenda names
// for the Mhinga area; ID numbers have the real South African shape
// (date of birth, gender digits, citizenship, checksum) so they pass the
// same validation a real resident's would, but belong to nobody. Email
// addresses use example.org, which can never receive mail.
//
// The output is the same every run: the random numbers come from a fixed
// seed, not the clock.

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "../../data/demo-seed");

// ---- deterministic randomness ----------------------------------------
let state = 20261008;
function random() {
  // mulberry32
  state = (state + 0x6d2b79f5) | 0;
  let t = Math.imul(state ^ (state >>> 15), 1 | state);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const int = (min, max) => min + Math.floor(random() * (max - min + 1));
const pick = (list) => list[Math.floor(random() * list.length)];
const chance = (p) => random() < p;

// ---- names -----------------------------------------------------------
const SURNAMES = [
  "Baloyi", "Maluleke", "Chauke", "Mathebula", "Ngobeni", "Hlungwani", "Rikhotso",
  "Shirilele", "Mabunda", "Khosa", "Nkuna", "Mhlongo", "Shibambu", "Mashele",
  "Mashaba", "Novela", "Mukhari", "Sambo", "Hlongwane", "Makhubele", "Ndlovu",
  "Mavhunga", "Netshiongolwe", "Mudau", "Ramavhoya", "Tshikovhi", "Nemakonde",
  "Chabalala", "Ngoveni", "Shivambu",
];
const MALE = [
  "Hlulani", "Nyiko", "Rhulani", "Vutomi", "Tiyani", "Amukelani", "Ntsako",
  "Kulani", "Themba", "Sipho", "Tshepo", "Mpho", "Lufuno", "Takalani", "Rendani",
  "Ndivhuwo", "Tsakani", "Musa", "Basani", "Khensani", "Hlayisani", "Risuna",
  "Xolani", "Samuel", "Joseph", "Daniel", "Elias", "Moses", "Petrus", "Wilson",
];
const FEMALE = [
  "Tsakani", "Nyeleti", "Hlengiwe", "Ntsakisi", "Rirhandzu", "Mixo", "Kurhula",
  "Tintswalo", "Nkateko", "Hlamalani", "Ntombi", "Vongani", "Murendeni",
  "Mashudu", "Ndivhuho", "Fulufhelo", "Thandeka", "Lerato", "Kgaogelo",
  "Nomsa", "Grace", "Maria", "Esther", "Lydia", "Florah", "Agnes", "Beauty",
  "Patience", "Sarah", "Ruth",
];

// Sections of the village used for addresses.
const SECTIONS = ["Mhinga Zone 1", "Mhinga Zone 2", "Mhinga-Vhuyani", "Shitlhelani", "Mhinga Central"];
const STREETS = ["Marula", "Mopani", "Baobab", "Nkuna", "Hosi Mhinga", "Xikundu", "Mutale", "Nandoni", "Tsonga", "Mahlathi"];

// ---- South African ID numbers -----------------------------------------
function luhnCheckDigit(twelveDigits) {
  // The check digit that makes the full 13-digit number pass Luhn.
  let sum = 0;
  for (let i = 0; i < 12; i++) {
    let d = Number(twelveDigits[11 - i]);
    if (i % 2 === 0) { d *= 2; if (d > 9) d -= 9; }
    sum += d;
  }
  return String((10 - (sum % 10)) % 10);
}

const usedIds = new Set();
function idNumber(dob, gender) {
  const yymmdd = dob.slice(2, 4) + dob.slice(5, 7) + dob.slice(8, 10);
  for (;;) {
    const sequence = gender === "Female" ? int(0, 4999) : int(5000, 9999);
    const body = yymmdd + String(sequence).padStart(4, "0") + "0" + "8";
    const id = body + luhnCheckDigit(body);
    if (!usedIds.has(id)) { usedIds.add(id); return id; }
  }
}

function date(yearFrom, yearTo) {
  const y = int(yearFrom, yearTo);
  const m = int(1, 12);
  const d = int(1, [31, y % 4 === 0 ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]);
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

const usedPhones = new Set();
function phone() {
  for (;;) {
    const n = pick(["06", "07", "08"]) + pick(["0", "1", "2", "3", "6", "8", "9"]) + String(int(0, 9999999)).padStart(7, "0");
    if (!usedPhones.has(n)) { usedPhones.add(n); return n; }
  }
}

// ---- the village -------------------------------------------------------
const HOUSEHOLDS = 32;
const residents = [];
const households = [];
const memberships = [];
const relationships = [];
const sites = [];
const allocations = [];

let residentSeq = 0;
function person({ first, last, gender, dob, status = "active", withContact = true }) {
  residentSeq += 1;
  const code = `R-${String(residentSeq).padStart(4, "0")}`;
  const r = {
    resident_code: code,
    id_number: idNumber(dob, gender),
    first_name: first,
    last_name: last,
    date_of_birth: dob,
    gender,
    contact_number: withContact ? phone() : "",
    email: withContact && chance(0.45)
      ? `${first}.${last}.${residentSeq}`.toLowerCase().replace(/[^a-z0-9.]/g, "") + "@example.org"
      : "",
    resident_status: status,
  };
  residents.push(r);
  return r;
}

function relate(a, b, typeAtoB, typeBtoA) {
  relationships.push({ resident_code: a.resident_code, related_resident_code: b.resident_code, relationship_type: typeAtoB, relationship_status: "active" });
  relationships.push({ resident_code: b.resident_code, related_resident_code: a.resident_code, relationship_type: typeBtoA, relationship_status: "active" });
}

const surnamesInUse = [...SURNAMES].sort(() => random() - 0.5);
const usedStands = new Set();

for (let h = 1; h <= HOUSEHOLDS; h++) {
  const surname = surnamesInUse[(h - 1) % surnamesInUse.length];
  const section = pick(SECTIONS);
  let stand;
  do { stand = int(1001, 2400); } while (usedStands.has(stand));
  usedStands.add(stand);

  const siteCode = `RES-${String(h).padStart(4, "0")}`;
  sites.push({
    site_code: siteCode,
    site_type: "residential",
    stand_number: `ST-${stand}`,
    street_address: `${int(1, 180)} ${pick(STREETS)} Street`,
    village_section: section,
    village_name: "Mhinga Village",
    site_status: "allocated",
  });

  const members = [];
  const headIsMale = chance(0.62);
  const head = person({
    first: pick(headIsMale ? MALE : FEMALE), last: surname,
    gender: headIsMale ? "Male" : "Female", dob: date(1952, 1986),
  });
  members.push(head);

  let spouse = null;
  if (chance(0.75)) {
    spouse = person({
      first: pick(headIsMale ? FEMALE : MALE), last: surname,
      gender: headIsMale ? "Female" : "Male", dob: date(1955, 1990),
    });
    members.push(spouse);
    relate(head, spouse, "spouse", "spouse");
  }

  const headYear = Number(head.date_of_birth.slice(0, 4));
  const children = [];
  for (let c = 0, n = int(1, 4); c < n; c++) {
    const male = chance(0.5);
    const childYear = Math.min(headYear + int(20, 38), 2016);
    const child = person({
      first: pick(male ? MALE : FEMALE), last: surname,
      gender: male ? "Male" : "Female", dob: date(childYear, childYear),
      withContact: childYear <= 2007,
    });
    members.push(child);
    children.push(child);
    relate(head, child, "parent", "child");
    if (spouse) relate(spouse, child, "parent", "child");
  }
  for (let i = 0; i < children.length; i++) {
    for (let j = i + 1; j < children.length; j++) relate(children[i], children[j], "sibling", "sibling");
  }

  // Some homes still have a grandparent living with them; a few have
  // passed on but stay on the register.
  if (chance(0.25)) {
    const male = chance(0.4);
    const elder = person({
      first: pick(male ? MALE : FEMALE), last: surname,
      gender: male ? "Male" : "Female", dob: date(Math.max(1930, headYear - 34), headYear - 20),
      status: chance(0.3) ? "deceased" : "active", withContact: false,
    });
    members.push(elder);
    relate(elder, head, "parent", "child");
    for (const child of children) relate(elder, child, "grandparent", "grandchild");
  }

  const householdCode = `HH-${String(h).padStart(4, "0")}`;
  households.push({ household_code: householdCode, primary_site_code: siteCode, head_resident_code: head.resident_code, household_status: "active" });
  for (const m of members) memberships.push({ household_code: householdCode, resident_code: m.resident_code });

  allocations.push({
    allocation_code: `ALLOC-${String(h).padStart(4, "0")}`,
    site_code: siteCode,
    allocated_to_resident_code: head.resident_code,
    allocation_date: date(Math.min(headYear + 22, 2023), Math.min(headYear + 30, 2024)),
    allocation_status: "active",
  });
}

// ---- write the package -------------------------------------------------
function csv(rows, columns) {
  const escape = (v) => (/[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
  return [columns.join(","), ...rows.map((r) => columns.map((c) => escape(r[c] ?? "")).join(","))].join("\n") + "\n";
}

await mkdir(OUT, { recursive: true });
const files = {
  "land_sites.csv": csv(sites, ["site_code", "site_type", "stand_number", "street_address", "village_section", "village_name", "site_status"]),
  "residents.csv": csv(residents, ["resident_code", "id_number", "first_name", "last_name", "date_of_birth", "gender", "contact_number", "email", "resident_status"]),
  "households.csv": csv(households, ["household_code", "primary_site_code", "head_resident_code", "household_status"]),
  "household_memberships.csv": csv(memberships, ["household_code", "resident_code"]),
  "family_relationships.csv": csv(relationships, ["resident_code", "related_resident_code", "relationship_type", "relationship_status"]),
  "land_allocations.csv": csv(allocations, ["allocation_code", "site_code", "allocated_to_resident_code", "allocation_date", "allocation_status"]),
  "import_order.csv": csv(
    ["land_sites.csv", "residents.csv", "households.csv", "household_memberships.csv", "family_relationships.csv", "land_allocations.csv"]
      .map((file_name, i) => ({ import_order: i + 1, file_name })),
    ["import_order", "file_name"],
  ),
};
for (const [name, text] of Object.entries(files)) await writeFile(join(OUT, name), text);

console.log(
  `Wrote ${OUT}: ${sites.length} sites, ${residents.length} residents, ${households.length} households, ` +
  `${relationships.length} relationships, ${allocations.length} allocations.`,
);
