import { defineConfig } from "vite-plus";

export default defineConfig({
  // Its own fmt block, so formatting doesn't find the repository's config above it.
  fmt: {},
  lint: {
    options: { typeAware: true, typeCheck: true },
  },
});
