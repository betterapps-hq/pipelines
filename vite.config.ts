import { defineConfig } from "vite-plus"

/** Formats the templates, modules and docs, as Parity formats its own. Each example workspace keeps its own settings. */
export default defineConfig({
  fmt: {
    printWidth: 120,
    semi: false,
    trailingComma: "none",
    proseWrap: "always",
    ignorePatterns: ["examples/**", "**/node_modules/**", "**/.terraform/**", "**/pnpm-lock.yaml"]
  },
  lint: {
    ignorePatterns: ["examples/**", "**/node_modules/**"]
  }
})
