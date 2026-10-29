import assert from "node:assert/strict"
import { test } from "node:test"
import semver from "semver"

test("the workspace's dependencies are installed", () => {
  assert.equal(semver.inc("1.0.0", "minor"), "1.1.0")
})
