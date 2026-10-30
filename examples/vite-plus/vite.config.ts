import { defineConfig } from "vite-plus";

// On Windows, Vite Task records listings of node_modules and node_modules/.vite as the tasks' inputs. Vite and Vitest
// add their own folders there (.vite-temp, .vitest-cache, .vite/vitest) that a restored task cache doesn't bring back,
// so every task would miss on a fresh runner, and check would miss after test in the same job. Leaving those two
// listings out keeps what's in the dependencies tracked.
const cache = { input: [{ auto: true }, "!node_modules", "!node_modules/.vite/**"] };

export default defineConfig({
  // Its own fmt block, so formatting doesn't find the repository's config above it.
  fmt: {},
  lint: {
    options: { typeAware: true, typeCheck: true },
  },
  // Tasks, which Vite Task caches, so CI can keep their results between runs.
  run: {
    tasks: {
      check: { command: "vp check", cache },
      test: { command: "vp test run", cache },
    },
  },
});
