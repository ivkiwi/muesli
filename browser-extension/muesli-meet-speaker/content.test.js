const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "content.js"), "utf8");

test("active speakers only come from explicit speaking state", () => {
  assert.doesNotMatch(source, /activeSpeakersFromCaptions/);
  assert.doesNotMatch(source, /\[jscontroller\]/);
  assert.match(source, /activeSpeakersFromAriaLabels\(\)/);
  assert.match(source, /activeSpeakersFromLiveRegions\(\)/);
  assert.match(source, /activeSpeakersFromMeetTiles\(\)/);
});
