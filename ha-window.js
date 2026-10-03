const api = window.nanoleafHA;
const elements = {
  bridgeBadge: document.getElementById("bridgeBadge"),
  pcIp: document.getElementById("pcIp"),
  haIp: document.getElementById("haIp"),
  port: document.getElementById("port"),
  versions: document.getElementById("versions"),
  enabledToggle: document.getElementById("enabledToggle"),
  autoStartToggle: document.getElementById("autoStartToggle"),
  tokenMasked: document.getElementById("tokenMasked"),
  refreshButton: document.getElementById("refreshButton"),
  copyTokenButton: document.getElementById("copyTokenButton"),
  regenerateTokenButton: document.getElementById("regenerateTokenButton"),
  copyYamlButton: document.getElementById("copyYamlButton"),
  openFolderButton: document.getElementById("openFolderButton"),
  prepareUpdateButton: document.getElementById("prepareUpdateButton"),
  toast: document.getElementById("toast"),
};

let toastTimer;
let configuredKeys = [];
function toast(message, isError = false) {
  clearTimeout(toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.toggle("error", isError);
  elements.toast.classList.add("show");
  toastTimer = setTimeout(() => elements.toast.classList.remove("show"), 2600);
}

function applyStatus(status) {
  elements.pcIp.textContent = status.pcIp;
  elements.haIp.textContent = status.haIp;
  elements.port.textContent = String(status.port);
  elements.versions.textContent = `${status.desktopVersion} / ${status.pluginVersion}`;
  elements.enabledToggle.checked = Boolean(status.enabled);
  elements.autoStartToggle.checked = Boolean(status.autoStart);
  elements.tokenMasked.textContent = status.tokenMasked;

  const healthy = status.bridgeStatus === "running" && status.rendererReady;
  elements.bridgeBadge.textContent = healthy
    ? "已连接"
    : status.bridgeStatus === "error"
      ? "网关异常"
      : "等待 Nanoleaf";
  elements.bridgeBadge.className = `badge ${healthy ? "ok" : status.bridgeStatus === "error" ? "error" : "muted"}`;

  const devices = Array.isArray(status.devices) ? status.devices : [];
  configuredKeys = devices.map((device) => device.key).filter((key) => key === "j" || key === "k");
  for (const key of ["j", "k"]) {
    const card = document.querySelector(`.device-card[data-key="${key}"]`);
    const device = devices.find((candidate) => candidate.key === key);
    card.hidden = !device;
    if (device) {
      card.querySelector('[data-role="name"]').textContent = device.name;
      card.querySelector('[data-role="id"]').textContent = device.id;
    }
  }
  const allCard = document.querySelector('.device-card[data-key="all"]');
  allCard.hidden = configuredKeys.length === 0;
  allCard.querySelector('[data-role="summary"]').textContent = devices.length > 1
    ? `同时控制 ${devices.map((device) => device.name).join("、")}`
    : devices.length === 1
      ? `控制 ${devices[0].name}`
      : "尚未配置设备";
}

function setCardLoading(card, loading) {
  if (!card) {
    return;
  }
  for (const button of card.querySelectorAll("button")) {
    button.disabled = loading;
  }
  if (loading) {
    card.querySelector('[data-role="state"]').textContent = "处理中";
  }
}

function applyDeviceState(card, result) {
  const state = card.querySelector('[data-role="state"]');
  const meta = card.querySelector('[data-role="meta"]');
  const on = Boolean(result?.on);
  state.textContent = on ? "已开启" : "已关闭";
  state.className = `device-state ${on ? "on" : "off"}`;
  const effect = result?.effect ? ` · ${result.effect}` : "";
  meta.textContent = `亮度 ${Number(result?.brightness || 0)}%${effect}`;
}

async function refreshStatus() {
  const status = await api.getStatus();
  applyStatus(status);
  return status;
}

async function refreshDevice(key) {
  const card = document.querySelector(`.device-card[data-key="${key}"]`);
  if (!card || card.hidden) {
    return;
  }
  setCardLoading(card, true);
  try {
    const result = await api.getDevice(key);
    applyDeviceState(card, result);
  } catch (error) {
    const state = card.querySelector('[data-role="state"]');
    const meta = card.querySelector('[data-role="meta"]');
    state.textContent = "读取失败";
    state.className = "device-state off";
    meta.textContent = error.message || "Nanoleaf 尚未准备完成";
  } finally {
    setCardLoading(card, false);
  }
}

async function refreshAll() {
  elements.refreshButton.disabled = true;
  try {
    await refreshStatus();
    await Promise.all([...configuredKeys, "all"].map(refreshDevice));
  } finally {
    elements.refreshButton.disabled = false;
  }
}

for (const card of document.querySelectorAll(".device-card")) {
  for (const button of card.querySelectorAll("button[data-action]")) {
    button.addEventListener("click", async () => {
      const key = card.dataset.key;
      const on = button.dataset.action === "on";
      setCardLoading(card, true);
      try {
        const result = await api.setPower(key, on);
        applyDeviceState(card, result);
        if (key !== "all") {
          await refreshDevice("all");
        } else {
          await Promise.all(configuredKeys.map(refreshDevice));
        }
      } catch (error) {
        toast(error.message || "控制失败", true);
      } finally {
        setCardLoading(card, false);
      }
    });
  }
}

elements.refreshButton.addEventListener("click", () => refreshAll().catch((error) => toast(error.message, true)));

elements.enabledToggle.addEventListener("change", async () => {
  try {
    applyStatus(await api.setEnabled(elements.enabledToggle.checked));
    toast(elements.enabledToggle.checked ? "HA 网关已开启" : "HA 网关已关闭");
  } catch (error) {
    elements.enabledToggle.checked = !elements.enabledToggle.checked;
    toast(error.message, true);
  }
});

elements.autoStartToggle.addEventListener("change", async () => {
  try {
    applyStatus(await api.setAutoStart(elements.autoStartToggle.checked));
    toast(elements.autoStartToggle.checked ? "已启用登录启动" : "已关闭登录启动");
  } catch (error) {
    elements.autoStartToggle.checked = !elements.autoStartToggle.checked;
    toast(error.message, true);
  }
});

elements.copyTokenButton.addEventListener("click", async () => {
  await api.copyToken();
  toast("访问密钥已复制");
});

elements.regenerateTokenButton.addEventListener("click", async () => {
  if (!confirm("重新生成密钥后，HAOS 中的 Bearer 密钥也必须更新。确定继续吗？")) {
    return;
  }
  applyStatus(await api.regenerateToken());
  toast("已生成新密钥，请重新复制 HA YAML");
});

elements.copyYamlButton.addEventListener("click", async () => {
  await api.copyYaml();
  toast("HA YAML 已复制到剪贴板");
});

elements.openFolderButton.addEventListener("click", () => api.openFolder());

elements.prepareUpdateButton.addEventListener("click", async () => {
  if (!confirm("这会关闭 Nanoleaf、还原官方 app.asar 并暂停插件修复任务。更新完成后需要运行 resume-after-update.ps1。继续吗？")) {
    return;
  }
  await api.prepareUpdate();
  toast("请在 UAC 窗口中确认");
});

refreshAll().catch((error) => toast(error.message || "初始化失败", true));
