"use strict";

const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const source = Buffer.from(
  [
    "const before=1;",
    'console.log("Running app version",ut.pkg.version);',
    'xm.on("before-quit",async t=>{yMt||(t.preventDefault(),Q$=!0,Wr&&!Wr.isDestroyed()?(xm.dock?.hide(),Wr.hide(),Wr.webContents.send("cleanup")):vMt())});',
    'async function vMt(){bxe(),await Promise.all([VP(),nJ(),CTe(),jDt(),I$()]),s1.deinit(),Ti.deinit(),yMt=!0,xm.quit()}',
    "const after=2;",
  ].join(""),
  "utf8"
);

const digest = (value) => crypto.createHash("sha256").update(value).digest("hex");

function writeSyntheticArchive(asarPath) {
  const header = {
    files: {
      minified: {
        files: {
          "main.js": {
            size: source.length,
            offset: "0",
            integrity: {
              algorithm: "SHA256",
              hash: digest(source),
              blockSize: 16,
              blocks: Array.from(
                { length: Math.ceil(source.length / 16) },
                (_, index) => digest(source.subarray(
                  index * 16,
                  Math.min((index + 1) * 16, source.length)
                ))
              ),
            },
          },
        },
      },
    },
  };
  const json = Buffer.from(JSON.stringify(header));
  const headerSize = 8 + Math.ceil(json.length / 4) * 4;
  const sizePickle = Buffer.alloc(8);
  sizePickle.writeUInt32LE(4, 0);
  sizePickle.writeUInt32LE(headerSize, 4);
  const headerPickle = Buffer.alloc(headerSize);
  headerPickle.writeUInt32LE(headerSize - 4, 0);
  headerPickle.writeUInt32LE(json.length, 4);
  json.copy(headerPickle, 8);
  fs.writeFileSync(asarPath, Buffer.concat([sizePickle, headerPickle, source]));
}

function run(patcher, command, asarPath, expectedStatus) {
  const result = spawnSync(process.execPath, [patcher, command, asarPath], {
    encoding: "utf8",
  });
  assert.equal(result.status, expectedStatus, result.stderr || result.stdout);
  return result;
}

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "nha-public-test-"));
try {
  const patcher = path.join(temporaryRoot, "asar-patch.cjs");
  const asarPath = path.join(temporaryRoot, "app.asar");
  fs.copyFileSync(path.resolve(__dirname, "..", "asar-patch.cjs"), patcher);
  writeSyntheticArchive(asarPath);
  const officialHash = digest(fs.readFileSync(asarPath));

  run(patcher, "check", asarPath, 2);
  run(patcher, "patch", asarPath, 0);
  const patchedBytes = fs.readFileSync(asarPath);
  assert(patchedBytes.includes(Buffer.from('import("file:///C:/ProgramData/NHA/m.mjs");')));
  assert(patchedBytes.includes(Buffer.from("global.__nhaQuit?.(")));
  assert(patchedBytes.includes(Buffer.from('xm.on("before-quit",t=>')));
  run(patcher, "check", asarPath, 0);

  const state = JSON.parse(fs.readFileSync(path.join(temporaryRoot, "patch-state.json"), "utf8"));
  assert.equal(state.active, true);
  assert.equal(state.beforeHash, officialHash);
  assert.equal(state.appliedPatches.length, 3);

  run(patcher, "restore", asarPath, 0);
  assert.equal(digest(fs.readFileSync(asarPath)), officialHash);
  console.log("Synthetic ASAR check, patch, integrity and restore round trip passed.");
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
