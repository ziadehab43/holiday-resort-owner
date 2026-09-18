import test from "node:test";
import assert from "node:assert/strict";
import {DateTime} from "luxon";
import worker, {testing} from "./index.js";

test("Cairo QR window ends at the next local midnight", () => {
  const result = testing.dayWindow(DateTime.fromISO("2026-08-31T21:00:00", {zone: "Africa/Cairo"}));
  assert.equal(result.date, "2026-08-31");
  assert.equal(result.expiresAt, "2026-08-31T21:00:00.000Z");
});

test("unauthenticated API request is rejected", async () => {
  const response = await worker.fetch(new Request("https://example.test/generate-guest-qr", {
    method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify({unitId: "unit-a", guestCount: 1})
  }), {FIREBASE_PROJECT_ID: "holiday-resort-7fa3f"});
  assert.equal(response.status, 401);
  assert.equal((await response.json()).code, "unauthenticated");
});

test("invalid privileged inputs are rejected", () => {
  assert.throws(() => testing.requiredString({unitId: ""}, "unitId"));
});

test("guest allowance is derived from active and used QR records", () => {
  const records = [
    {data: {status: "used", guestCount: 2}},
    {data: {status: "cancelled", guestCount: 3}},
    {data: {status: "expired", guestCount: 4}}
  ];
  assert.equal(testing.activeGuestTotal(records), 2);
});

test("guest limit counts people across multiple QR records", () => {
  const twoPlusTwo = [
    {data: {status: "active", guestCount: 2}},
    {data: {status: "used", guestCount: 2}}
  ];
  assert.equal(testing.assertGuestLimit(twoPlusTwo, 2), 4);
  assert.throws(
    () => testing.assertGuestLimit(twoPlusTwo, 3),
    (error) => error.code === "daily-limit-exceeded" && error.status === 409
  );

  const threePlusTwo = [
    {data: {status: "active", guestCount: 3}},
    {data: {status: "active", guestCount: 2}}
  ];
  assert.equal(testing.assertGuestLimit(threePlusTwo, 1), 5);
  assert.throws(() => testing.assertGuestLimit(threePlusTwo, 2));
});

test("inactive owners, inactive units, and foreign units are rejected", () => {
  const owner = {data: {role: "owner", isActive: true}};
  const unit = {data: {ownerId: "owner-a", isActive: true}};
  assert.doesNotThrow(() => testing.assertOwner(owner, unit, "owner-a"));
  assert.throws(() => testing.assertOwner({data: {role: "owner", isActive: false}}, unit, "owner-a"));
  assert.throws(() => testing.assertOwner(owner, {data: {ownerId: "owner-a", isActive: false}}, "owner-a"));
  assert.throws(() => testing.assertOwner(owner, unit, "owner-b"));
});

test("cancellation rejects foreign, used, expired, and repeated requests", () => {
  const future = new Date(Date.now() + 60_000).toISOString();
  const active = {data: {ownerId: "owner-a", type: "guest", status: "active", usedAt: null, expiresAt: future}};
  assert.doesNotThrow(() => testing.assertCancellableQr(active, "owner-a"));
  assert.throws(() => testing.assertCancellableQr(active, "owner-b"));
  assert.throws(() => testing.assertCancellableQr({data: {...active.data, status: "cancelled"}}, "owner-a"));
  assert.throws(() => testing.assertCancellableQr({data: {...active.data, status: "used", usedAt: future}}, "owner-a"));
  assert.throws(() => testing.assertCancellableQr({data: {...active.data, expiresAt: "2020-01-01T00:00:00.000Z"}}, "owner-a"));
});

test("cancelling a three-person QR refunds exactly three and never exceeds six", () => {
  const active = {data: {status: "active", guestCount: 3}};
  const records = [active];
  assert.equal(testing.activeGuestTotal(records), 3);

  active.data.status = "cancelled";
  assert.equal(testing.activeGuestTotal(records), 0);
  assert.equal(6 - testing.activeGuestTotal(records), 6);
  assert.equal(testing.assertGuestLimit(records, 6), 0);
  assert.throws(() => testing.assertGuestLimit([
    ...records,
    {data: {status: "active", guestCount: 6}}
  ], 1));
});

test("secure QR identifiers are unique and non-empty", () => {
  const first = testing.secureId();
  const second = testing.secureId();
  assert.notEqual(first, second);
  assert.ok(first.length >= 32);
  assert.ok(second.length >= 32);
});

const future = () => new Date(Date.now() + 60_000).toISOString();
const activeQr = (overrides = {}) => ({name: "projects/p/databases/(default)/documents/qr_codes/qr-a", data: {
  qrId: "qr-a", qrToken: "token-a", ownerId: "owner-a", ownerName: "Owner A", unitId: "unit-a",
  unitNumber: "101", type: "guest", guestCount: 3, status: "active", usedAt: null,
  expiresAt: future(), ...overrides
}});
const securityUser = (role = "security", isActive = true) => ({data: {role, isActive}});
const pendingDraft = (overrides = {}) => ({data: {draftId: "draft-a", qrId: "qr-a", ownerId: "owner-a",
  unitId: "unit-a", type: "guest", guestCount: 3, securityUserId: "security-a", status: "pending",
  expiresAt: future(), adultIdentifications: {}, ...overrides
}});

test("Security and Admin roles are authorized for Security endpoints", () => {
  assert.doesNotThrow(() => testing.assertSecurity(securityUser("security"), {sub: "security-a"}));
  assert.doesNotThrow(() => testing.assertSecurity(securityUser("admin"), {sub: "admin-a"}));
  assert.doesNotThrow(() => testing.assertSecurity(securityUser("owner"), {sub: "claim-a", security: true}));
  assert.doesNotThrow(() => testing.assertSecurity(securityUser("owner"), {sub: "claim-a", admin: true}));
});

test("Owner and inactive accounts cannot use Security endpoints", () => {
  assert.throws(() => testing.assertSecurity(securityUser("owner"), {sub: "owner-a"}), (error) => error.code === "UNAUTHORIZED");
  assert.throws(() => testing.assertSecurity(securityUser("security", false), {sub: "security-a"}));
});

test("active Guest QR passes non-consuming inspection validation", () => {
  const qr = activeQr();
  const before = JSON.stringify(qr);
  assert.doesNotThrow(() => testing.assertInspectableQr(qr, "token-a"));
  assert.doesNotThrow(() => testing.assertInspectableQr(qr, "token-a"));
  assert.equal(JSON.stringify(qr), before);
});

test("inspection rejects missing QR", () => {
  assert.throws(() => testing.assertInspectableQr(null, "token-a"), (error) => error.code === "QR_NOT_FOUND");
});

test("inspection rejects invalid authenticity token", () => {
  assert.throws(() => testing.assertInspectableQr(activeQr(), "forged"), (error) => error.code === "INVALID_QR_TOKEN");
});

test("inspection rejects cancelled QR", () => {
  assert.throws(() => testing.assertInspectableQr(activeQr({status: "cancelled"}), "token-a"), (error) => error.code === "QR_CANCELLED");
});

test("inspection rejects used status and usedAt independently", () => {
  assert.throws(() => testing.assertInspectableQr(activeQr({status: "used"}), "token-a"), (error) => error.code === "QR_ALREADY_USED");
  assert.throws(() => testing.assertInspectableQr(activeQr({usedAt: new Date().toISOString()}), "token-a"), (error) => error.code === "QR_ALREADY_USED");
});

test("inspection rejects expired or malformed expiry", () => {
  assert.throws(() => testing.assertInspectableQr(activeQr({expiresAt: "2020-01-01T00:00:00.000Z"}), "token-a"), (error) => error.code === "QR_EXPIRED");
  assert.throws(() => testing.assertInspectableQr(activeQr({expiresAt: "invalid"}), "token-a"));
});

test("inspection result uses authoritative QR and unit values", () => {
  const result = testing.trustedQrResult(activeQr(), {data: {unitNumber: "U-101", buildingNumber: "B-2", floorNumber: "F-3"}});
  assert.deepEqual(result, {valid: true, qrId: "qr-a", type: "guest", ownerName: "Owner A", unitId: "unit-a",
    unitNumber: "U-101", buildingNumber: "B-2", floorNumber: "F-3", guestCount: 3,
    expiresAt: result.expiresAt, deliveryType: null});
});

test("delivery inspection preserves delivery type without Guest ID requirements", () => {
  const result = testing.trustedQrResult(activeQr({type: "delivery", guestCount: 1, deliveryType: "pharmacy"}),
    {data: {unitNumber: "101", buildingNumber: "1", floorNumber: "2"}});
  assert.equal(result.type, "delivery");
  assert.equal(result.deliveryType, "pharmacy");
});

test("pending draft is bound to its Security UID", () => {
  assert.doesNotThrow(() => testing.assertPendingDraft(pendingDraft(), {sub: "security-a"}, securityUser()));
  assert.throws(() => testing.assertPendingDraft(pendingDraft(), {sub: "security-b"}, securityUser()),
    (error) => error.code === "FOREIGN_DRAFT");
});

test("Admin can operate another Security user's pending draft", () => {
  assert.doesNotThrow(() => testing.assertPendingDraft(pendingDraft(), {sub: "admin-a"}, securityUser("admin")));
});

test("expired and consumed drafts are rejected", () => {
  assert.throws(() => testing.assertPendingDraft(pendingDraft({expiresAt: "2020-01-01T00:00:00.000Z"}),
    {sub: "security-a"}, securityUser()), (error) => error.code === "DRAFT_EXPIRED");
  assert.throws(() => testing.assertPendingDraft(pendingDraft({status: "confirmed"}),
    {sub: "security-a"}, securityUser()), (error) => error.code === "DRAFT_NOT_PENDING");
});

test("private object paths are server generated and contain no personal data", () => {
  assert.equal(testing.storageObjectPath("draft-a", 0, "front", "image/jpeg"),
    "gate-entry-drafts/draft-a/adults/0/front.jpg");
  assert.equal(testing.storageObjectPath("draft-a", 2, "back", "image/png"),
    "gate-entry-drafts/draft-a/adults/2/back.png");
  assert.ok(!testing.storageObjectPath("draft-a", 0, "front", "image/webp").includes("http"));
});

test("valid ID image metadata accepts each private MIME type", () => {
  for (const contentType of ["image/jpeg", "image/png", "image/webp"]) {
    assert.doesNotThrow(() => testing.assertIdImageMetadata({draft: pendingDraft(), claims: {sub: "security-a"},
      user: securityUser(), adultIndex: 0, side: "front", contentType, size: 1024}));
  }
});

test("ID upload rejects invalid MIME type and files over 5 MB", () => {
  const base = {draft: pendingDraft(), claims: {sub: "security-a"}, user: securityUser(), adultIndex: 0, side: "front"};
  assert.throws(() => testing.assertIdImageMetadata({...base, contentType: "application/pdf", size: 1024}),
    (error) => error.code === "INVALID_IMAGE_TYPE");
  assert.throws(() => testing.assertIdImageMetadata({...base, contentType: "image/jpeg", size: 5 * 1024 * 1024 + 1}),
    (error) => error.code === "IMAGE_TOO_LARGE");
});

test("ID upload rejects invalid index, side, and foreign draft", () => {
  const base = {draft: pendingDraft(), claims: {sub: "security-a"}, user: securityUser(),
    adultIndex: 0, side: "front", contentType: "image/jpeg", size: 1024};
  assert.throws(() => testing.assertIdImageMetadata({...base, adultIndex: 3}), (error) => error.code === "INVALID_ADULT_INDEX");
  assert.throws(() => testing.assertIdImageMetadata({...base, side: "profile"}), (error) => error.code === "INVALID_IMAGE_SIDE");
  assert.throws(() => testing.assertIdImageMetadata({...base, claims: {sub: "security-b"}}), (error) => error.code === "FOREIGN_DRAFT");
});

test("Delivery accepts ID upload only for its one delivery person", () => {
  const base = {draft: pendingDraft({type: "delivery", guestCount: 1}), claims: {sub: "security-a"},
    user: securityUser(), side: "front", contentType: "image/jpeg", size: 1024};
  assert.doesNotThrow(() => testing.assertIdImageMetadata({...base, adultIndex: 0}));
  assert.throws(() => testing.assertIdImageMetadata({...base, adultIndex: 1}),
    (error) => error.code === "INVALID_ADULT_INDEX");
});

test("one provided guest with both draft-owned images is valid", () => {
  const draft = pendingDraft({guestCount: 1, adultIdentifications: {
    adult_0: {idStatus: "provided", frontPath: "gate-entry-drafts/draft-a/adults/0/front.jpg",
      backPath: "gate-entry-drafts/draft-a/adults/0/back.jpg"}
  }});
  assert.equal(testing.requiredAdultIdentifications(draft).adult_0.idStatus, "provided");
});

test("one explicitly No-ID guest is valid and auditable", () => {
  const draft = pendingDraft({guestCount: 1, adultIdentifications: {
    adult_0: {idStatus: "no_id", noIdReason: "young", fullName: "Guest One", age: 15}
  }});
  assert.equal(testing.requiredAdultIdentifications(draft).adult_0.idStatus, "no_id");
});

test("mixed provided and No-ID guests are valid", () => {
  const draft = pendingDraft({guestCount: 2, adultIdentifications: {
    adult_0: {idStatus: "provided", frontPath: "gate-entry-drafts/draft-a/adults/0/front.webp",
      backPath: "gate-entry-drafts/draft-a/adults/0/back.png"},
    adult_1: {idStatus: "no_id", noIdReason: "lost", fullName: "Guest Two", age: 30}
  }});
  const adults = testing.requiredAdultIdentifications(draft);
  assert.equal(adults.adult_0.idStatus, "provided");
  assert.equal(adults.adult_1.idStatus, "no_id");
});

test("provided state rejects missing front or back image", () => {
  const base = {idStatus: "provided", frontPath: "gate-entry-drafts/draft-a/adults/0/front.jpg",
    backPath: "gate-entry-drafts/draft-a/adults/0/back.jpg"};
  assert.throws(() => testing.requiredAdultIdentifications(pendingDraft({guestCount: 1,
    adultIdentifications: {adult_0: {...base, frontPath: undefined}}})),
  (error) => error.code === "ID_IMAGES_INCOMPLETE");
  assert.throws(() => testing.requiredAdultIdentifications(pendingDraft({guestCount: 1,
    adultIdentifications: {adult_0: {...base, backPath: undefined}}})),
  (error) => error.code === "ID_IMAGES_INCOMPLETE");
});

test("missing paths are never inferred as No-ID", () => {
  assert.throws(() => testing.requiredAdultIdentifications(pendingDraft({guestCount: 1,
    adultIdentifications: {adult_0: {}}})), (error) => error.code === "ID_STATE_INCOMPLETE");
});

test("image references from another draft or visitor are rejected", () => {
  for (const frontPath of ["gate-entry-drafts/draft-b/adults/0/front.jpg",
    "gate-entry-drafts/draft-a/adults/1/front.jpg"]) {
    assert.throws(() => testing.requiredAdultIdentifications(pendingDraft({guestCount: 1,
      adultIdentifications: {adult_0: {idStatus: "provided", frontPath,
        backPath: "gate-entry-drafts/draft-a/adults/0/back.jpg"}}})),
    (error) => error.code === "ID_IMAGES_INCOMPLETE");
  }
});

test("No-ID metadata is validated and cannot carry image paths", () => {
  assert.throws(() => testing.assertNoIdMetadata({noIdReason: "other", fullName: "Guest", age: 20}),
    (error) => error.code === "INVALID_NO_ID_EXPLANATION");
  assert.throws(() => testing.requiredAdultIdentifications(pendingDraft({guestCount: 1,
    adultIdentifications: {adult_0: {idStatus: "no_id", noIdReason: "lost", fullName: "Guest", age: 20,
      frontPath: "gate-entry-drafts/draft-a/adults/0/front.jpg"}}})),
    (error) => error.code === "NO_ID_STATE_INCONSISTENT");
});

test("Delivery requires exactly one provided front and back identification", () => {
  const valid = {idStatus: "provided",
    frontPath: "gate-entry-drafts/draft-a/adults/0/front.jpg",
    backPath: "gate-entry-drafts/draft-a/adults/0/back.png"};
  const delivery = (adultIdentifications) => pendingDraft({type: "delivery", guestCount: 1, adultIdentifications});
  for (const adultIdentifications of [{},
    {adult_0: {...valid, frontPath: undefined}},
    {adult_0: {...valid, backPath: undefined}}]) {
    assert.throws(() => testing.requiredDeliveryIdentification(delivery(adultIdentifications)),
      (error) => ["DELIVERY_ID_REQUIRED", "ID_IMAGES_INCOMPLETE"].includes(error.code));
  }
  assert.throws(() => testing.requiredDeliveryIdentification(delivery({adult_0: {
    idStatus: "no_id", noIdReason: "lost", fullName: "Courier", age: 30
  }})), (error) => error.code === "DELIVERY_ID_REQUIRED");
  assert.throws(() => testing.requiredDeliveryIdentification(delivery({adult_0: valid, adult_1: valid})),
    (error) => error.code === "DELIVERY_ID_REQUIRED");
  assert.equal(testing.requiredDeliveryIdentification(delivery({adult_0: valid})).adult_0.idStatus, "provided");
});

test("children count is independent and accepts zero through ten", () => {
  assert.doesNotThrow(() => testing.assertChildrenCount(0));
  assert.doesNotThrow(() => testing.assertChildrenCount(10));
  assert.throws(() => testing.assertChildrenCount(11), (error) => error.code === "INVALID_CHILDREN_COUNT");
  assert.throws(() => testing.assertChildrenCount(1.5));
});

test("final confirmation rejects forged owner, unit, type, and guest count", () => {
  const draft = pendingDraft();
  assert.doesNotThrow(() => testing.assertDraftQrMatch(draft, activeQr()));
  for (const overrides of [{ownerId: "forged"}, {unitId: "forged"}, {type: "delivery"}, {guestCount: 6}]) {
    assert.throws(() => testing.assertDraftQrMatch(draft, activeQr(overrides)), (error) => error.code === "QR_DRAFT_MISMATCH");
  }
});

test("final confirmation reuses current QR state checks after inspection", () => {
  for (const overrides of [{status: "cancelled"}, {status: "used"}, {usedAt: new Date().toISOString()},
    {expiresAt: "2020-01-01T00:00:00.000Z"}]) {
    assert.throws(() => testing.assertInspectableQr(activeQr(overrides), "token-a"));
  }
});

test("final confirmation composes one atomic QR, gate-entry, and draft mutation", () => {
  const qr = {...activeQr(), updateTime: "qr-version"};
  const draft = {...pendingDraft(), name: "projects/p/databases/(default)/documents/entry_drafts/draft-a",
    updateTime: "draft-version"};
  const identifications = {adult_0: {idStatus: "provided", frontPath: "private/0/front.jpg", backPath: "private/0/back.jpg"},
    adult_1: {idStatus: "no_id", noIdReason: "lost", fullName: "Guest Two", age: 30},
    adult_2: {idStatus: "provided", frontPath: "private/2/front.jpg", backPath: "private/2/back.jpg"}};
  const writes = testing.buildConfirmMutation({FIREBASE_PROJECT_ID: "project-a"}, {entryId: "entry-a", draft, qr,
    unit: {data: {unitNumber: "101", buildingNumber: "2", floorNumber: "3"}}, claims: {sub: "security-a"},
    adultIdentifications: identifications, adultCount: 3, childrenCount: 2});

  assert.equal(writes.length, 3);
  assert.equal(writes[0].update.fields.status.stringValue, "used");
  assert.equal(writes[0].updateTransforms[0].fieldPath, "usedAt");
  assert.equal(writes[0].currentDocument.updateTime, "qr-version");
  assert.match(writes[1].update.name, /gate_entries\/entry-a$/);
  assert.equal(writes[1].currentDocument.exists, false);
  assert.equal(writes[1].updateTransforms[0].fieldPath, "enteredAt");
  const gate = writes[1].update.fields;
  assert.equal(gate.entryId.stringValue, "entry-a");
  assert.equal(gate.qrId.stringValue, "qr-a");
  assert.equal(gate.ownerId.stringValue, "owner-a");
  assert.equal(gate.ownerName.stringValue, "Owner A");
  assert.equal(gate.unitId.stringValue, "unit-a");
  assert.equal(gate.unitNumber.stringValue, "101");
  assert.equal(gate.buildingNumber.stringValue, "2");
  assert.equal(gate.floorNumber.stringValue, "3");
  assert.equal(gate.guestCount.integerValue, "3");
  assert.equal(gate.allowedGuestCount.integerValue, "3");
  assert.equal(gate.adultCount.integerValue, "3");
  assert.equal(gate.childrenCount.integerValue, "2");
  assert.equal(gate.securityUserId.stringValue, "security-a");
  assert.equal(gate.draftId.stringValue, "draft-a");
  assert.equal(gate.adultIdentifications.mapValue.fields.adult_1.mapValue.fields.idStatus.stringValue, "no_id");
  assert.equal(gate.adultIdentifications.mapValue.fields.adult_1.mapValue.fields.noIdReason.stringValue, "lost");
  assert.equal(gate.adultImages.mapValue.fields.adult_2.mapValue.fields.backPath.stringValue, "private/2/back.jpg");
  assert.equal(gate.adultImages.mapValue.fields.adult_1, undefined);
  assert.equal(writes[2].update.fields.status.stringValue, "confirmed");
  assert.equal(writes[2].update.fields.gateEntryId.stringValue, "entry-a");
  assert.equal(writes[2].updateTransforms[0].fieldPath, "confirmedAt");
  assert.equal(writes[2].currentDocument.updateTime, "draft-version");
});

test("delivery confirmation stores one provided ID and no children field", () => {
  const qr = {...activeQr({type: "delivery", guestCount: 1, deliveryType: "pharmacy"}), updateTime: "qr-version"};
  const identifications = {adult_0: {idStatus: "provided",
    frontPath: "gate-entry-drafts/draft-a/adults/0/front.jpg",
    backPath: "gate-entry-drafts/draft-a/adults/0/back.jpg"}};
  const draft = {...pendingDraft({type: "delivery", guestCount: 1, adultIdentifications: identifications}),
    name: "projects/p/databases/(default)/documents/entry_drafts/draft-a", updateTime: "draft-version"};
  const writes = testing.buildConfirmMutation({FIREBASE_PROJECT_ID: "project-a"}, {entryId: "entry-a", draft, qr,
    unit: {data: {unitNumber: "101"}}, claims: {sub: "security-a"},
    adultIdentifications: testing.requiredDeliveryIdentification(draft), adultCount: 1});
  const gate = writes[1].update.fields;
  assert.equal(writes.length, 3);
  assert.equal(writes[0].update.fields.status.stringValue, "used");
  assert.equal(writes[0].currentDocument.updateTime, "qr-version");
  assert.equal(writes[1].currentDocument.exists, false);
  assert.equal(gate.type.stringValue, "delivery");
  assert.equal(gate.deliveryType.stringValue, "pharmacy");
  assert.equal(gate.adultCount.integerValue, "1");
  assert.equal(gate.childrenCount, undefined);
  assert.equal(gate.adultIdentifications.mapValue.fields.adult_0.mapValue.fields.idStatus.stringValue, "provided");
  assert.equal(gate.adultImages.mapValue.fields.adult_0.mapValue.fields.frontPath.stringValue,
    "gate-entry-drafts/draft-a/adults/0/front.jpg");
});

test("failed Delivery validation creates no mutation and replay states are rejected", () => {
  const incomplete = pendingDraft({type: "delivery", guestCount: 1, adultIdentifications: {
    adult_0: {idStatus: "provided", frontPath: "gate-entry-drafts/draft-a/adults/0/front.jpg"}
  }});
  assert.throws(() => testing.requiredDeliveryIdentification(incomplete),
    (error) => error.code === "ID_IMAGES_INCOMPLETE");
  assert.throws(() => testing.assertPendingDraft(
    pendingDraft({type: "delivery", status: "confirmed"}), {sub: "security-a"}, securityUser()),
  (error) => error.code === "DRAFT_NOT_PENDING");
  assert.throws(() => testing.assertInspectableQr(activeQr({type: "delivery", status: "used"}), "token-a"),
    (error) => error.code === "QR_ALREADY_USED");
});

test("Supabase upload uses only the private object API and server secret headers", async () => {
  const originalFetch = globalThis.fetch;
  let request;
  globalThis.fetch = async (url, init) => {
    request = {url, init};
    return new Response("{}", {status: 200});
  };
  try {
    await testing.uploadPrivateObject({SUPABASE_URL: "https://private-project.supabase.co/",
      SUPABASE_SECRET_KEY: "server-secret"}, "gate-entry-drafts/draft-a/adults/0/front.jpg",
    "image/jpeg", new Uint8Array([1, 2, 3]));
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(request.url,
    "https://private-project.supabase.co/storage/v1/object/gate-id-cards/gate-entry-drafts/draft-a/adults/0/front.jpg");
  assert.ok(!request.url.includes("/public/"));
  assert.equal(request.init.method, "POST");
  assert.equal(request.init.headers.authorization, "Bearer server-secret");
  assert.equal(request.init.headers.apikey, "server-secret");
  assert.equal(request.init.headers["content-type"], "image/jpeg");
  assert.equal(request.init.headers["x-upsert"], "true");
});

test("Supabase upload fails closed when secrets are missing or storage rejects", async () => {
  await assert.rejects(() => testing.uploadPrivateObject({}, "private/path.jpg", "image/jpeg", new Uint8Array([1])),
    (error) => error.code === "STORAGE_NOT_CONFIGURED");
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("denied", {status: 403});
  try {
    await assert.rejects(() => testing.uploadPrivateObject({SUPABASE_URL: "https://private-project.supabase.co",
      SUPABASE_SECRET_KEY: "server-secret"}, "private/path.jpg", "image/jpeg", new Uint8Array([1])),
    (error) => error.code === "STORAGE_UPLOAD_FAILED");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("public app-version endpoint exposes independent safe metadata without authentication",async()=>{
  for(const app of ["owner","security","admin"]){
    const response=await worker.fetch(new Request(`https://worker.example.test/app-version?app=${app}`),{});
    const body=await response.json();assert.equal(response.status,200);assert.equal(body.app,app);
    assert.equal(body.latestBuild,2);assert.equal(body.minimumSupportedBuild,2);
    assert.ok(body.updateUrl.startsWith("https://worker.example.test/downloads/"));
    assert.equal(JSON.stringify(body).includes("PRIVATE_KEY"),false);
  }
  const invalid=await worker.fetch(new Request("https://worker.example.test/app-version?app=unknown"),{});
  assert.equal(invalid.status,400);
});

test("release download fails closed when private release storage is unavailable",async()=>{
  const response=await worker.fetch(new Request("https://worker.example.test/downloads/owner.apk"),{});
  assert.equal(response.status,503);assert.equal((await response.json()).code,"release-unavailable");
});
