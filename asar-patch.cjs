"use strict";

// Electron patches Node's fs module so paths ending in .asar are treated as
// virtual directories. The patcher needs the raw archive bytes instead.
process.noAsar = true;

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

function paddedReplacement(target, replacement) {
  const remaining = Buffer.byteLength(target) - Buffer.byteLength(replacement);
  if (remaining < 0) {
    throw new Error(`Replacement is longer than its target (${replacement})`);
  }
  return replacement + " ".repeat(remaining);
}

const ENTRY_TARGET = 'console.log("Running app version",ut.pkg.version);';
const ENTRY_REPLACEMENT = paddedReplacement(
  ENTRY_TARGET,
  'import("file:///C:/ProgramData/NHA/m.mjs");'
);
const CLEANUP_TARGET =
  'async function vMt(){bxe(),await Promise.all([VP(),nJ(),CTe(),jDt(),I$()]),s1.deinit(),Ti.deinit(),yMt=!0,xm.quit()}';
const CLEANUP_REPLACEMENT = paddedReplacement(
  CLEANUP_TARGET,
  'function vMt(){global.__nhaQuit?.([bxe,VP,nJ,CTe,jDt,I$],[s1.deinit,Ti.deinit])||xm.exit()}'
);
const CLEANUP_REPLACEMENT_1_1_2 = paddedReplacement(
  CLEANUP_TARGET,
  'function vMt(){global.__nhaQuit?.([bxe,VP,nJ,CTe,jDt,I$],()=>{s1.deinit();Ti.deinit();yMt=1;xm.exit()})||xm.exit()}'
);
const CLEANUP_REPLACEMENT_1_1_1 = paddedReplacement(
  CLEANUP_TARGET,
  'function vMt(){global.__nhaQuit?.([bxe,VP,nJ,CTe,jDt,I$],()=>{s1.deinit();Ti.deinit();yMt=1;xm.quit()})||xm.exit()}'
);
const CLEANUP_REPLACEMENT_1_1_0 = paddedReplacement(
  CLEANUP_TARGET,
  'async function vMt(){return global.__nhaQuit?.([bxe,VP,nJ,CTe,jDt,I$],()=>{yMt=!0,xm.quit()})??(yMt=!0,xm.quit())}'
);
const BEFORE_QUIT_TARGET =
  'xm.on("before-quit",async t=>{yMt||(t.preventDefault(),Q$=!0,Wr&&!Wr.isDestroyed()?(xm.dock?.hide(),Wr.hide(),Wr.webContents.send("cleanup")):vMt())});';
const BEFORE_QUIT_REPLACEMENT = paddedReplacement(
  BEFORE_QUIT_TARGET,
  'xm.on("before-quit",t=>{yMt||(t.preventDefault(),Q$=!0,vMt(),Wr&&!Wr.isDestroyed()&&(xm.dock?.hide(),Wr.hide(),Wr.webContents.send("cleanup")))});'
);
const BEFORE_QUIT_REPLACEMENT_1_1_0 = paddedReplacement(
  BEFORE_QUIT_TARGET,
  'xm.on("before-quit",t=>{yMt||(t.preventDefault(),Q$=!0,Wr&&!Wr.isDestroyed()&&(xm.dock?.hide(),Wr.hide(),Wr.webContents.send("cleanup")),vMt())});'
);

const PATCHES = Object.freeze([
  Object.freeze({
    name: "entry",
    target: ENTRY_TARGET,
    replacement: ENTRY_REPLACEMENT,
    legacyReplacements: Object.freeze([]),
  }),
  Object.freeze({
    name: "cleanup",
    target: CLEANUP_TARGET,
    replacement: CLEANUP_REPLACEMENT,
    legacyReplacements: Object.freeze([
      CLEANUP_REPLACEMENT_1_1_2,
      CLEANUP_REPLACEMENT_1_1_1,
      CLEANUP_REPLACEMENT_1_1_0,
    ]),
  }),
  Object.freeze({
    name: "beforeQuit",
    target: BEFORE_QUIT_TARGET,
    replacement: BEFORE_QUIT_REPLACEMENT,
    legacyReplacements: Object.freeze([BEFORE_QUIT_REPLACEMENT_1_1_0]),
  }),
]);

function fail(message, code = 1) {
  console.error(`[NHA] ${message}`);
  process.exitCode = code;
}

function countOccurrences(buffer, needle) {
  let count = 0;
  let cursor = 0;
  while ((cursor = buffer.indexOf(needle, cursor)) !== -1) {
    count += 1;
    cursor += needle.length;
  }
  return count;
}

function sha256(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function preserveHexCase(previous, next) {
  if (typeof previous === "string" && previous === previous.toUpperCase()) {
    return next.toUpperCase();
  }
  return next;
}

function updateIntegrity(entry, content) {
  const integrity = entry.integrity;
  if (!integrity) {
    return;
  }
  if (String(integrity.algorithm || "SHA256").toUpperCase() !== "SHA256") {
    throw new Error(`Unsupported ASAR integrity algorithm: ${integrity.algorithm}`);
  }

  integrity.hash = preserveHexCase(integrity.hash, sha256(content));
  if (Array.isArray(integrity.blocks) && Number(integrity.blockSize) > 0) {
    const hashes = [];
    const blockSize = Number(integrity.blockSize);
    for (let offset = 0; offset < content.length; offset += blockSize) {
      hashes.push(sha256(content.subarray(offset, Math.min(offset + blockSize, content.length))));
    }
    const uppercase = integrity.blocks[0] && integrity.blocks[0] === integrity.blocks[0].toUpperCase();
    integrity.blocks = uppercase ? hashes.map((hash) => hash.toUpperCase()) : hashes;
  }
}

function readArchive(asarPath) {
  const descriptor = fs.openSync(asarPath, "r");
  try {
    const sizePickle = Buffer.alloc(8);
    if (fs.readSync(descriptor, sizePickle, 0, 8, 0) !== 8) {
      throw new Error("ASAR header is truncated");
    }
    const payloadSize = sizePickle.readUInt32LE(0);
    const headerSize = sizePickle.readUInt32LE(4);
    if (payloadSize !== 4 || headerSize < 12 || headerSize > 128 * 1024 * 1024) {
      throw new Error("ASAR header size is invalid");
    }

    const headerPickle = Buffer.alloc(headerSize);
    if (fs.readSync(descriptor, headerPickle, 0, headerSize, 8) !== headerSize) {
      throw new Error("ASAR metadata is truncated");
    }
    const picklePayloadSize = headerPickle.readUInt32LE(0);
    const jsonSize = headerPickle.readUInt32LE(4);
    if (picklePayloadSize + 4 !== headerSize || jsonSize <= 0 || jsonSize > headerSize - 8) {
      throw new Error("ASAR metadata pickle is invalid");
    }

    const jsonBuffer = headerPickle.subarray(8, 8 + jsonSize);
    const jsonText = jsonBuffer.toString("utf8");
    const header = JSON.parse(jsonText);
    const entry = header?.files?.minified?.files?.["main.js"];
    if (!entry || entry.unpacked || entry.offset === undefined || !Number.isFinite(Number(entry.size))) {
      throw new Error("minified/main.js was not found inside app.asar");
    }

    const contentOffset = 8 + headerSize + Number(entry.offset);
    const content = Buffer.alloc(Number(entry.size));
    if (fs.readSync(descriptor, content, 0, content.length, contentOffset) !== content.length) {
      throw new Error("minified/main.js is truncated");
    }
    return {
      header,
      entry,
      jsonSize,
      jsonText,
      contentOffset,
      content,
    };
  } finally {
    fs.closeSync(descriptor);
  }
}

function inspectArchive(asarPath) {
  const archive = readArchive(asarPath);
  const patches = Object.fromEntries(PATCHES.map((patch) => [
    patch.name,
    {
      ...patch,
      targetCount: countOccurrences(archive.content, Buffer.from(patch.target, "utf8")),
      replacementCount: countOccurrences(
        archive.content,
        Buffer.from(patch.replacement, "utf8")
      ),
      legacyCounts: patch.legacyReplacements.map((replacement) =>
        countOccurrences(archive.content, Buffer.from(replacement, "utf8"))
      ),
    },
  ]));
  return {
    ...archive,
    patches,
  };
}

function legacyCount(patch) {
  return patch.legacyCounts.reduce((total, count) => total + count, 0);
}

function markerCount(patch) {
  return patch.targetCount + patch.replacementCount + legacyCount(patch);
}

function isCurrentPatch(patch) {
  return patch.replacementCount === 1 && patch.targetCount === 0 && legacyCount(patch) === 0;
}

function isOfficialPatch(patch) {
  return patch.targetCount === 1 && patch.replacementCount === 0 && legacyCount(patch) === 0;
}

function isRecognizedPatch(patch) {
  return markerCount(patch) === 1;
}

function writeState(pluginDir, value) {
  const statePath = path.join(pluginDir, "patch-state.json");
  const temporaryPath = `${statePath}.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  fs.renameSync(temporaryPath, statePath);
}

function readState(pluginDir) {
  const statePath = path.join(pluginDir, "patch-state.json");
  if (!fs.existsSync(statePath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(statePath, "utf8").replace(/^\uFEFF/, ""));
}

function check(asarPath) {
  const archive = inspectArchive(asarPath);
  const states = Object.values(archive.patches);
  if (states.every(isCurrentPatch)) {
    console.log("[NHA] Embedded plugin 1.1.4 and compatible self-termination hooks are active.");
    return 0;
  }
  if (states.every(isOfficialPatch)) {
    console.log("[NHA] Official app.asar is compatible and not patched.");
    return 2;
  }
  if (states.every(isRecognizedPatch)) {
    console.log("[NHA] A compatible previous plugin patch is active; 1.1.4 upgrade is available.");
    return 4;
  }
  console.error(
    `[NHA] Incompatible app.asar markers: ${JSON.stringify(states.map((patch) => ({
      name: patch.name,
      official: patch.targetCount,
      patched: patch.replacementCount,
      legacy: legacyCount(patch),
    })))}.`
  );
  return 3;
}

function patchArchive(asarPath, pluginDir) {
  for (const patch of PATCHES) {
    if (Buffer.byteLength(patch.target) !== Buffer.byteLength(patch.replacement)) {
      throw new Error(`Internal patch length mismatch: ${patch.name}`);
    }
    for (const legacyReplacement of patch.legacyReplacements) {
      if (Buffer.byteLength(patch.target) !== Buffer.byteLength(legacyReplacement)) {
        throw new Error(`Legacy patch length mismatch: ${patch.name}`);
      }
    }
  }

  const archive = inspectArchive(asarPath);
  const states = Object.values(archive.patches);
  if (states.every(isCurrentPatch)) {
    console.log("[NHA] app.asar is already patched.");
    return;
  }
  for (const patch of states) {
    if (!isRecognizedPatch(patch)) {
      throw new Error(
        `This Nanoleaf version is incompatible (${patch.name}: official=${patch.targetCount}, patched=${patch.replacementCount}, legacy=${legacyCount(patch)})`
      );
    }
  }

  const previousState = readState(pluginDir);
  let backupPath;
  let beforeHash;
  if (!isOfficialPatch(archive.patches.entry)) {
    backupPath = previousState?.backupPath;
    if (!backupPath || !fs.existsSync(backupPath)) {
      throw new Error(
        "The existing plugin patch has no official backup; restore the previous backup before upgrading"
      );
    }
    const backupArchive = inspectArchive(backupPath);
    const backupStates = Object.values(backupArchive.patches);
    if (!backupStates.every(isOfficialPatch)) {
      throw new Error("The recorded app.asar backup is not an unmodified compatible archive");
    }
    beforeHash = sha256(fs.readFileSync(backupPath));
    if (previousState.beforeHash && previousState.beforeHash !== beforeHash) {
      throw new Error("The official app.asar backup hash does not match patch-state.json");
    }
  } else {
    const backupDir = path.join(pluginDir, "backups");
    fs.mkdirSync(backupDir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    backupPath = path.join(backupDir, `app.asar.${stamp}.official.bak`);
    fs.copyFileSync(asarPath, backupPath, fs.constants.COPYFILE_EXCL);
    beforeHash = sha256(fs.readFileSync(asarPath));
  }

  const currentBeforeHash = sha256(fs.readFileSync(asarPath));
  const nextContent = Buffer.from(archive.content);
  const appliedPatches = [];
  for (const patch of states) {
    if (isCurrentPatch(patch)) {
      continue;
    }
    const activeMarker = patch.targetCount === 1
      ? patch.target
      : patch.legacyReplacements[patch.legacyCounts.findIndex((count) => count === 1)];
    const targetOffset = nextContent.indexOf(Buffer.from(activeMarker, "utf8"));
    if (targetOffset < 0) {
      throw new Error(`Could not locate patch target: ${patch.name}`);
    }
    nextContent.write(
      patch.replacement,
      targetOffset,
      Buffer.byteLength(patch.replacement),
      "utf8"
    );
    appliedPatches.push(patch.name);
  }
  updateIntegrity(archive.entry, nextContent);

  const nextJson = JSON.stringify(archive.header);
  if (Buffer.byteLength(nextJson) !== archive.jsonSize) {
    throw new Error(
      `ASAR metadata length changed (${archive.jsonSize} -> ${Buffer.byteLength(nextJson)})`
    );
  }

  try {
    const descriptor = fs.openSync(asarPath, "r+");
    try {
      fs.writeSync(descriptor, nextContent, 0, nextContent.length, archive.contentOffset);
      fs.writeSync(descriptor, Buffer.from(nextJson), 0, archive.jsonSize, 16);
      fs.fsyncSync(descriptor);
    } finally {
      fs.closeSync(descriptor);
    }

    const verified = inspectArchive(asarPath);
    if (!Object.values(verified.patches).every(isCurrentPatch)) {
      throw new Error("Patched archive failed verification");
    }
    const afterHash = sha256(fs.readFileSync(asarPath));
    writeState(pluginDir, {
      ...previousState,
      active: true,
      patchedAt: new Date().toISOString(),
      asarPath,
      backupPath,
      beforeHash,
      currentBeforeHash,
      afterHash,
      appliedPatches,
      patches: PATCHES.map((patch) => ({
        name: patch.name,
        target: patch.target,
        replacement: patch.replacement.trimEnd(),
        legacyReplacements: patch.legacyReplacements.map((replacement) =>
          replacement.trimEnd()
        ),
      })),
    });
    console.log(`[NHA] Patched: ${asarPath}`);
    console.log(`[NHA] Backup:  ${backupPath}`);
  } catch (error) {
    fs.copyFileSync(backupPath, asarPath);
    throw error;
  }
}

function restoreArchive(asarPath, pluginDir) {
  const state = readState(pluginDir);
  if (!state?.backupPath || !fs.existsSync(state.backupPath)) {
    throw new Error("No official app.asar backup is available");
  }

  const archive = inspectArchive(asarPath);
  const states = Object.values(archive.patches);
  if (states.every(isOfficialPatch)) {
    writeState(pluginDir, {
      ...state,
      active: false,
      restoredAt: new Date().toISOString(),
      note: "Current archive was already official; no backup was copied.",
    });
    console.log("[NHA] Current app.asar is already official; nothing was overwritten.");
    return;
  }
  if (!states.every(isRecognizedPatch)) {
    throw new Error("Current app.asar is not a recognized plugin-patched archive");
  }

  fs.copyFileSync(state.backupPath, asarPath);
  const restoredHash = sha256(fs.readFileSync(asarPath));
  if (state.beforeHash && restoredHash !== state.beforeHash) {
    throw new Error("Restored app.asar hash does not match the official backup hash");
  }
  const restored = inspectArchive(asarPath);
  if (!Object.values(restored.patches).every(isOfficialPatch)) {
    throw new Error("Restored app.asar does not contain the expected official markers");
  }
  writeState(pluginDir, {
    ...state,
    active: false,
    restoredAt: new Date().toISOString(),
    restoredHash,
  });
  console.log(`[NHA] Restored official app.asar from: ${state.backupPath}`);
}

function main() {
  const command = String(process.argv[2] || "check").toLowerCase();
  const asarPath = path.resolve(process.argv[3] || "");
  const pluginDir = path.dirname(__filename);
  if (!asarPath || !fs.existsSync(asarPath)) {
    fail(`app.asar not found: ${asarPath || "(missing argument)"}`);
    return;
  }

  try {
    if (command === "check") {
      process.exitCode = check(asarPath);
    } else if (command === "patch") {
      patchArchive(asarPath, pluginDir);
    } else if (command === "restore") {
      restoreArchive(asarPath, pluginDir);
    } else {
      fail("Usage: asar-patch.cjs <check|patch|restore> <path-to-app.asar>");
    }
  } catch (error) {
    fail(error.stack || error.message || String(error));
  }
}

main();
