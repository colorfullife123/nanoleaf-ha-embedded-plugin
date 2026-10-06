"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const required = [
  "LICENSE",
  "README.md",
  "VERSION",
  "asar-patch.cjs",
  "ha-preload.cjs",
  "ha-window.css",
  "ha-window.html",
  "ha-window.js",
  "install.ps1",
  "m.mjs",
  "prepare-update.ps1",
  "repair.ps1",
  "resume-after-update.ps1",
  "runtime.ps1",
  "status.ps1",
  "uninstall.ps1",
];

for (const relativePath of required) {
  assert(fs.existsSync(path.join(root, relativePath)), `Missing ${relativePath}`);
}

assert.equal(fs.readFileSync(path.join(root, "VERSION"), "utf8").trim(), "1.1.5");
assert.equal(require(path.join(root, "package.json")).version, "1.1.5");

for (const relativePath of ["m.mjs", "ha-window.js", "ha-preload.cjs", "asar-patch.cjs"]) {
  const result = spawnSync(process.execPath, ["--check", path.join(root, relativePath)], {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr || `Syntax check failed: ${relativePath}`);
}

const publicFiles = fs.readdirSync(root, { withFileTypes: true })
  .filter((entry) => entry.isFile())
  .map((entry) => entry.name);
const combined = publicFiles
  .map((name) => fs.readFileSync(path.join(root, name), "utf8"))
  .join("\n");

const embeddedDeviceIds = combined.match(/\bV[A-Z0-9]{12}\b/g) || [];
assert.deepEqual(embeddedDeviceIds, [], "A device-like serial was embedded in the package");

for (const forbiddenFile of ["config.json", "patch-state.json", "app.asar"]) {
  assert(!publicFiles.includes(forbiddenFile), `Runtime or official file included: ${forbiddenFile}`);
}

const installer = fs.readFileSync(path.join(root, "install.ps1"), "utf8");
assert(installer.includes("Get-PnpDevice -PresentOnly"));
assert(installer.includes("VID_37FA&PID_8201"));
assert(installer.includes("Get-PreferredIpv4"));
assert(installer.includes("devices = $Devices"));
assert(installer.includes('[string]$HaIp = ""'));
assert(installer.includes('[string]$PcIp = ""'));

const plugin = fs.readFileSync(path.join(root, "m.mjs"), "utf8");
assert(plugin.includes('const DEVICE_KEYS = Object.freeze(["j", "k"])'));
assert(plugin.includes("devices: normalizeDevices(config.devices)"));
assert(plugin.includes("config.devices[key]"));
assert(!plugin.includes("const DEVICES ="));

const readme = fs.readFileSync(path.join(root, "README.md"), "utf8");
assert(readme.includes("与 Nanoleaf 官方无隶属或授权关系"));
assert(readme.includes("不会分发 Nanoleaf Desktop"));

console.log("Package syntax, generic configuration and privacy checks passed.");
