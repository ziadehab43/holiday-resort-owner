"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {DateTime} = require("luxon");
const {dayWindow} = require("./index")._test;

test("dayWindow expires at the next Cairo midnight", () => {
  const now = DateTime.fromISO("2026-08-31T20:45:00", {zone: "Africa/Cairo"});
  const result = dayWindow(now);
  assert.equal(result.date, "2026-08-31");
  assert.equal(DateTime.fromJSDate(result.expiresAt, {zone: "Africa/Cairo"}).toISO(), "2026-09-01T00:00:00.000+03:00");
});
