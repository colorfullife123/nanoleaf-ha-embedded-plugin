"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

async function main() {
  const root = path.resolve(__dirname, "..");
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "nha-config-test-"));
  try {
    const electronDir = path.join(temporaryRoot, "node_modules", "electron");
    fs.mkdirSync(electronDir, { recursive: true });
    fs.writeFileSync(path.join(electronDir, "package.json"), JSON.stringify({
      name: "electron",
      version: "0.0.0-test",
      type: "module",
      exports: "./index.js",
    }));
    fs.writeFileSync(path.join(electronDir, "index.js"), `
      export const app = {
        getVersion: () => "3.0.0-test",
        once: () => {},
        whenReady: () => new Promise(() => {}),
        setLoginItemSettings: (settings) => { globalThis.testLoginSettings = settings; },
        removeAllListeners: () => {},
      };
      export class BrowserWindow {
        static getAllWindows() { return []; }
      }
      export const clipboard = { writeText: () => {} };
      export const ipcMain = {
        handle: () => {},
        on: () => {},
        removeAllListeners: () => {},
        removeHandler: () => {},
      };
      export const shell = { openPath: () => {}, openExternal: () => {} };
    `);

    const source = fs.readFileSync(path.join(root, "m.mjs"), "utf8") +
      "\nexport { loadConfig, saveConfig, selectedDevices, yamlConfig, applyAutoStart };\n";
    const modulePath = path.join(temporaryRoot, "m.mjs");
    fs.writeFileSync(modulePath, source);
    const plugin = await import(pathToFileURL(modulePath).href);

    const baseConfig = {
      enabled: true,
      port: 17654,
      token: "a".repeat(64),
      haIp: "192.0.2.50",
      pcIp: "192.0.2.20",
      autoStart: true,
      devices: {
        j: { id: "DEVICE_SERIAL_A", model: "NL82K1", name: "左侧灯板", port: 0 },
        k: { id: "DEVICE_SERIAL_B", model: "NL82K1", name: "右侧灯板", port: 0 },
      },
    };
    plugin.saveConfig(baseConfig);
    const loaded = plugin.loadConfig();
    assert.equal(loaded.version, 2);
    assert.deepEqual(Object.keys(loaded.devices), ["j", "k"]);
    assert.equal(plugin.selectedDevices("all").length, 2);

    plugin.applyAutoStart(true);
    assert.equal(globalThis.testLoginSettings.openAtLogin, true);
    assert(globalThis.testLoginSettings.path.endsWith("wscript.exe"));
    assert.deepEqual(globalThis.testLoginSettings.args, ["//B", "//Nologo", path.join(temporaryRoot, "startup.vbs"), "--hidden"]);
    plugin.applyAutoStart(false);
    assert.equal(globalThis.testLoginSettings.openAtLogin, false);
    delete globalThis.testLoginSettings;

    const yaml = plugin.yamlConfig();
    assert(yaml.includes("http://192.0.2.20:17654/device/j"));
    assert(yaml.includes("http://192.0.2.20:17654/device/k"));
    assert(yaml.includes("http://192.0.2.20:17654/device/all"));
    assert(yaml.includes('name: "左侧灯板"'));
    assert(yaml.includes("Bearer " + "a".repeat(64)));

    plugin.saveConfig({ ...baseConfig, devices: { j: baseConfig.devices.j } });
    const oneDeviceYaml = plugin.yamlConfig();
    assert(oneDeviceYaml.includes("/device/j"));
    assert(!oneDeviceYaml.includes("/device/k"));
    assert(oneDeviceYaml.includes("/device/all"));
    assert.throws(() => plugin.selectedDevices("k"), /not configured/);

    console.log("Dynamic device configuration and HA YAML generation checks passed.");
  } finally {
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
