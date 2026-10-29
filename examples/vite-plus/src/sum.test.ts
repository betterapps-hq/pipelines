import { expect, test } from "vite-plus/test";
import { sum } from "./sum.ts";

test("adds", () => {
  expect(sum(1, 2)).toBe(3);
});
