"use strict";

const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const { spawnSync } = require("node:child_process");

// Only the three compatibility markers are included, not official app files.
const fixtures = {
  "3.0.0": [
    'console.log("Running app version",ut.pkg.version);',
    'xm.on("before-quit",async t=>{yMt||(t.preventDefault(),Q$=!0,Wr&&!Wr.isDestroyed()?(xm.dock?.hide(),Wr.hide(),Wr.webContents.send("cleanup")):vMt())});',
    'async function vMt(){bxe(),await Promise.all([VP(),nJ(),CTe(),jDt(),I$()]),s1.deinit(),Ti.deinit(),yMt=!0,xm.quit()}',
  ],
  "3.0.1": [
    'console.log("Running app version",tt.pkg.version);',
    'zm.on("before-quit",async t=>{wMt||(t.preventDefault(),U$=!0,Wr&&!Wr.isDestroyed()?(zm.dock?.hide(),Wr.hide(),Wr.webContents.send("cleanup")):TMt())});',
    'async function TMt(){vxe(),await Promise.all([ZP(),oJ(),MTe(),CDt(),S$()]),c1.deinit(),Ti.deinit(),wMt=!0,zm.quit()}',
  ],
};
const digest = (value) => crypto.createHash("sha256").update(value).digest("hex");

function writeSyntheticArchive(asarPath, version, markers = fixtures[version]) {
  const source = Buffer.from("const before=1;" + markers.join("") + "const after=2;");
  const packageBytes = Buffer.from(JSON.stringify({ version, main: "minified/main.js" }));
  const header = { files: {
    "package.json": { size: packageBytes.length, offset: String(source.length) },
    minified: { files: { "main.js": {
      size: source.length,
      offset: "0",
      integrity: {
        algorithm: "SHA256", hash: digest(source), blockSize: 16,
        blocks: Array.from({ length: Math.ceil(source.length / 16) }, (_, index) =>
          digest(source.subarray(index * 16, Math.min((index + 1) * 16, source.length))))
      },
    } } },
  } };
  const json = Buffer.from(JSON.stringify(header));
  const headerSize = 8 + Math.ceil(json.length / 4) * 4;
  const sizePickle = Buffer.alloc(8);
  sizePickle.writeUInt32LE(4, 0);
  sizePickle.writeUInt32LE(headerSize, 4);
  const headerPickle = Buffer.alloc(headerSize);
  headerPickle.writeUInt32LE(headerSize - 4, 0);
  headerPickle.writeUInt32LE(json.length, 4);
  json.copy(headerPickle, 8);
  fs.writeFileSync(asarPath, Buffer.concat([sizePickle, headerPickle, source, packageBytes]));
}

function run(patcher, command, asarPath, expectedStatus) {
  const result = spawnSync(process.execPath, [patcher, command, asarPath], { encoding: "utf8" });
  assert.equal(result.status, expectedStatus, result.stderr || result.stdout);
  return result;
}

function verifyIntegrity(asarPath) {
  const bytes = fs.readFileSync(asarPath);
  const headerSize = bytes.readUInt32LE(4);
  const jsonSize = bytes.readUInt32LE(12);
  const header = JSON.parse(bytes.subarray(16, 16 + jsonSize));
  const entry = header.files.minified.files["main.js"];
  const source = bytes.subarray(8 + headerSize + Number(entry.offset), 8 + headerSize + Number(entry.offset) + entry.size);
  assert.equal(entry.integrity.hash, digest(source));
  for (const [index, hash] of entry.integrity.blocks.entries()) {
    assert.equal(hash, digest(source.subarray(index * 16, Math.min((index + 1) * 16, source.length))));
  }
}

function verifyCleanupWiring(state, version) {
  const names = version === "3.0.0"
    ? ["bxe", "VP", "nJ", "CTe", "jDt", "I$"]
    : ["vxe", "ZP", "oJ", "MTe", "CDt", "S$"];
  const cleanupName = version === "3.0.0" ? "vMt" : "TMt";
  const appName = version === "3.0.0" ? "xm" : "zm";
  const calls = [];
  const context = { global: { __nhaQuit: (parallel, final) => {
    assert.deepEqual(Array.from(parallel), names.map(name => context[name]));
    assert.deepEqual(Array.from(final), [context[version === "3.0.0" ? "s1" : "c1"].deinit, context.Ti.deinit]);
    calls.push("cleanup");
    return true;
  } }, yMt: false, wMt: false, Q$: false, U$: false,
  Wr: { isDestroyed: () => false, hide: () => calls.push("hide"), webContents: { send: () => calls.push("signal") } },
  Ti: { deinit: () => {} }, s1: { deinit: () => {} }, c1: { deinit: () => {} },
  };
  for (const name of names) context[name] = () => {};
  let handler;
  context[appName] = { on: (event, fn) => { assert.equal(event, "before-quit"); handler = fn; },
    exit: () => { throw new Error("Unexpected immediate exit"); } };
  vm.createContext(context);
  vm.runInContext(state.patches.find(patch => patch.name === "cleanup").replacement, context);
  assert.equal(typeof context[cleanupName], "function");
  vm.runInContext(state.patches.find(patch => patch.name === "beforeQuit").replacement, context);
  handler({ preventDefault: () => calls.push("prevent") });
  assert.deepEqual(calls, ["prevent", "cleanup", "hide", "signal"]);
}

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "nha-public-test-"));
try {
  const patcher = path.join(temporaryRoot, "asar-patch.cjs");
  const asarPath = path.join(temporaryRoot, "app.asar");
  const statePath = path.join(temporaryRoot, "patch-state.json");
  const readState = () => JSON.parse(fs.readFileSync(statePath, "utf8"));
  fs.copyFileSync(path.resolve(__dirname, "..", "asar-patch.cjs"), patcher);

  for (const version of Object.keys(fixtures)) {
    writeSyntheticArchive(asarPath, version);
    const officialBytes = fs.readFileSync(asarPath);
    run(patcher, "check", asarPath, 2);
    run(patcher, "patch", asarPath, 0);
    verifyIntegrity(asarPath);
    run(patcher, "check", asarPath, 0);
    const state = readState();
    assert.equal(state.desktopVersion, version);
    assert.equal(state.pluginVersion, "1.1.5");
    assert.equal(state.beforeHash, digest(officialBytes));
    assert.equal(state.appliedPatches.length, 3);
    verifyCleanupWiring(state, version);
    const patchedHash = digest(fs.readFileSync(asarPath));
    run(patcher, "patch", asarPath, 0);
    assert.equal(digest(fs.readFileSync(asarPath)), patchedHash);
    run(patcher, "restore", asarPath, 0);
    assert.deepEqual(fs.readFileSync(asarPath), officialBytes);
    console.log(`${version}: check, patch, integrity, cleanup wiring, idempotence and restore passed.`);
  }

  // A pre-1.1.4 cleanup patch on Desktop 3.0.0 retains its original backup.
  writeSyntheticArchive(asarPath, "3.0.0");
  run(patcher, "patch", asarPath, 0);
  const oldState = readState();
  const legacyCleanup = 'function vMt(){global.__nhaQuit?.([bxe,VP,nJ,CTe,jDt,I$],()=>{s1.deinit();Ti.deinit();yMt=1;xm.exit()})||xm.exit()}';
  const legacyMarkers = oldState.patches.map(patch => patch.name === "cleanup"
    ? legacyCleanup.padEnd(patch.target.length, " ") : patch.replacement.padEnd(patch.target.length, " "));
  writeSyntheticArchive(asarPath, "3.0.0", legacyMarkers);
  run(patcher, "check", asarPath, 4);
  run(patcher, "patch", asarPath, 0);
  assert.equal(readState().backupPath, oldState.backupPath);
  verifyIntegrity(asarPath);
  console.log("Legacy 3.0.0 plugin upgrade passed.");

  // Official update replaces the archive while the previous patch-state remains.
  const sentinelConfig = Buffer.from('{"token":"TEST_ONLY_TOKEN","devices":{}}');
  fs.writeFileSync(path.join(temporaryRoot, "config.json"), sentinelConfig);
  writeSyntheticArchive(asarPath, "3.0.1");
  const newOfficialBytes = fs.readFileSync(asarPath);
  run(patcher, "patch", asarPath, 0);
  const newState = readState();
  assert.notEqual(newState.backupPath, oldState.backupPath);
  assert.equal(newState.beforeHash, digest(newOfficialBytes));
  assert.deepEqual(fs.readFileSync(path.join(temporaryRoot, "config.json")), sentinelConfig);
  const patched301 = fs.readFileSync(asarPath);

  fs.writeFileSync(statePath, JSON.stringify({ ...newState, backupPath: oldState.backupPath, beforeHash: oldState.beforeHash }));
  run(patcher, "restore", asarPath, 1);
  assert.deepEqual(fs.readFileSync(asarPath), patched301);
  fs.writeFileSync(statePath, JSON.stringify({ ...newState, beforeHash: "0".repeat(64) }));
  run(patcher, "restore", asarPath, 1);
  assert.deepEqual(fs.readFileSync(asarPath), patched301);
  fs.writeFileSync(statePath, JSON.stringify(newState));
  run(patcher, "restore", asarPath, 0);
  assert.deepEqual(fs.readFileSync(asarPath), newOfficialBytes);
  console.log("3.0.0 -> 3.0.1 official update and backup/version/hash guards passed.");

  for (const markers of [fixtures["3.0.1"].slice(1), [...fixtures["3.0.1"], fixtures["3.0.1"][0]]]) {
    writeSyntheticArchive(asarPath, "3.0.1", markers);
    const bytes = fs.readFileSync(asarPath);
    run(patcher, "check", asarPath, 3);
    run(patcher, "patch", asarPath, 1);
    assert.deepEqual(fs.readFileSync(asarPath), bytes);
  }
  writeSyntheticArchive(asarPath, "3.0.2", fixtures["3.0.1"]);
  const unknownBytes = fs.readFileSync(asarPath);
  run(patcher, "patch", asarPath, 1);
  assert.deepEqual(fs.readFileSync(asarPath), unknownBytes);
  console.log("Missing/duplicate markers and unknown versions rejected without archive writes.");
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
