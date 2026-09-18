"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {initializeTestEnvironment, assertFails, assertSucceeds} = require("@firebase/rules-unit-testing");
const {doc, getDoc, setDoc, updateDoc, serverTimestamp} = require("firebase/firestore");

let environment;
test.before(async () => {
  environment = await initializeTestEnvironment({
    projectId: "holiday-resort-7fa3f",
    firestore: {rules: fs.readFileSync(path.join(__dirname, "..", "firestore.rules"), "utf8")}
  });
  await environment.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "users/admin-user"), {name: "Admin", role: "admin", isActive: true});
    await setDoc(doc(db, "users/owner-a"), {name: "Owner A", role: "owner", isActive: true});
    await setDoc(doc(db, "users/owner-b"), {name: "Owner B", role: "owner", isActive: true});
    await setDoc(doc(db, "users/security-a"), {name: "Security A", role: "security", isActive: true});
    await setDoc(doc(db, "units/unit-a"), {ownerId: "owner-a", unitNumber: "101", isActive: true});
    await setDoc(doc(db, "units/unit-b"), {ownerId: "owner-b", unitNumber: "202", isActive: true});
    await setDoc(doc(db, "qr_codes/qr-a"), {qrId: "qr-a", ownerId: "owner-a", unitId: "unit-a", type: "guest", guestCount: 2, status: "active", usedAt: null});
    await setDoc(doc(db, "qr_codes/qr-b"), {qrId: "qr-b", ownerId: "owner-b", unitId: "unit-b", type: "guest", guestCount: 2, status: "active", usedAt: null});
    await setDoc(doc(db, "daily_guest_limits/unit-a_2026-08-31"), {ownerId: "owner-a", unitId: "unit-a", dailyLimit: 6, reservedGuests: 2});
    await setDoc(doc(db, "reports/report-a"), {ownerId: "owner-a", unitId: "unit-a", status: "pending", adminReply: null, adminResponse: null, updatedAt: null});
  });
});
test.after(async () => environment?.cleanup());

function ownerDb(uid) { return environment.authenticatedContext(uid).firestore(); }

test("Owner cannot read another Owner QR or spoof another unit", async () => {
  await assertFails(getDoc(doc(ownerDb("owner-a"), "qr_codes/qr-b")));
  await assertFails(updateDoc(doc(ownerDb("owner-a"), "qr_codes/qr-b"), {status: "cancelled"}));
  await assertFails(setDoc(doc(ownerDb("owner-a"), "reports/spoof"), {
    ownerId: "owner-a", ownerName: "Owner A", unitId: "unit-b", unitNumber: "202",
    category: "general", message: "request", description: "request", status: "pending",
    createdAt: serverTimestamp(), updatedAt: null, adminReply: null, adminResponse: null
  }));
});

test("Unauthenticated users cannot read or write protected data", async () => {
  const db = environment.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, "users/owner-a")));
  await assertFails(getDoc(doc(db, "units/unit-a")));
  await assertFails(getDoc(doc(db, "qr_codes/qr-a")));
  await assertFails(setDoc(doc(db, "reports/anonymous"), {message: "forged"}));
});

test("Owner cannot assign a unit or change unit ownership", async () => {
  const db = ownerDb("owner-a");
  await assertFails(setDoc(doc(db, "units/forged"), {
    ownerId: "owner-a", unitNumber: "999", isActive: true
  }));
  await assertFails(updateDoc(doc(db, "units/unit-b"), {ownerId: "owner-a"}));
  await assertFails(updateDoc(doc(db, "units/unit-a"), {ownerId: "owner-b"}));
});

test("Owner cannot forge report identity even on an assigned unit", async () => {
  await assertFails(setDoc(doc(ownerDb("owner-a"), "reports/foreign-owner"), {
    ownerId: "owner-b", ownerName: "Owner B", unitId: "unit-a", unitNumber: "101",
    category: "general", message: "request", description: "request", status: "pending",
    createdAt: serverTimestamp(), updatedAt: null, adminReply: null, adminResponse: null
  }));
});

test("Owner cannot directly create, consume, or mutate immutable QR fields", async () => {
  const db = ownerDb("owner-a");
  await assertFails(setDoc(doc(db, "qr_codes/forged"), {ownerId: "owner-a", unitId: "unit-a", status: "used"}));
  await assertFails(updateDoc(doc(db, "qr_codes/qr-a"), {guestCount: 6}));
  await assertFails(updateDoc(doc(db, "qr_codes/qr-a"), {status: "used", usedAt: serverTimestamp()}));
  await assertFails(updateDoc(doc(db, "qr_codes/qr-a"), {status: "cancelled", cancelledAt: serverTimestamp()}));
});

test("Owner cannot reset quota or write administration fields", async () => {
  const db = ownerDb("owner-a");
  await assertFails(updateDoc(doc(db, "daily_guest_limits/unit-a_2026-08-31"), {reservedGuests: 0}));
  await assertFails(updateDoc(doc(db, "reports/report-a"), {adminReply: "forged", updatedAt: serverTimestamp()}));
  await assertFails(updateDoc(doc(db, "reports/report-a"), {status: "resolved", updatedAt: serverTimestamp()}));
});

test("Mobile clients cannot read, create, or forge entry drafts", async () => {
  const owner = ownerDb("owner-a");
  const security = environment.authenticatedContext("security-a").firestore();
  const forged = {draftId: "forged", qrId: "qr-a", ownerId: "owner-a", unitId: "unit-a",
    type: "guest", guestCount: 2, securityUserId: "security-a", status: "pending"};
  await assertFails(setDoc(doc(owner, "entry_drafts/owner-forged"), forged));
  await assertFails(setDoc(doc(security, "entry_drafts/security-forged"), forged));
  await assertFails(getDoc(doc(security, "entry_drafts/security-forged")));
});

test("Owner can create a valid report and Admin can update protected fields", async () => {
  const report = doc(ownerDb("owner-a"), "reports/valid-owner-report");
  await assertSucceeds(setDoc(report, {ownerId: "owner-a", ownerName: "Owner A", unitId: "unit-a", unitNumber: "101",
    category: "general", message: "request", description: "request", status: "pending",
    createdAt: serverTimestamp(), updatedAt: null, adminReply: null, adminResponse: null}));
  const adminDb = environment.authenticatedContext("admin-user", {admin: true}).firestore();
  await assertSucceeds(updateDoc(doc(adminDb, "reports/valid-owner-report"), {
    status: "resolved", adminReply: "done", adminResponse: "done", updatedAt: serverTimestamp()
  }));
  assert.equal(true, true);
});

test("Inactive Admin and claim-only Admin cannot read protected records", async () => {
  await environment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/inactive-admin"), {role: "admin", isActive: false});
  });
  await assertFails(getDoc(doc(environment.authenticatedContext("inactive-admin", {admin: true}).firestore(), "units/unit-a")));
  await assertFails(getDoc(doc(environment.authenticatedContext("claim-only", {admin: true}).firestore(), "units/unit-a")));
});

