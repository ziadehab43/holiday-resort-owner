"use strict";

const {randomBytes} = require("node:crypto");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue, Timestamp} = require("firebase-admin/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {DateTime} = require("luxon");

initializeApp();
const db = getFirestore();
const DAILY_GUEST_LIMIT = 6;
const TIME_ZONE = "Africa/Cairo";
const CALLABLE_OPTIONS = {maxInstances: 20};

function requireAuth(request) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Authentication is required.");
  return uid;
}

function requiredString(data, field) {
  const value = data?.[field];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return value.trim();
}

function dayWindow(now = DateTime.now().setZone(TIME_ZONE)) {
  const start = now.startOf("day");
  return {date: start.toFormat("yyyy-LL-dd"), expiresAt: start.plus({days: 1}).toJSDate()};
}

function secureToken() {
  return randomBytes(32).toString("base64url");
}

function assertOwner(userSnapshot, unitSnapshot, uid) {
  const user = userSnapshot.data();
  const unit = unitSnapshot.data();
  if (!userSnapshot.exists || user?.role !== "owner" || user?.isActive !== true) {
    throw new HttpsError("permission-denied", "Active Owner account required.");
  }
  if (!unitSnapshot.exists || unit?.ownerId !== uid || unit?.isActive !== true) {
    throw new HttpsError("permission-denied", "The unit is not assigned to this Owner.");
  }
  return {user, unit};
}

function isPrivileged(token, user, role) {
  return token?.admin === true || token?.[role] === true ||
    user?.role === "admin" || user?.role === role;
}

async function legacyReserved(transaction, uid, unitId, validDate) {
  const query = db.collection("qr_codes")
      .where("ownerId", "==", uid).where("unitId", "==", unitId)
      .where("type", "==", "guest").where("validDate", "==", validDate);
  const snapshot = await transaction.get(query);
  return Math.min(DAILY_GUEST_LIMIT, snapshot.docs.reduce((sum, document) => {
    const value = document.data();
    return ["active", "used"].includes(value.status) ? sum + Number(value.guestCount || 0) : sum;
  }, 0));
}

exports.generateGuestQr = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireAuth(request);
  const unitId = requiredString(request.data, "unitId");
  const guestCount = request.data?.guestCount;
  if (!Number.isInteger(guestCount) || guestCount < 1 || guestCount > DAILY_GUEST_LIMIT) {
    throw new HttpsError("invalid-argument", "guestCount must be between 1 and 6.");
  }
  const {date, expiresAt} = dayWindow();
  const userRef = db.collection("users").doc(uid);
  const unitRef = db.collection("units").doc(unitId);
  const counterRef = db.collection("daily_guest_limits").doc(`${unitId}_${date}`);
  const qrRef = db.collection("qr_codes").doc();
  const token = secureToken();

  const result = await db.runTransaction(async (transaction) => {
    const [userSnapshot, unitSnapshot, counterSnapshot] = await Promise.all([
      transaction.get(userRef), transaction.get(unitRef), transaction.get(counterRef)
    ]);
    const {user, unit} = assertOwner(userSnapshot, unitSnapshot, uid);
    const counter = counterSnapshot.data();
    const reserved = counterSnapshot.exists ? Number(counter.reservedGuests || 0) :
      await legacyReserved(transaction, uid, unitId, date);
    if (reserved + guestCount > DAILY_GUEST_LIMIT) {
      throw new HttpsError("resource-exhausted", "Daily guest limit exceeded.");
    }
    const createdAt = FieldValue.serverTimestamp();
    transaction.set(counterRef, {
      ownerId: uid, unitId, validDate: date, dailyLimit: DAILY_GUEST_LIMIT,
      reservedGuests: reserved + guestCount, updatedAt: createdAt
    }, {merge: true});
    transaction.create(qrRef, {
      qrId: qrRef.id, ownerId: uid, ownerName: user.name || "",
      unitId, unitNumber: unit.unitNumber || "", type: "guest", guestCount,
      qrToken: token, status: "active", validDate: date, createdAt,
      expiresAt: Timestamp.fromDate(expiresAt), usedAt: null, cancelledAt: null
    });
    return {unitNumber: unit.unitNumber || ""};
  });
  return {qrId: qrRef.id, ownerId: uid, unitId, unitNumber: result.unitNumber,
    type: "guest", guestCount, qrToken: token, status: "active", validDate: date,
    createdAt: Date.now(), expiresAt: expiresAt.getTime()};
});

exports.cancelGuestQr = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireAuth(request);
  const qrId = requiredString(request.data, "qrId");
  const qrRef = db.collection("qr_codes").doc(qrId);
  await db.runTransaction(async (transaction) => {
    const qrSnapshot = await transaction.get(qrRef);
    if (!qrSnapshot.exists) throw new HttpsError("not-found", "QR code not found.");
    const qr = qrSnapshot.data();
    const userRef = db.collection("users").doc(uid);
    const unitRef = db.collection("units").doc(qr.unitId);
    const counterRef = db.collection("daily_guest_limits").doc(`${qr.unitId}_${qr.validDate}`);
    const [userSnapshot, unitSnapshot, counterSnapshot] = await Promise.all([
      transaction.get(userRef), transaction.get(unitRef), transaction.get(counterRef)
    ]);
    assertOwner(userSnapshot, unitSnapshot, uid);
    if (qr.ownerId !== uid || qr.type !== "guest") throw new HttpsError("permission-denied", "QR ownership mismatch.");
    if (qr.status !== "active" || Boolean(qr.usedAt)) throw new HttpsError("failed-precondition", "Only an unused active QR can be cancelled.");
    if (qr.expiresAt?.toMillis() <= Date.now()) throw new HttpsError("failed-precondition", "QR code has expired.");
    const counter = counterSnapshot.data();
    const reserved = counterSnapshot.exists ? Number(counter.reservedGuests || 0) :
      await legacyReserved(transaction, uid, qr.unitId, qr.validDate);
    transaction.update(qrRef, {status: "cancelled", cancelledAt: FieldValue.serverTimestamp()});
    transaction.set(counterRef, {ownerId: uid, unitId: qr.unitId, validDate: qr.validDate,
      dailyLimit: DAILY_GUEST_LIMIT, reservedGuests: Math.max(0, reserved - Number(qr.guestCount)),
      updatedAt: FieldValue.serverTimestamp()}, {merge: true});
  });
  return {qrId, status: "cancelled"};
});

exports.generateDeliveryQr = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireAuth(request);
  const unitId = requiredString(request.data, "unitId");
  const deliveryType = requiredString(request.data, "deliveryType");
  if (deliveryType.length > 80) throw new HttpsError("invalid-argument", "deliveryType is too long.");
  const {date, expiresAt} = dayWindow();
  const userRef = db.collection("users").doc(uid);
  const unitRef = db.collection("units").doc(unitId);
  const qrRef = db.collection("qr_codes").doc();
  const token = secureToken();
  const unitNumber = await db.runTransaction(async (transaction) => {
    const [userSnapshot, unitSnapshot] = await Promise.all([transaction.get(userRef), transaction.get(unitRef)]);
    const {user, unit} = assertOwner(userSnapshot, unitSnapshot, uid);
    transaction.create(qrRef, {qrId: qrRef.id, ownerId: uid, ownerName: user.name || "",
      unitId, unitNumber: unit.unitNumber || "", type: "delivery", deliveryType,
      guestCount: 1, qrToken: token, status: "active", validDate: date,
      createdAt: FieldValue.serverTimestamp(), expiresAt: Timestamp.fromDate(expiresAt),
      usedAt: null, cancelledAt: null});
    return unit.unitNumber || "";
  });
  return {qrId: qrRef.id, ownerId: uid, unitId, unitNumber, type: "delivery",
    deliveryType, guestCount: 1, qrToken: token, status: "active", validDate: date,
    createdAt: Date.now(), expiresAt: expiresAt.getTime()};
});

exports.validateAndUseQr = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireAuth(request);
  const qrId = requiredString(request.data, "qrId");
  const qrToken = requiredString(request.data, "qrToken");
  const expectedUnitId = request.data?.unitId;
  const userRef = db.collection("users").doc(uid);
  const qrRef = db.collection("qr_codes").doc(qrId);
  const gateRef = db.collection("gate_entries").doc();
  return db.runTransaction(async (transaction) => {
    const [userSnapshot, qrSnapshot] = await Promise.all([transaction.get(userRef), transaction.get(qrRef)]);
    const user = userSnapshot.data();
    if (!userSnapshot.exists || user?.isActive !== true || !isPrivileged(request.auth.token, user, "security")) {
      throw new HttpsError("permission-denied", "Security role required.");
    }
    if (!qrSnapshot.exists) throw new HttpsError("not-found", "QR code not found.");
    const qr = qrSnapshot.data();
    if (qr.qrToken !== qrToken) throw new HttpsError("permission-denied", "Invalid QR authenticity token.");
    if (typeof expectedUnitId === "string" && expectedUnitId !== qr.unitId) throw new HttpsError("failed-precondition", "QR unit mismatch.");
    if (qr.status !== "active" || Boolean(qr.usedAt)) throw new HttpsError("already-exists", "QR code has already been used or invalidated.");
    if (!qr.expiresAt || qr.expiresAt.toMillis() <= Date.now()) throw new HttpsError("deadline-exceeded", "QR code has expired.");
    transaction.update(qrRef, {status: "used", usedAt: FieldValue.serverTimestamp()});
    transaction.create(gateRef, {qrId, ownerId: qr.ownerId, unitId: qr.unitId,
      type: qr.type, guestCount: qr.guestCount, securityUserId: uid,
      enteredAt: FieldValue.serverTimestamp()});
    return {qrId, unitId: qr.unitId, unitNumber: qr.unitNumber || "", type: qr.type,
      guestCount: qr.guestCount, status: "used"};
  });
});

exports._test = {dayWindow};
