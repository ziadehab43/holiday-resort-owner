import {createAdminHandler} from './admin.js';
import {DateTime} from "luxon";

const TIME_ZONE = "Africa/Cairo";
const DAILY_LIMIT = 6;
const ENTRY_DRAFT_TTL_MS = 15 * 60 * 1000;
const MAX_ID_IMAGE_BYTES = 5 * 1024 * 1024;
const MAX_CHILDREN = 10;
const ID_IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const ID_BUCKET = "gate-id-cards";
const NO_ID_REASONS = new Set(["young", "lost", "other"]);
const FIRESTORE_SCOPE = "https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/identitytoolkit";
const TOKEN_AUDIENCE = "https://oauth2.googleapis.com/token";
let googleKeys;
let googleKeysExpiresAt = 0;
let serviceToken;

class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"}
});

function base64UrlBytes(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function base64Url(value) {
  const bytes = value instanceof Uint8Array ? value : new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function parseJwt(token) {
  const parts = token.split(".");
  if (parts.length !== 3) throw new ApiError(401, "unauthenticated", "Invalid authentication token.");
  try {
    return {
      header: JSON.parse(new TextDecoder().decode(base64UrlBytes(parts[0]))),
      claims: JSON.parse(new TextDecoder().decode(base64UrlBytes(parts[1]))),
      signed: new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
      signature: base64UrlBytes(parts[2])
    };
  } catch (_) {
    throw new ApiError(401, "unauthenticated", "Invalid authentication token.");
  }
}

async function firebaseKeys() {
  if (googleKeys && Date.now() < googleKeysExpiresAt) return googleKeys;
  const response = await fetch("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com");
  if (!response.ok) throw new ApiError(503, "auth-unavailable", "Authentication verification is unavailable.");
  const cache = response.headers.get("cache-control")?.match(/max-age=(\d+)/);
  googleKeysExpiresAt = Date.now() + Number(cache?.[1] || 300) * 1000;
  googleKeys = (await response.json()).keys;
  return googleKeys;
}

async function verifyFirebaseToken(request, env) {
  const authorization = request.headers.get("authorization") || "";
  if (!authorization.startsWith("Bearer ")) throw new ApiError(401, "unauthenticated", "Authentication is required.");
  const token = authorization.slice(7);
  const decoded = parseJwt(token);
  if (decoded.header.alg !== "RS256" || typeof decoded.header.kid !== "string") throw new ApiError(401, "unauthenticated", "Invalid authentication token.");
  const jwk = (await firebaseKeys()).find((key) => key.kid === decoded.header.kid);
  if (!jwk) throw new ApiError(401, "unauthenticated", "Unknown authentication key.");
  const key = await crypto.subtle.importKey("jwk", jwk, {name: "RSASSA-PKCS1-v1_5", hash: "SHA-256"}, false, ["verify"]);
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, decoded.signature, decoded.signed);
  const now = Math.floor(Date.now() / 1000);
  const claims = decoded.claims;
  if (!valid || claims.aud !== env.FIREBASE_PROJECT_ID ||
      claims.iss !== `https://securetoken.google.com/${env.FIREBASE_PROJECT_ID}` ||
      !claims.sub || claims.exp <= now || claims.iat > now + 60 || claims.auth_time > now + 60) {
    throw new ApiError(401, "unauthenticated", "Authentication token is expired or invalid.");
  }
  return claims;
}

function pemBytes(pem) {
  const clean = pem.replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  return Uint8Array.from(atob(clean), (character) => character.charCodeAt(0));
}

async function serviceAccessToken(env) {
  if (serviceToken && serviceToken.expiresAt > Date.now() + 60000) return serviceToken.value;
  if (!env.FIREBASE_CLIENT_EMAIL || !env.FIREBASE_PRIVATE_KEY) throw new ApiError(503, "backend-not-configured", "Backend credentials are not configured.");
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({alg: "RS256", typ: "JWT"}));
  const payload = base64Url(JSON.stringify({iss: env.FIREBASE_CLIENT_EMAIL, scope: FIRESTORE_SCOPE, aud: TOKEN_AUDIENCE, iat: now, exp: now + 3600}));
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(env.FIREBASE_PRIVATE_KEY), {name: "RSASSA-PKCS1-v1_5", hash: "SHA-256"}, false, ["sign"]);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${payload}`));
  const response = await fetch(TOKEN_AUDIENCE, {method: "POST", headers: {"content-type": "application/x-www-form-urlencoded"},
    body: new URLSearchParams({grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${header}.${payload}.${base64Url(new Uint8Array(signature))}`})});
  if (!response.ok) throw new ApiError(503, "backend-auth-failed", "Backend authentication failed.");
  const result = await response.json();
  serviceToken = {value: result.access_token, expiresAt: Date.now() + Number(result.expires_in || 3600) * 1000};
  return serviceToken.value;
}

const documentsBase = (env) => `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents`;
const documentName = (env, path) => `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/${path}`;
const field = {
  string: (value) => ({stringValue: String(value)}),
  integer: (value) => ({integerValue: String(value)}),
  timestamp: (value) => ({timestampValue: value instanceof Date ? value.toISOString() : value}),
  null: () => ({nullValue: null}),
  map: (value) => ({mapValue: {fields: Object.fromEntries(Object.entries(value).map(([key, item]) => [key, encodeValue(item)]))}})
};

function encodeValue(value) {
  if (value === null || value === undefined) return field.null();
  if (typeof value === "boolean") return {booleanValue:value};
  if (Array.isArray(value)) return {arrayValue:{values:value.map(encodeValue)}};
  if (value?.reference) return {referenceValue:value.reference};
  if (typeof value === "string") return field.string(value);
  if (Number.isInteger(value)) return field.integer(value);
  if (value instanceof Date) return field.timestamp(value);
  if (typeof value === "object" && !Array.isArray(value)) return field.map(value);
  throw new ApiError(500, "internal", "Unsupported Firestore value.");
}

function decodeValue(value) {
  if (!value) return undefined;
  if ("arrayValue" in value) return (value.arrayValue.values || []).map(decodeValue);
  if ("stringValue" in value) return value.stringValue;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("doubleValue" in value) return Number(value.doubleValue);
  if ("booleanValue" in value) return value.booleanValue;
  if ("timestampValue" in value) return value.timestampValue;
  if ("nullValue" in value) return null;
  if ("mapValue" in value) {
    return Object.fromEntries(Object.entries(value.mapValue.fields || {}).map(([key, item]) => [key, decodeValue(item)]));
  }
  return undefined;
}

function decodeDocument(document) {
  if (!document) return null;
  return {name: document.name, updateTime: document.updateTime,
    data: Object.fromEntries(Object.entries(document.fields || {}).map(([key, value]) => [key, decodeValue(value)]))};
}

async function firestoreFetch(env, token, path, init = {}) {
  const response = await fetch(path.startsWith("http") ? path : `${documentsBase(env)}${path}`, {
    ...init, headers: {...init.headers, authorization: `Bearer ${token}`, "content-type": "application/json"}
  });
  if (!response.ok) {
    const error = await response.json().catch(() => ({}));
    const code = error.error?.status || "FIRESTORE_ERROR";
    const apiError = new ApiError(response.status, code, error.error?.message || "Firestore request failed.");
    apiError.firestoreCode = code;
    throw apiError;
  }
  return response.status === 204 ? null : response.json();
}

async function beginTransaction(env, token) {
  const result = await firestoreFetch(env, token, `${documentsBase(env)}:beginTransaction`, {method: "POST", body: "{}"});
  return result.transaction;
}

async function getDocument(env, token, path, transaction) {
  const url = new URL(`${documentsBase(env)}/${path}`);
  if (transaction) url.searchParams.set("transaction", transaction);
  try { return decodeDocument(await firestoreFetch(env, token, url.toString())); }
  catch (error) { if (error.status === 404) return null; throw error; }
}

async function runGuestQuery(env, token, uid, unitId, validDate, transaction) {
  const result = await firestoreFetch(env, token, `${documentsBase(env)}:runQuery`, {method: "POST", body: JSON.stringify({transaction,
    structuredQuery: {from: [{collectionId: "qr_codes"}], where: {compositeFilter: {op: "AND", filters: [
      ["ownerId", uid], ["unitId", unitId], ["type", "guest"], ["validDate", validDate]
    ].map(([fieldPath, value]) => ({fieldFilter: {field: {fieldPath}, op: "EQUAL", value: field.string(value)}}))}}}})});
  return result.map((entry) => decodeDocument(entry.document)).filter(Boolean);
}

async function commit(env, token, transaction, writes) {
  return firestoreFetch(env, token, `${documentsBase(env)}:commit`, {method: "POST", body: JSON.stringify({transaction, writes})});
}

async function withTransaction(env, operation) {
  const token = await serviceAccessToken(env);
  for (let attempt = 0; attempt < 5; attempt++) {
    const transaction = await beginTransaction(env, token);
    try {
      const value = await operation({token, transaction});
      await commit(env, token, transaction, value.writes);
      return value.result;
    } catch (error) {
      if (error.firestoreCode === "ABORTED" && attempt < 4) {
        await new Promise((resolve) => setTimeout(resolve, 150 * (2 ** attempt)));
        continue;
      }
      throw error;
    }
  }
  throw new ApiError(409, "transaction-conflict", "Please retry the request.");
}

function dayWindow(now = DateTime.now().setZone(TIME_ZONE)) {
  const start = now.startOf("day");
  return {date: start.toFormat("yyyy-LL-dd"), expiresAt: start.plus({days: 1}).toUTC().toISO()};
}

function secureId(bytes = 24) {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64Url(value);
}

function requiredString(body, key, maximum = 200) {
  const value = body?.[key];
  if (typeof value !== "string" || value.trim().length === 0 || value.trim().length > maximum) throw new ApiError(400, "invalid-argument", `${key} is invalid.`);
  return value.trim();
}

function assertOwner(user, unit, uid) {
  if (!user || user.data.role !== "owner" || user.data.isActive !== true || user.data.adminOperation) throw new ApiError(403, "permission-denied", "Active Owner account required.");
  if (!unit || unit.data.ownerId !== uid || unit.data.isActive !== true) throw new ApiError(403, "permission-denied", "The unit is not assigned to this Owner.");
}

function assertSecurity(user, claims) {
  if (!user || user.data.isActive !== true ||
      !(claims.admin === true || claims.security === true || ["admin", "security"].includes(user.data.role))) {
    throw new ApiError(403, "UNAUTHORIZED", "Active Security or Admin account required.");
  }
}

function assertInspectableQr(qr, qrToken, now = Date.now()) {
  if (!qr) throw new ApiError(404, "QR_NOT_FOUND", "QR code not found.");
  if (qr.data.qrToken !== qrToken) throw new ApiError(403, "INVALID_QR_TOKEN", "Invalid QR authenticity token.");
  if (qr.data.status === "cancelled") throw new ApiError(409, "QR_CANCELLED", "QR code has been cancelled.");
  if (qr.data.status !== "active" || qr.data.usedAt) throw new ApiError(409, "QR_ALREADY_USED", "QR code has already been used or invalidated.");
  const expiresAt = Date.parse(qr.data.expiresAt);
  if (!Number.isFinite(expiresAt) || expiresAt <= now) throw new ApiError(410, "QR_EXPIRED", "QR code has expired.");
}

function trustedQrResult(qr, unit) {
  return {valid: true, qrId: qr.data.qrId || qr.name.split("/").pop(), type: qr.data.type,
    ownerName: qr.data.ownerName || "", unitId: qr.data.unitId, unitNumber: unit.data.unitNumber || qr.data.unitNumber || "",
    buildingNumber: unit.data.buildingNumber || "", floorNumber: unit.data.floorNumber || "",
    guestCount: Number(qr.data.guestCount || 0), expiresAt: qr.data.expiresAt,
    deliveryType: qr.data.deliveryType || null};
}

function activeGuestTotal(records) {
  return records.reduce((sum, item) =>
    ["active", "used"].includes(item.data.status)
      ? sum + Number(item.data.guestCount || 0)
      : sum, 0);
}

function assertGuestLimit(records, guestCount) {
  const reserved = activeGuestTotal(records);
  if (reserved + guestCount > DAILY_LIMIT) {
    throw new ApiError(409, "daily-limit-exceeded", "Daily guest limit exceeded.");
  }
  return reserved;
}

function assertCancellableQr(qr, uid, now = Date.now()) {
  if (qr.data.ownerId !== uid || qr.data.type !== "guest") {
    throw new ApiError(403, "permission-denied", "QR ownership mismatch.");
  }
  if (qr.data.status !== "active" || qr.data.usedAt) {
    throw new ApiError(409, "failed-precondition", "Only an unused active QR can be cancelled.");
  }
  if (Date.parse(qr.data.expiresAt) <= now) {
    throw new ApiError(409, "failed-precondition", "QR code has expired.");
  }
}

const serverTransform = (path) => ({fieldPath: path, setToServerValue: "REQUEST_TIME"});
const precondition = (document) => document ? {updateTime: document.updateTime} : {exists: false};

async function generateQr(env, uid, body, type) {
  const unitId = requiredString(body, "unitId");
  const guestCount = type === "guest" ? body.guestCount : 1;
  if (!Number.isInteger(guestCount) || guestCount < 1 || guestCount > DAILY_LIMIT) throw new ApiError(400, "invalid-argument", "guestCount must be between 1 and 6.");
  const deliveryType = type === "delivery" ? requiredString(body, "deliveryType", 80) : null;
  const {date, expiresAt} = dayWindow();
  const qrId = secureId();
  const qrToken = secureId(32);
  return withTransaction(env, async ({token, transaction}) => {
    const [user, unit] = await Promise.all([
      getDocument(env, token, `users/${uid}`, transaction), getDocument(env, token, `units/${unitId}`, transaction)
    ]);
    assertOwner(user, unit, uid);
    const qrFields = {qrId: field.string(qrId), ownerId: field.string(uid), ownerName: field.string(user.data.name || ""),
      unitId: field.string(unitId), unitNumber: field.string(unit.data.unitNumber || ""), type: field.string(type),
      guestCount: field.integer(guestCount), qrToken: field.string(qrToken), status: field.string("active"),
      validDate: field.string(date), expiresAt: field.timestamp(expiresAt), usedAt: field.null(), cancelledAt: field.null()};
    if (deliveryType) qrFields.deliveryType = field.string(deliveryType);
    const writes = [];
    if (type === "guest") {
      const counterPath = `daily_guest_limits/${unitId}_${date}`;
      const [counter, guestRecords] = await Promise.all([
        getDocument(env, token, counterPath, transaction),
        runGuestQuery(env, token, uid, unitId, date, transaction)
      ]);
      // QR records are the source of truth. Rebuild the cached counter on every
      // mutation so an old/partially migrated counter cannot block valid guests.
      const reserved = assertGuestLimit(guestRecords, guestCount);
      writes.push({update: {name: documentName(env, counterPath), fields: {ownerId: field.string(uid), unitId: field.string(unitId),
        validDate: field.string(date), dailyLimit: field.integer(DAILY_LIMIT), reservedGuests: field.integer(reserved + guestCount)}},
        updateTransforms: [serverTransform("updatedAt")], currentDocument: precondition(counter)});
    }
    writes.push({update: {name: documentName(env, `qr_codes/${qrId}`), fields: qrFields},
      updateTransforms: [serverTransform("createdAt")], currentDocument: {exists: false}});
    return {writes, result: {qrId, ownerId: uid, unitId, unitNumber: unit.data.unitNumber || "", type, deliveryType,
      guestCount, qrToken, status: "active", validDate: date, createdAt: Date.now(), expiresAt: Date.parse(expiresAt)}};
  });
}

async function cancelGuestQr(env, uid, body) {
  const qrId = requiredString(body, "qrId");
  const token = await serviceAccessToken(env);
  for (let attempt = 0; attempt < 5; attempt++) {
    const qr = await getDocument(env, token, `qr_codes/${qrId}`);
    if (!qr) throw new ApiError(404, "not-found", "QR code not found.");
    const [user, unit] = await Promise.all([getDocument(env, token, `users/${uid}`),
      getDocument(env, token, `units/${qr.data.unitId}`)]);
    assertOwner(user, unit, uid);
    assertCancellableQr(qr, uid);
    // QR documents are the quota source of truth. The next generation rebuilds
    // the cached daily counter from active/used QR records, so cancellation
    // need only change this QR atomically. This avoids a hot-counter write.
    const updateUrl = new URL(`${documentsBase(env)}/qr_codes/${qrId}`);
    updateUrl.searchParams.append("updateMask.fieldPaths", "status");
    updateUrl.searchParams.append("updateMask.fieldPaths", "cancelledAt");
    try {
      await firestoreFetch(env, token, updateUrl.toString(), {method: "PATCH", body: JSON.stringify({fields: {
        status: field.string("cancelled"), cancelledAt: field.timestamp(new Date())
      }})});
      return {qrId, status: "cancelled"};
    } catch (error) {
      if (error.firestoreCode === "ABORTED" && attempt < 4) {
        await new Promise((resolve) => setTimeout(resolve, 1000 * (2 ** attempt)));
        continue;
      }
      throw error;
    }
  }
  throw new ApiError(409, "transaction-conflict", "Please retry cancellation.");
}

async function inspectQr(env, claims, body) {
  const qrId = requiredString(body, "qrId");
  const qrToken = requiredString(body, "qrToken");
  const token = await serviceAccessToken(env);
  const [user, qr] = await Promise.all([
    getDocument(env, token, `users/${claims.sub}`),
    getDocument(env, token, `qr_codes/${qrId}`)
  ]);
  assertSecurity(user, claims);
  assertInspectableQr(qr, qrToken);
  const unit = await getDocument(env, token, `units/${qr.data.unitId}`);
  if (!unit || unit.data.isActive !== true) throw new ApiError(409, "UNIT_UNAVAILABLE", "QR unit is unavailable.");
    assertOwner(await getDocument(env, token, `users/${qr.data.ownerId}`), unit, qr.data.ownerId);
  return trustedQrResult(qr, unit);
}

async function createEntryDraft(env, claims, body) {
  const qrId = requiredString(body, "qrId");
  const qrToken = requiredString(body, "qrToken");
  const draftId = secureId();
  const expiresAt = new Date(Date.now() + ENTRY_DRAFT_TTL_MS);
  return withTransaction(env, async ({token, transaction}) => {
    const [user, qr] = await Promise.all([
      getDocument(env, token, `users/${claims.sub}`, transaction),
      getDocument(env, token, `qr_codes/${qrId}`, transaction)
    ]);
    assertSecurity(user, claims);
    assertInspectableQr(qr, qrToken);
    const unit = await getDocument(env, token, `units/${qr.data.unitId}`, transaction);
    if (!unit || unit.data.isActive !== true) throw new ApiError(409, "UNIT_UNAVAILABLE", "QR unit is unavailable.");
    assertOwner(await getDocument(env, token, `users/${qr.data.ownerId}`, transaction), unit, qr.data.ownerId);
    const fields = {draftId: field.string(draftId), qrId: field.string(qrId), ownerId: field.string(qr.data.ownerId),
      unitId: field.string(qr.data.unitId), type: field.string(qr.data.type), guestCount: field.integer(Number(qr.data.guestCount || 0)),
      securityUserId: field.string(claims.sub), status: field.string("pending"), expiresAt: field.timestamp(expiresAt),
      cleanupAfter: field.timestamp(expiresAt), adultIdentifications: field.map({})};
    if (qr.data.type === "delivery") fields.identificationCount = field.integer(1);
    return {writes: [{update: {name: documentName(env, `entry_drafts/${draftId}`), fields},
      updateTransforms: [serverTransform("createdAt")], currentDocument: {exists: false}}],
    result: {draftId, status: "pending", draftExpiresAt: expiresAt.getTime(), ...trustedQrResult(qr, unit)}};
  });
}

function assertPendingDraft(draft, claims, user, now = Date.now()) {
  if (!draft) throw new ApiError(404, "DRAFT_NOT_FOUND", "Entry draft not found.");
  assertSecurity(user, claims);
  const admin = claims.admin === true || user.data.role === "admin";
  if (!admin && draft.data.securityUserId !== claims.sub) throw new ApiError(403, "FOREIGN_DRAFT", "Entry draft belongs to another Security user.");
  if (draft.data.status !== "pending") throw new ApiError(409, "DRAFT_NOT_PENDING", "Entry draft is no longer pending.");
  const expiry = Date.parse(draft.data.expiresAt);
  if (!Number.isFinite(expiry) || expiry <= now) throw new ApiError(410, "DRAFT_EXPIRED", "Entry draft has expired.");
}

function imageExtension(contentType) {
  return contentType === "image/jpeg" ? "jpg" : contentType === "image/png" ? "png" : "webp";
}

function storageObjectPath(draftId, adultIndex, side, contentType) {
  return `gate-entry-drafts/${draftId}/adults/${adultIndex}/${side}.${imageExtension(contentType)}`;
}

function assertIdImageMetadata({draft, claims, user, adultIndex, side, contentType, size}) {
  assertPendingDraft(draft, claims, user);
  if (!["front", "back"].includes(side)) throw new ApiError(400, "INVALID_IMAGE_SIDE", "Image side must be front or back.");
  const identificationCount = draft.data.type === "delivery" ? 1 : Number(draft.data.guestCount || 0);
  if (!Number.isInteger(adultIndex) || adultIndex < 0 || adultIndex >= identificationCount) {
    throw new ApiError(400, "INVALID_ADULT_INDEX", "adultIndex exceeds the allowed guest count.");
  }
  if (!["guest", "delivery"].includes(draft.data.type)) {
    throw new ApiError(409, "ID_IMAGES_NOT_REQUIRED", "ID images are not required for this QR type.");
  }
  if (!ID_IMAGE_TYPES.has(contentType)) throw new ApiError(415, "INVALID_IMAGE_TYPE", "Unsupported ID image type.");
  if (!Number.isInteger(size) || size <= 0 || size > MAX_ID_IMAGE_BYTES) {
    throw new ApiError(413, "IMAGE_TOO_LARGE", "ID image must not exceed 5 MB.");
  }
}

async function uploadPrivateObject(env, objectPath, contentType, bytes) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SECRET_KEY) throw new ApiError(503, "STORAGE_NOT_CONFIGURED", "Private ID storage is not configured.");
  const base = env.SUPABASE_URL.replace(/\/+$/, "");
  const encodedPath = objectPath.split("/").map(encodeURIComponent).join("/");
  const response = await fetch(`${base}/storage/v1/object/${ID_BUCKET}/${encodedPath}`, {method: "POST", headers: {
    authorization: `Bearer ${env.SUPABASE_SECRET_KEY}`, apikey: env.SUPABASE_SECRET_KEY,
    "content-type": contentType, "x-upsert": "true"
  }, body: bytes});
  if (!response.ok) throw new ApiError(502, "STORAGE_UPLOAD_FAILED", "Private ID image upload failed.");
}

async function uploadEntryIdImage(env, claims, form) {
  const draftId = requiredString(Object.fromEntries(form), "draftId");
  const side = requiredString(Object.fromEntries(form), "side", 10);
  const adultIndex = Number(form.get("adultIndex"));
  const image = form.get("image");
  if (!image || typeof image.arrayBuffer !== "function") throw new ApiError(400, "IMAGE_REQUIRED", "Image file is required.");
  const contentType = String(image.type || "").toLowerCase();
  const token = await serviceAccessToken(env);
  const [user, draft] = await Promise.all([
    getDocument(env, token, `users/${claims.sub}`), getDocument(env, token, `entry_drafts/${draftId}`)
  ]);
  assertIdImageMetadata({draft, claims, user, adultIndex, side, contentType, size: image.size});
  const objectPath = storageObjectPath(draftId, adultIndex, side, contentType);
  await uploadPrivateObject(env, objectPath, contentType, await image.arrayBuffer());
  await withTransaction(env, async ({token: transactionToken, transaction}) => {
    const [currentUser, currentDraft] = await Promise.all([
      getDocument(env, transactionToken, `users/${claims.sub}`, transaction),
      getDocument(env, transactionToken, `entry_drafts/${draftId}`, transaction)
    ]);
    assertPendingDraft(currentDraft, claims, currentUser);
    const adultIdentifications = currentDraft.data.adultIdentifications || {};
    const adultKey = `adult_${adultIndex}`;
    const current = adultIdentifications[adultKey];
    adultIdentifications[adultKey] = {idStatus: "provided",
      ...(current?.idStatus === "provided" && typeof current.frontPath === "string" ? {frontPath: current.frontPath} : {}),
      ...(current?.idStatus === "provided" && typeof current.backPath === "string" ? {backPath: current.backPath} : {}),
      [`${side}Path`]: objectPath};
    return {writes: [{update: {name: currentDraft.name, fields: {adultIdentifications: field.map(adultIdentifications)}},
      updateMask: {fieldPaths: ["adultIdentifications"]}, updateTransforms: [serverTransform("updatedAt")],
      currentDocument: {updateTime: currentDraft.updateTime}}], result: null};
  });
  return {draftId, adultIndex, side, objectPath};
}

function assertNoIdMetadata(body) {
  const noIdReason = requiredString(body, "noIdReason", 40);
  const fullName = requiredString(body, "fullName", 120);
  const age = body.age;
  const explanation = typeof body.explanation === "string" ? body.explanation.trim() : "";
  if (!NO_ID_REASONS.has(noIdReason)) throw new ApiError(400, "INVALID_NO_ID_REASON", "No-ID reason is invalid.");
  if (!Number.isInteger(age) || age < 10 || age > 120) throw new ApiError(400, "INVALID_NO_ID_AGE", "No-ID visitor age must be between 10 and 120.");
  if (explanation.length > 200 || (noIdReason === "other" && explanation.length === 0)) {
    throw new ApiError(400, "INVALID_NO_ID_EXPLANATION", "A valid explanation is required for the Other reason.");
  }
  return {noIdReason, fullName, age, ...(explanation ? {explanation} : {})};
}

async function setEntryVisitorIdState(env, claims, body) {
  const draftId = requiredString(body, "draftId");
  const adultIndex = body.adultIndex;
  if (!Number.isInteger(adultIndex)) throw new ApiError(400, "INVALID_ADULT_INDEX", "adultIndex is invalid.");
  if (body.idStatus !== "no_id") throw new ApiError(400, "INVALID_ID_STATUS", "Only explicit no_id state is accepted by this endpoint.");
  const metadata = assertNoIdMetadata(body);
  return withTransaction(env, async ({token, transaction}) => {
    const [user, draft] = await Promise.all([
      getDocument(env, token, `users/${claims.sub}`, transaction),
      getDocument(env, token, `entry_drafts/${draftId}`, transaction)
    ]);
    assertPendingDraft(draft, claims, user);
    if (draft.data.type !== "guest") throw new ApiError(409, "NO_ID_NOT_ALLOWED", "No-ID is not allowed for Delivery entry.");
    if (adultIndex < 0 || adultIndex >= Number(draft.data.guestCount || 0)) {
      throw new ApiError(400, "INVALID_ADULT_INDEX", "adultIndex exceeds the allowed guest count.");
    }
    const adultIdentifications = draft.data.adultIdentifications || {};
    adultIdentifications[`adult_${adultIndex}`] = {idStatus: "no_id", ...metadata};
    return {writes: [{update: {name: draft.name, fields: {adultIdentifications: field.map(adultIdentifications)}},
      updateMask: {fieldPaths: ["adultIdentifications"]}, updateTransforms: [serverTransform("updatedAt")],
      currentDocument: {updateTime: draft.updateTime}}], result: {draftId, adultIndex, idStatus: "no_id"}};
  });
}

function expectedImagePath(draftId, adultIndex, side, value) {
  return typeof value === "string" && new RegExp(`^gate-entry-drafts/${draftId}/adults/${adultIndex}/${side}\\.(jpg|png|webp)$`).test(value);
}

function requiredAdultIdentifications(draft) {
  const count = Number(draft.data.guestCount || 0);
  const identifications = draft.data.adultIdentifications || {};
  for (let index = 0; index < count; index++) {
    const adult = identifications[`adult_${index}`];
    if (!adult || !["provided", "no_id"].includes(adult.idStatus)) {
      throw new ApiError(409, "ID_STATE_INCOMPLETE", "Every counted guest requires an explicit identification state.");
    }
    if (adult.idStatus === "provided" &&
        (!expectedImagePath(draft.data.draftId, index, "front", adult.frontPath) ||
         !expectedImagePath(draft.data.draftId, index, "back", adult.backPath))) {
      throw new ApiError(409, "ID_IMAGES_INCOMPLETE", "Front and back ID images are required for every guest marked ID provided.");
    }
    if (adult.idStatus === "no_id") {
      assertNoIdMetadata(adult);
      if (adult.frontPath !== undefined || adult.backPath !== undefined) {
        throw new ApiError(409, "NO_ID_STATE_INCONSISTENT", "No-ID guests cannot reference ID images.");
      }
    }
  }
  return identifications;
}

function requiredDeliveryIdentification(draft) {
  const identifications = draft.data.adultIdentifications || {};
  const keys = Object.keys(identifications);
  const adult = identifications.adult_0;
  if (keys.length !== 1 || !adult || adult.idStatus !== "provided") {
    throw new ApiError(409, "DELIVERY_ID_REQUIRED", "Delivery requires exactly one provided identification record.");
  }
  if (!expectedImagePath(draft.data.draftId, 0, "front", adult.frontPath) ||
      !expectedImagePath(draft.data.draftId, 0, "back", adult.backPath)) {
    throw new ApiError(409, "ID_IMAGES_INCOMPLETE", "Delivery requires front and back ID images.");
  }
  return identifications;
}

function providedImageReferences(identifications) {
  return Object.fromEntries(Object.entries(identifications)
    .filter(([, adult]) => adult.idStatus === "provided")
    .map(([key, adult]) => [key, {frontPath: adult.frontPath, backPath: adult.backPath}]));
}

function assertChildrenCount(childrenCount) {
  if (!Number.isInteger(childrenCount) || childrenCount < 0 || childrenCount > MAX_CHILDREN) {
    throw new ApiError(400, "INVALID_CHILDREN_COUNT", "childrenCount must be between 0 and 10.");
  }
}

function assertDraftQrMatch(draft, qr) {
  if (!qr) throw new ApiError(404, "QR_NOT_FOUND", "QR code not found.");
  if (qr.data.ownerId !== draft.data.ownerId || qr.data.unitId !== draft.data.unitId ||
      qr.data.type !== draft.data.type || Number(qr.data.guestCount || 0) !== Number(draft.data.guestCount || 0)) {
    throw new ApiError(409, "QR_DRAFT_MISMATCH", "QR data no longer matches the entry draft.");
  }
}

function buildConfirmMutation(env, {entryId, draft, qr, unit, claims, adultIdentifications, adultCount, childrenCount}) {
  const gateFields = {entryId: field.string(entryId), qrId: field.string(draft.data.qrId), ownerId: field.string(qr.data.ownerId),
    ownerName: field.string(qr.data.ownerName || ""), unitId: field.string(qr.data.unitId),
    unitNumber: field.string(unit.data.unitNumber || qr.data.unitNumber || ""),
    buildingNumber: field.string(unit.data.buildingNumber || ""), floorNumber: field.string(unit.data.floorNumber || ""),
    type: field.string(qr.data.type), guestCount: field.integer(Number(qr.data.guestCount || 0)),
    allowedGuestCount: field.integer(Number(qr.data.guestCount || 0)), adultCount: field.integer(adultCount),
    securityUserId: field.string(claims.sub),
    draftId: field.string(draft.data.draftId), adultIdentifications: field.map(adultIdentifications),
    adultImages: field.map(providedImageReferences(adultIdentifications))};
  if (qr.data.type === "guest") gateFields.childrenCount = field.integer(childrenCount);
  if (qr.data.deliveryType) gateFields.deliveryType = field.string(qr.data.deliveryType);
  return [
    {update: {name: qr.name, fields: {status: field.string("used")}}, updateMask: {fieldPaths: ["status"]},
      updateTransforms: [serverTransform("usedAt")], currentDocument: {updateTime: qr.updateTime}},
    {update: {name: documentName(env, `gate_entries/${entryId}`), fields: gateFields},
      updateTransforms: [serverTransform("enteredAt")], currentDocument: {exists: false}},
    {update: {name: draft.name, fields: {status: field.string("confirmed"), gateEntryId: field.string(entryId)}},
      updateMask: {fieldPaths: ["status", "gateEntryId"]}, updateTransforms: [serverTransform("confirmedAt")],
      currentDocument: {updateTime: draft.updateTime}}
  ];
}

async function confirmEntry(env, claims, body) {
  const draftId = requiredString(body, "draftId");
  const entryId = secureId();
  return withTransaction(env, async ({token, transaction}) => {
    const [user, draft] = await Promise.all([
      getDocument(env, token, `users/${claims.sub}`, transaction),
      getDocument(env, token, `entry_drafts/${draftId}`, transaction)
    ]);
    assertPendingDraft(draft, claims, user);
    const qr = await getDocument(env, token, `qr_codes/${draft.data.qrId}`, transaction);
    assertDraftQrMatch(draft, qr);
    assertInspectableQr(qr, qr.data.qrToken);
    const unit = await getDocument(env, token, `units/${qr.data.unitId}`, transaction);
    if (!unit || unit.data.isActive !== true) throw new ApiError(409, "UNIT_UNAVAILABLE", "QR unit is unavailable.");
    assertOwner(await getDocument(env, token, `users/${qr.data.ownerId}`, transaction), unit, qr.data.ownerId);
    const guest = qr.data.type === "guest";
    const childrenCount = guest ? body.childrenCount : undefined;
    if (guest) assertChildrenCount(childrenCount);
    const delivery = qr.data.type === "delivery";
    const adultIdentifications = guest ? requiredAdultIdentifications(draft) :
      delivery ? requiredDeliveryIdentification(draft) : {};
    const adultCount = guest ? Number(qr.data.guestCount || 0) : delivery ? 1 : 0;
    const writes = buildConfirmMutation(env, {entryId, draft, qr, unit, claims, adultIdentifications, adultCount, childrenCount});
    return {writes, result: {entryId, qrId: draft.data.qrId, unitId: qr.data.unitId,
      unitNumber: unit.data.unitNumber || qr.data.unitNumber || "", type: qr.data.type,
      allowedGuestCount: Number(qr.data.guestCount || 0), adultCount,
      ...(guest ? {childrenCount} : {}), status: "used"}};
  });
}

async function validateAndUseQr(env, claims, body) {
  const qrId = requiredString(body, "qrId");
  const qrToken = requiredString(body, "qrToken");
  return withTransaction(env, async ({token, transaction}) => {
    const [user, qr] = await Promise.all([getDocument(env, token, `users/${claims.sub}`, transaction),
      getDocument(env, token, `qr_codes/${qrId}`, transaction)]);
    if (!user || user.data.isActive !== true || !(claims.admin === true || claims.security === true || ["admin", "security"].includes(user.data.role))) throw new ApiError(403, "permission-denied", "Security role required.");
    if (!qr) throw new ApiError(404, "not-found", "QR code not found.");
    if (qr.data.type === "delivery") throw new ApiError(409, "DELIVERY_DRAFT_REQUIRED", "Delivery entry requires the secure ID draft workflow.");
    if (qr.data.qrToken !== qrToken) throw new ApiError(403, "permission-denied", "Invalid QR authenticity token.");
    if (typeof body.unitId === "string" && body.unitId !== qr.data.unitId) throw new ApiError(409, "unit-mismatch", "QR unit mismatch.");
    if (qr.data.status !== "active" || qr.data.usedAt) throw new ApiError(409, "already-used", "QR code has already been used or invalidated.");
    if (Date.parse(qr.data.expiresAt) <= Date.now()) throw new ApiError(410, "expired", "QR code has expired.");
    const entryId = secureId();
    const unit = await getDocument(env, token, `units/${qr.data.unitId}`, transaction);
    assertOwner(await getDocument(env, token, `users/${qr.data.ownerId}`, transaction), unit, qr.data.ownerId);
    const writes = [
      {update: {name: qr.name, fields: {status: field.string("used")}}, updateMask: {fieldPaths: ["status"]},
        updateTransforms: [serverTransform("usedAt")], currentDocument: {updateTime: qr.updateTime}},
      {update: {name: documentName(env, `gate_entries/${entryId}`), fields: {qrId: field.string(qrId), ownerId: field.string(qr.data.ownerId),
        unitId: field.string(qr.data.unitId), ownerName: field.string(qr.data.ownerName || ""), buildingNumber: field.string(unit.data.buildingNumber || ""), unitNumber: field.string(unit.data.unitNumber || ""), floorNumber: field.string(unit.data.floorNumber || ""), type: field.string(qr.data.type), guestCount: field.integer(qr.data.guestCount),
        securityUserId: field.string(claims.sub)}}, updateTransforms: [serverTransform("enteredAt")], currentDocument: {exists: false}}
    ];
    return {writes, result: {qrId, unitId: qr.data.unitId, unitNumber: qr.data.unitNumber || "", type: qr.data.type,
      guestCount: qr.data.guestCount, status: "used"}};
  });
}

const adminHandler = createAdminHandler({ApiError, serviceAccessToken, getDocument, firestoreFetch, documentsBase, documentName, encodeValue, decodeDocument, withTransaction, requiredString});

const APP_VERSIONS = Object.freeze({
  owner: {latestVersion:"1.1.0",latestBuild:2,minimumSupportedVersion:"1.1.0",minimumSupportedBuild:2,forceUpdate:false,releaseNotes:"QR connectivity fix and secure update support",apkSha256:"55572E4147117EC5AEBE345477718FA5B75C9CEDCDB47EB29DCE1BB39C71BF3B",apkSize:70163567},
  security: {latestVersion:"1.1.0",latestBuild:2,minimumSupportedVersion:"1.1.0",minimumSupportedBuild:2,forceUpdate:false,releaseNotes:"Secure update support",apkSha256:"6D36DF46203A9F8A2DE2B5FC379AF32DF7BD274AC9911B4D29CB906F589615D1",apkSize:73526896},
  admin: {latestVersion:"1.1.0",latestBuild:2,minimumSupportedVersion:"1.1.0",minimumSupportedBuild:2,forceUpdate:false,releaseNotes:"Secure update support",apkSha256:"008B705B62C10EB4C7C6A7E67875AF7356DD1EFCAC726769887A56C08096480A",apkSize:58591539}
});

async function publicGet(request, env) {
  const url=new URL(request.url);
  if(url.pathname==="/app-version") {
    const app=(url.searchParams.get("app")||"").toLowerCase(), policy=APP_VERSIONS[app];
    if(!policy) throw new ApiError(400,"invalid-app","app must be owner, security, or admin.");
    return {ok:true,app,...policy,updateUrl:`${url.origin}/downloads/${app}.apk`};
  }
  const match=url.pathname.match(/^\/downloads\/(owner|security|admin)\.apk$/);
  if(match) {
    if(!env.RELEASES) throw new ApiError(503,"release-unavailable","Release storage is not configured.");
    const object=await env.RELEASES.get(`${match[1]}.apk`);
    if(!object) throw new ApiError(404,"release-not-found","Release is not available.");
    return new Response(object.body,{headers:{"content-type":"application/vnd.android.package-archive","content-length":String(object.size),"etag":object.httpEtag,"cache-control":"public, max-age=300","content-disposition":`attachment; filename="holiday-resort-${match[1]}.apk"`}});
  }
  throw new ApiError(404,"not-found","Endpoint not found.");
}
async function route(request, env) {
  if (request.method !== "POST") throw new ApiError(405, "method-not-allowed", "POST is required.");
  const path = new URL(request.url).pathname.replace(/\/+$/, "");
  const claims = await verifyFirebaseToken(request, env);
  if (path === "/upload-entry-id-image") {
    const contentType = request.headers.get("content-type") || "";
    if (!contentType.toLowerCase().startsWith("multipart/form-data")) {
      throw new ApiError(415, "MULTIPART_REQUIRED", "multipart/form-data is required.");
    }
    let form;
    try { form = await request.formData(); } catch (_) { throw new ApiError(400, "INVALID_MULTIPART", "Invalid multipart request."); }
    return uploadEntryIdImage(env, claims, form);
  }
  let body;
  try { body = await request.json(); } catch (_) { throw new ApiError(400, "invalid-json", "A JSON body is required."); }
  if (path.startsWith("/admin/")) {
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new ApiError(400, "invalid-argument", "A JSON object is required.");
    return adminHandler(env, claims, path, body);
  }
  if (path === "/generate-guest-qr") return generateQr(env, claims.sub, body, "guest");
  if (path === "/generate-delivery-qr") return generateQr(env, claims.sub, body, "delivery");
  if (path === "/cancel-guest-qr") return cancelGuestQr(env, claims.sub, body);
  if (path === "/inspect-qr") return inspectQr(env, claims, body);
  if (path === "/create-entry-draft") return createEntryDraft(env, claims, body);
  if (path === "/set-entry-visitor-id-state") return setEntryVisitorIdState(env, claims, body);
  if (path === "/confirm-entry") return confirmEntry(env, claims, body);
  if (path === "/validate-and-use-qr") return validateAndUseQr(env, claims, body);
  throw new ApiError(404, "not-found", "Endpoint not found.");
}

export default {
  async fetch(request, env) {
    try { const result = request.method === "GET" ? await publicGet(request, env) : await route(request, env); return result instanceof Response ? result : json(result); }
    catch (error) {
      if (error instanceof ApiError) {
        console.error(JSON.stringify({event:"api-error",path:new URL(request.url).pathname,status:error.status,code:error.firestoreCode||error.code,detail:String(error.message||'').slice(0,240)}));
        const firestoreCode=error.firestoreCode?`firestore-${String(error.firestoreCode).toLowerCase().replace(/_/g,"-")}`:null;
        return json({code:firestoreCode||error.code,message:firestoreCode?"Database operation failed safely. Retry; no partial change was committed.":error.message},error.firestoreCode?503:error.status);
      }
      console.error("Worker request failed");
      return json({code: "internal", message: "The request could not be completed."}, 500);
    }
  }
};

export const testing = {
  activeGuestTotal,
  assertCancellableQr,
  assertGuestLimit,
  assertChildrenCount,
  assertDraftQrMatch,
  assertIdImageMetadata,
  assertInspectableQr,
  assertOwner,
  assertPendingDraft,
  assertSecurity,
  buildConfirmMutation,
  dayWindow,
  imageExtension,
  parseJwt,
  requiredAdultIdentifications,
  requiredDeliveryIdentification,
  providedImageReferences,
  assertNoIdMetadata,
  requiredString,
  secureId,
  storageObjectPath,
  trustedQrResult,
  uploadPrivateObject
};



