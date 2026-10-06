import { app, BrowserWindow, clipboard, ipcMain, shell } from "electron";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PLUGIN_VERSION = "1.1.7";
const PLUGIN_DIR = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.join(PLUGIN_DIR, "config.json");
const LOG_PATH = path.join(PLUGIN_DIR, "plugin.log");
const PREPARE_UPDATE_PATH = path.join(PLUGIN_DIR, "prepare-update.ps1");
const RENDERER_CLEANUP_GRACE_MS = 300;
const OFFICIAL_CLEANUP_TIMEOUT_MS = 5000;
const INTERNAL_EXIT_FALLBACK_MS = 6800;
const PARALLEL_CLEANUP_NAMES = Object.freeze([
  "dns-sd",
  "hid-devices",
  "kpi-events",
  "ltpdu-connections",
  "device-mqtt",
  "remote-app-mqtt",
]);
const FINAL_CLEANUP_NAMES = Object.freeze([
  "colour-calibration",
  "ltpdu-client-manager",
]);

const DEVICE_KEYS = Object.freeze(["j", "k"]);

function log(...values) {
  const line = `${new Date().toISOString()} ${values.map((value) =>
    typeof value === "string" ? value : JSON.stringify(value)
  ).join(" ")}\n`;
  try {
    if (fs.existsSync(LOG_PATH) && fs.statSync(LOG_PATH).size > 5 * 1024 * 1024) {
      fs.renameSync(LOG_PATH, `${LOG_PATH}.1`);
    }
    fs.appendFileSync(LOG_PATH, line, "utf8");
  } catch {
    // Logging must never affect Nanoleaf Desktop.
  }
}

function createToken() {
  return crypto.randomBytes(32).toString("hex");
}

function localIpv4() {
  const addresses = [];
  try {
    for (const entries of Object.values(os.networkInterfaces())) {
      for (const entry of entries || []) {
        if (entry.family === "IPv4" && !entry.internal && !entry.address.startsWith("169.254.")) {
          addresses.push(entry.address);
        }
      }
    }
  } catch (error) {
    log("local IPv4 discovery failed", error.message);
  }
  return addresses.find((address) => address.startsWith("192.168.")) ||
    addresses.find((address) => /^10\./.test(address)) ||
    addresses.find((address) => {
      const second = Number(address.split(".")[1]);
      return address.startsWith("172.") && second >= 16 && second <= 31;
    }) ||
    addresses[0] || "127.0.0.1";
}

function normalizeDevice(key, value) {
  if (!value || typeof value !== "object") {
    return null;
  }
  const id = String(value.id || "").trim();
  if (!id) {
    return null;
  }
  const port = Number(value.port);
  return {
    id,
    model: String(value.model || "NL82K1").trim() || "NL82K1",
    name: String(value.name || `Nanoleaf Pegboard ${key.toUpperCase()}`).trim() ||
      `Nanoleaf Pegboard ${key.toUpperCase()}`,
    port: Number.isFinite(port) ? port : 0,
  };
}

function normalizeDevices(value) {
  const devices = {};
  for (const key of DEVICE_KEYS) {
    const device = normalizeDevice(key, value?.[key]);
    if (device) {
      devices[key] = device;
    }
  }
  return devices;
}

function defaultConfig() {
  return {
    version: 2,
    enabled: true,
    host: "0.0.0.0",
    port: 17654,
    token: createToken(),
    haIp: "",
    pcIp: localIpv4(),
    autoStart: true,
    devices: {},
  };
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, ""));
}

function loadConfig() {
  const defaults = defaultConfig();
  try {
    const config = readJson(CONFIG_PATH);
    return {
      ...defaults,
      ...config,
      port: Number(config.port || defaults.port),
      token: String(config.token || defaults.token),
      haIp: String(config.haIp || "").trim(),
      pcIp: String(config.pcIp || defaults.pcIp).trim() || defaults.pcIp,
      devices: normalizeDevices(config.devices),
    };
  } catch {
    saveConfig(defaults);
    return defaults;
  }
}

function saveConfig(config) {
  const next = {
    version: 2,
    enabled: config.enabled !== false,
    host: "0.0.0.0",
    port: Number(config.port || 17654),
    token: String(config.token || createToken()),
    haIp: String(config.haIp || "").trim(),
    pcIp: String(config.pcIp || localIpv4()).trim() || localIpv4(),
    autoStart: config.autoStart !== false,
    devices: normalizeDevices(config.devices),
  };
  const temporaryPath = `${CONFIG_PATH}.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(next, null, 2)}\n`, "utf8");
  fs.renameSync(temporaryPath, CONFIG_PATH);
  return next;
}

function selectedDevices(key) {
  const configured = loadConfig().devices;
  if (key === "all") {
    const devices = DEVICE_KEYS.flatMap((deviceKey) =>
      configured[deviceKey] ? [configured[deviceKey]] : []
    );
    if (!devices.length) {
      throw new Error("No Nanoleaf devices are configured");
    }
    return devices;
  }
  if (!DEVICE_KEYS.includes(key)) {
    throw new Error("Unknown device key; use j, k, or all");
  }
  if (!configured[key]) {
    throw new Error(`Device slot ${key.toUpperCase()} is not configured`);
  }
  return [configured[key]];
}

let haWindow = null;

function nanoleafWindows() {
  return BrowserWindow.getAllWindows().filter((window) =>
    !window.isDestroyed() && window !== haWindow
  );
}

function mainNanoleafWindow() {
  const windows = nanoleafWindows();
  return windows.find((window) => {
    const url = window.webContents.getURL();
    return url.startsWith("http://localhost:15765") ||
      url.startsWith("http://localhost:15766");
  }) || windows[0] || null;
}

async function evaluateInNanoleaf(expression) {
  const window = mainNanoleafWindow();
  if (!window || window.isDestroyed() || window.webContents.isLoading()) {
    throw new Error("Nanoleaf renderer is not ready");
  }
  return window.webContents.executeJavaScript(expression, true);
}

function stateExpression(key) {
  const selected = JSON.stringify(selectedDevices(key));
  return `(async () => {
    const devices = ${selected};
    if (!window.electronAPI?.deviceControl?.getState) {
      throw new Error("Nanoleaf deviceControl API is unavailable");
    }
    const raw = await Promise.all(devices.map(device =>
      window.electronAPI.deviceControl.getState(device)
    ));
    const values = raw.map((result, index) => ({
      id: devices[index].id,
      isSuccess: result?.isSuccess === true,
      on: result?.value?.state?.on?.value === true,
      brightness: result?.value?.state?.brightness?.value ?? 0,
      effect: result?.value?.currentEffect ?? null
    }));
    return {
      ok: values.every(value => value.isSuccess),
      key: ${JSON.stringify(key)},
      on: values.every(value => value.on),
      brightness: values.length
        ? Math.round(values.reduce((sum, value) => sum + value.brightness, 0) / values.length)
        : 0,
      effect: values.length === 1 ? values[0].effect : null,
      devices: values
    };
  })()`;
}

function powerExpression(key, on) {
  const selected = JSON.stringify(selectedDevices(key));
  return `(async () => {
    const devices = ${selected};
    if (!window.electronAPI?.deviceControl?.setPower) {
      throw new Error("Nanoleaf deviceControl API is unavailable");
    }
    const changed = await Promise.all(devices.map(device =>
      window.electronAPI.deviceControl.setPower(device, ${on ? "true" : "false"})
    ));
    await new Promise(resolve => setTimeout(resolve, 180));
    const raw = await Promise.all(devices.map(device =>
      window.electronAPI.deviceControl.getState(device)
    ));
    const values = raw.map((result, index) => ({
      id: devices[index].id,
      isSuccess: result?.isSuccess === true,
      on: result?.value?.state?.on?.value === true,
      brightness: result?.value?.state?.brightness?.value ?? 0,
      effect: result?.value?.currentEffect ?? null
    }));
    return {
      ok: changed.every(value => value?.isSuccess === true) &&
        values.every(value => value.isSuccess),
      key: ${JSON.stringify(key)},
      on: values.every(value => value.on),
      brightness: values.length
        ? Math.round(values.reduce((sum, value) => sum + value.brightness, 0) / values.length)
        : 0,
      effect: values.length === 1 ? values[0].effect : null,
      devices: values
    };
  })()`;
}

let operationQueue = Promise.resolve();
function enqueue(operation) {
  const current = operationQueue.then(operation, operation);
  operationQueue = current.catch(() => undefined);
  return current;
}

function readBody(request, limit = 8192) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > limit) {
        reject(new Error("Request body is too large"));
        request.destroy();
      }
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

function sendJson(response, statusCode, value) {
  const body = JSON.stringify(value);
  response.shouldKeepAlive = false;
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Connection": "close",
  });
  response.end(body);
}

let bridgeServer = null;
const bridgeSockets = new Set();
let bridgeStatus = "stopped";
let bridgeError = null;

async function handleBridgeRequest(request, response) {
  const config = loadConfig();
  if (request.headers.authorization !== `Bearer ${config.token}`) {
    sendJson(response, 401, { ok: false, error: "Unauthorized" });
    return;
  }

  const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);

  if (request.method === "GET" && url.pathname === "/health") {
    const window = mainNanoleafWindow();
    sendJson(response, window ? 200 : 503, {
      ok: Boolean(window),
      service: "nanoleaf-ha-embedded-plugin",
      pluginVersion: PLUGIN_VERSION,
      desktopVersion: app.getVersion(),
      transport: "embedded-electron-ipc",
      rendererReady: Boolean(window),
    });
    return;
  }

  const match = /^\/device\/(j|k|all)$/.exec(url.pathname);
  if (!match) {
    sendJson(response, 404, { ok: false, error: "Not found" });
    return;
  }

  const key = match[1];
  if (request.method === "GET") {
    const state = await enqueue(() => evaluateInNanoleaf(stateExpression(key)));
    sendJson(response, state?.ok ? 200 : 503, state);
    return;
  }

  if (request.method === "POST") {
    const rawBody = await readBody(request);
    let payload;
    try {
      payload = JSON.parse(rawBody || "{}");
    } catch {
      sendJson(response, 400, { ok: false, error: "Invalid JSON" });
      return;
    }
    if (typeof payload.on !== "boolean") {
      sendJson(response, 400, { ok: false, error: "Body must contain boolean field: on" });
      return;
    }
    const state = await enqueue(() => evaluateInNanoleaf(powerExpression(key, payload.on)));
    sendJson(response, state?.ok ? 200 : 503, state);
    return;
  }

  response.setHeader("Allow", "GET, POST");
  sendJson(response, 405, { ok: false, error: "Method not allowed" });
}

async function stopBridge() {
  if (!bridgeServer) {
    bridgeStatus = "stopped";
    return;
  }
  const server = bridgeServer;
  bridgeServer = null;
  for (const socket of bridgeSockets) {
    socket.destroy();
  }
  bridgeSockets.clear();
  server.closeAllConnections?.();
  await new Promise((resolve) => server.close(resolve));
  server.unref();
  bridgeStatus = "stopped";
  log("HA bridge stopped");
}

function stopBridgeForAppExit() {
  const server = bridgeServer;
  bridgeServer = null;
  bridgeStatus = "stopped";
  for (const socket of bridgeSockets) {
    socket.destroy();
  }
  bridgeSockets.clear();
  if (server) {
    try {
      server.close();
      server.closeAllConnections?.();
      server.unref();
    } catch (error) {
      log("bridge exit cleanup failed", error.message);
    }
  }
}

let windowScanTimer = null;
let officialCleanupPromise = null;
let exitFallbackTimer = null;

function stopPluginResourcesForExit() {
  stopBridgeForAppExit();
  if (windowScanTimer) {
    clearInterval(windowScanTimer);
    windowScanTimer = null;
  }
  if (haWindow && !haWindow.isDestroyed()) {
    try {
      haWindow.destroy();
    } catch (error) {
      log("HA window exit cleanup failed", error.message);
    }
  }
  haWindow = null;
}

function clearExitFallback() {
  if (exitFallbackTimer) {
    clearTimeout(exitFallbackTimer);
    exitFallbackTimer = null;
  }
}

function terminateNanoleafProcess(reason) {
  clearExitFallback();
  try {
    app.removeAllListeners("before-quit");
    for (const window of BrowserWindow.getAllWindows()) {
      if (!window.isDestroyed()) {
        try {
          window.destroy();
        } catch (error) {
          log("Nanoleaf window destroy failed", error.message);
        }
      }
    }
  } catch (error) {
    log("Nanoleaf pre-exit cleanup failed", error.stack || error.message);
  }
  log("Nanoleaf main process self-termination committed", { reason });
  process.exitCode = 0;
  if (typeof process.reallyExit === "function") {
    process.reallyExit(0);
  }
  process.exit(0);
}

function requestUnblockedAppQuit(reason) {
  log("Nanoleaf internal fallback cleanup started", { reason });
  terminateNanoleafProcess(reason);
}

function scheduleExitFallback() {
  if (exitFallbackTimer) {
    return;
  }
  exitFallbackTimer = setTimeout(() => {
    exitFallbackTimer = null;
    requestUnblockedAppQuit("official-cleanup-timeout");
  }, INTERNAL_EXIT_FALLBACK_MS);
}

function runOfficialCleanupStep(step, name) {
  const startedAt = Date.now();
  return new Promise((resolve) => {
    let settled = false;
    const finish = (status, error = null) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      resolve({
        name,
        status,
        elapsedMs: Date.now() - startedAt,
        error: error ? String(error.message || error) : null,
      });
    };
    const timeout = setTimeout(
      () => finish("timeout"),
      OFFICIAL_CLEANUP_TIMEOUT_MS
    );
    Promise.resolve()
      .then(() => step())
      .then(
        () => finish("completed"),
        (error) => finish("failed", error)
      );
  });
}

function normalizeFinalCleanupSteps(value) {
  if (Array.isArray(value)) {
    return {
      steps: value,
      names: FINAL_CLEANUP_NAMES,
      compatibility: "array",
    };
  }
  if (typeof value === "function") {
    return {
      steps: [],
      names: [],
      compatibility: "legacy-callback-skipped",
    };
  }
  if (value && typeof value[Symbol.iterator] === "function") {
    const steps = Array.from(value).filter((step) => typeof step === "function");
    return {
      steps,
      names: FINAL_CLEANUP_NAMES.slice(0, steps.length),
      compatibility: "iterable",
    };
  }
  return {
    steps: [],
    names: [],
    compatibility: "missing",
  };
}

function runNanoleafOfficialCleanup(parallelSteps, finalSteps = []) {
  if (officialCleanupPromise) {
    return officialCleanupPromise;
  }
  officialCleanupPromise = (async () => {
    try {
      const normalizedFinal = normalizeFinalCleanupSteps(finalSteps);
      stopPluginResourcesForExit();
      scheduleExitFallback();
      log("Nanoleaf internal cleanup started", {
        rendererGraceMs: RENDERER_CLEANUP_GRACE_MS,
        timeoutMs: OFFICIAL_CLEANUP_TIMEOUT_MS,
        fallbackMs: INTERNAL_EXIT_FALLBACK_MS,
        parallelSteps: PARALLEL_CLEANUP_NAMES,
        finalSteps: normalizedFinal.names,
        finalStepCompatibility: normalizedFinal.compatibility,
      });
      if (normalizedFinal.compatibility === "legacy-callback-skipped") {
        log("Legacy final cleanup callback skipped to avoid Electron exit recursion");
      }
      await new Promise((resolve) => setTimeout(resolve, RENDERER_CLEANUP_GRACE_MS));
      const parallelResults = await Promise.all(
        parallelSteps.map((step, index) =>
          runOfficialCleanupStep(
            step,
            PARALLEL_CLEANUP_NAMES[index] || `parallel-step-${index + 1}`
          )
        )
      );
      const finalResults = [];
      for (const [index, step] of normalizedFinal.steps.entries()) {
        const name = normalizedFinal.names[index] || `final-step-${index + 1}`;
        log("Nanoleaf final cleanup step started", { name });
        finalResults.push(await runOfficialCleanupStep(step, name));
      }
      const results = [...parallelResults, ...finalResults];
      log("Nanoleaf internal cleanup completed", { results });
      terminateNanoleafProcess("official-cleanup-completed");
    } catch (error) {
      log("Nanoleaf internal cleanup failed", error.stack || error.message);
      requestUnblockedAppQuit("official-cleanup-failed");
    }
  })();
  return officialCleanupPromise;
}

function beginAppExit() {
  stopPluginResourcesForExit();
  scheduleExitFallback();
  log("Nanoleaf internal cleanup requested", {
    fallbackMs: INTERNAL_EXIT_FALLBACK_MS,
  });
}

function finishAppExit() {
  clearExitFallback();
  stopBridgeForAppExit();
}

async function startBridge() {
  const config = loadConfig();
  if (!config.enabled) {
    await stopBridge();
    return;
  }
  if (bridgeServer?.listening) {
    return;
  }

  bridgeStatus = "starting";
  bridgeError = null;
  const server = http.createServer((request, response) => {
    handleBridgeRequest(request, response).catch((error) => {
      log("bridge request failed", error.stack || error.message);
      if (!response.headersSent) {
        sendJson(response, 503, { ok: false, error: error.message });
      } else {
        response.end();
      }
    });
  });

  server.on("error", (error) => {
    bridgeStatus = "error";
    bridgeError = error.message;
    log("bridge server error", error.stack || error.message);
  });

  server.on("connection", (socket) => {
    bridgeSockets.add(socket);
    socket.unref();
    socket.once("close", () => bridgeSockets.delete(socket));
  });

  await new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(config.port, config.host);
  });

  bridgeServer = server;
  server.unref();
  bridgeStatus = "running";
  log(`HA bridge listening on ${config.host}:${config.port}`);
}

async function restartBridge() {
  await stopBridge();
  await startBridge();
}

function maskedToken(token) {
  if (!token || token.length < 16) {
    return "未生成";
  }
  return `${token.slice(0, 8)}••••••••${token.slice(-8)}`;
}

function yamlQuoted(value) {
  return JSON.stringify(String(value));
}

function restSwitchYaml(config, key) {
  const label = key === "all" ? "All" : key.toUpperCase();
  const resource = `http://${config.pcIp}:${config.port}/device/${key}`;
  return `  - platform: rest
    name: Nanoleaf Pegboard ${label} Internal
    resource: ${resource}
    state_resource: ${resource}
    method: post
    body_on: '{"on":true}'
    body_off: '{"on":false}'
    is_on_template: "{{ value_json.on }}"
    headers:
      Authorization: "Bearer ${config.token}"
      Content-Type: "application/json"
    timeout: 10`;
}

function templateLightYaml(key, name) {
  return `      - name: ${yamlQuoted(name)}
        unique_id: nanoleaf_pegboard_${key}_light
        state: "{{ is_state('switch.nanoleaf_pegboard_${key}_internal', 'on') }}"
        turn_on:
          - action: switch.turn_on
            target:
              entity_id: switch.nanoleaf_pegboard_${key}_internal
        turn_off:
          - action: switch.turn_off
            target:
              entity_id: switch.nanoleaf_pegboard_${key}_internal`;
}

function yamlConfig() {
  const config = loadConfig();
  const deviceKeys = DEVICE_KEYS.filter((key) => config.devices[key]);
  if (!deviceKeys.length) {
    throw new Error("No Nanoleaf devices are configured");
  }
  const keys = [...deviceKeys, "all"];
  const names = Object.fromEntries(deviceKeys.map((key) => [key, config.devices[key].name]));
  names.all = "桌面灯板全部";
  return [
    `# Nanoleaf HA Embedded Plugin ${PLUGIN_VERSION}`,
    "switch:",
    keys.map((key) => restSwitchYaml(config, key)).join("\n\n"),
    "",
    "template:",
    "  - light:",
    keys.map((key) => templateLightYaml(key, names[key])).join("\n\n"),
    "",
  ].join("\n");
}

function publicStatus() {
  const config = loadConfig();
  return {
    pluginVersion: PLUGIN_VERSION,
    desktopVersion: app.getVersion(),
    enabled: config.enabled,
    autoStart: config.autoStart,
    haIp: config.haIp,
    pcIp: config.pcIp,
    port: config.port,
    endpoint: `http://${config.pcIp}:${config.port}`,
    tokenMasked: maskedToken(config.token),
    devices: DEVICE_KEYS.flatMap((key) =>
      config.devices[key] ? [{ key, ...config.devices[key] }] : []
    ),
    bridgeStatus,
    bridgeError,
    rendererReady: Boolean(mainNanoleafWindow()),
  };
}

function registerHandler(channel, handler) {
  try {
    ipcMain.removeHandler(channel);
  } catch {
    // No previous handler.
  }
  ipcMain.handle(channel, handler);
}

function applyAutoStart(enabled) {
  app.setLoginItemSettings({
    openAtLogin: Boolean(enabled),
    path: path.join(process.env.SystemRoot || "C:\\Windows", "System32", "wscript.exe"),
    args: ["//B", "//Nologo", path.join(PLUGIN_DIR, "startup.vbs"), "--hidden"],
  });
}

function installIpcHandlers() {
  ipcMain.removeAllListeners("nanoleaf-ha:open");
  ipcMain.on("nanoleaf-ha:open", () => openHaWindow());

  registerHandler("nanoleaf-ha:get-status", () => publicStatus());
  registerHandler("nanoleaf-ha:get-device", (_event, key) =>
    enqueue(() => evaluateInNanoleaf(stateExpression(key)))
  );
  registerHandler("nanoleaf-ha:set-power", (_event, key, on) =>
    enqueue(() => evaluateInNanoleaf(powerExpression(key, Boolean(on))))
  );
  registerHandler("nanoleaf-ha:set-enabled", async (_event, enabled) => {
    const config = loadConfig();
    config.enabled = Boolean(enabled);
    saveConfig(config);
    await restartBridge();
    return publicStatus();
  });
  registerHandler("nanoleaf-ha:set-autostart", (_event, enabled) => {
    const value = Boolean(enabled);
    const config = loadConfig();
    config.autoStart = value;
    saveConfig(config);
    applyAutoStart(value);
    return publicStatus();
  });
  registerHandler("nanoleaf-ha:copy-yaml", () => {
    clipboard.writeText(yamlConfig());
    return true;
  });
  registerHandler("nanoleaf-ha:copy-token", () => {
    clipboard.writeText(loadConfig().token);
    return true;
  });
  registerHandler("nanoleaf-ha:regenerate-token", async () => {
    const config = loadConfig();
    config.token = createToken();
    saveConfig(config);
    await restartBridge();
    return publicStatus();
  });
  registerHandler("nanoleaf-ha:open-folder", async () => shell.openPath(PLUGIN_DIR));
  registerHandler("nanoleaf-ha:prepare-update", () => {
    const escaped = PREPARE_UPDATE_PATH.replace(/'/g, "''");
    const command = `Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "${escaped}"'`;
    const process = spawn(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
      { detached: true, windowsHide: true, stdio: "ignore" }
    );
    process.unref();
    return true;
  });
}

const BUTTON_SCRIPT = `(() => {
  const id = "nanoleaf-ha-plugin-button";
  if (document.getElementById(id) || !document.body) return;
  const button = document.createElement("button");
  button.id = id;
  button.type = "button";
  button.textContent = "HA";
  button.title = "Home Assistant 接入";
  button.setAttribute("aria-label", "打开 Home Assistant 接入窗口");
  Object.assign(button.style, {
    position: "fixed",
    left: "14px",
    bottom: "14px",
    zIndex: "2147483647",
    width: "44px",
    height: "44px",
    border: "1px solid rgba(255,255,255,.18)",
    borderRadius: "14px",
    color: "#fff",
    background: "linear-gradient(145deg,#39a6ff,#1768d4)",
    boxShadow: "0 10px 26px rgba(0,86,190,.38)",
    fontFamily: "Segoe UI,Microsoft YaHei,sans-serif",
    fontSize: "14px",
    fontWeight: "700",
    letterSpacing: ".4px",
    cursor: "pointer",
    backdropFilter: "blur(12px)",
  });
  button.addEventListener("mouseenter", () => button.style.transform = "translateY(-2px)");
  button.addEventListener("mouseleave", () => button.style.transform = "translateY(0)");
  button.addEventListener("click", () => {
    window.electronAPI?.sendToMain?.("nanoleaf-ha:open");
  });
  document.body.appendChild(button);
})()`;

async function injectButton(window) {
  if (!window || window.isDestroyed()) {
    return;
  }
  try {
    await window.webContents.executeJavaScript(BUTTON_SCRIPT, true);
  } catch (error) {
    log("button injection failed", error.message);
  }
}

const attachedWindows = new WeakSet();
function attachMainWindow(window) {
  if (!window || window === haWindow || attachedWindows.has(window)) {
    return;
  }
  attachedWindows.add(window);
  window.webContents.on("dom-ready", () => {
    setTimeout(() => injectButton(window), 1200);
  });
  if (!window.webContents.isLoading()) {
    setTimeout(() => injectButton(window), 500);
  }
}

function openHaWindow() {
  if (haWindow && !haWindow.isDestroyed()) {
    haWindow.show();
    haWindow.focus();
    return;
  }

  const parent = mainNanoleafWindow();
  haWindow = new BrowserWindow({
    width: 820,
    height: 700,
    minWidth: 720,
    minHeight: 600,
    title: "Home Assistant 接入",
    parent: parent || undefined,
    modal: false,
    show: false,
    backgroundColor: "#101318",
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(PLUGIN_DIR, "ha-preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  haWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) {
      shell.openExternal(url);
    }
    return { action: "deny" };
  });
  haWindow.once("ready-to-show", () => haWindow?.show());
  haWindow.on("closed", () => {
    haWindow = null;
  });
  haWindow.loadFile(path.join(PLUGIN_DIR, "ha-window.html"));
}

async function initialize() {
  try {
    const config = loadConfig();
    installIpcHandlers();

    applyAutoStart(config.autoStart);

    await startBridge();
    for (const window of nanoleafWindows()) {
      attachMainWindow(window);
    }
    windowScanTimer = setInterval(() => {
      for (const window of nanoleafWindows()) {
        attachMainWindow(window);
      }
    }, 1500).unref?.();
    log("Nanoleaf HA embedded plugin initialized", {
      pluginVersion: PLUGIN_VERSION,
      desktopVersion: app.getVersion(),
    });
  } catch (error) {
    log("plugin initialization failed", error.stack || error.message);
  }
}

globalThis.__nhaQuit = runNanoleafOfficialCleanup;

if (!globalThis.__nanoleafHaEmbeddedPluginLoaded) {
  globalThis.__nanoleafHaEmbeddedPluginLoaded = true;
  app.once("before-quit", beginAppExit);
  app.once("will-quit", finishAppExit);
  app.whenReady().then(initialize).catch((error) => {
    log("app readiness failed", error.stack || error.message);
  });
}
