// Tiny installer stand-ins exercise artifact collection on every runner without distributing a real application.
import { mkdir, writeFile } from "node:fs/promises"
import { platform } from "node:os"
await mkdir("dist", { recursive: true })
const [extension, metadata] = platform() === "win32" ? ["exe", "latest.yml"] :
  platform() === "darwin" ? ["dmg", "latest-mac.yml"] : ["AppImage", "latest-linux.yml"]
const file = `Example-1.0.0.${extension}`
await writeFile(`dist/${file}`, `Installer fixture for ${platform()}\n`)
await writeFile(`dist/${metadata}`, `version: 1.0.0\npath: ${file}\n`)
