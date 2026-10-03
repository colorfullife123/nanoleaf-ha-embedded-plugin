const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("nanoleafHA", {
  getStatus: () => ipcRenderer.invoke("nanoleaf-ha:get-status"),
  getDevice: (key) => ipcRenderer.invoke("nanoleaf-ha:get-device", key),
  setPower: (key, on) => ipcRenderer.invoke("nanoleaf-ha:set-power", key, on),
  setEnabled: (enabled) => ipcRenderer.invoke("nanoleaf-ha:set-enabled", enabled),
  setAutoStart: (enabled) => ipcRenderer.invoke("nanoleaf-ha:set-autostart", enabled),
  copyYaml: () => ipcRenderer.invoke("nanoleaf-ha:copy-yaml"),
  copyToken: () => ipcRenderer.invoke("nanoleaf-ha:copy-token"),
  regenerateToken: () => ipcRenderer.invoke("nanoleaf-ha:regenerate-token"),
  openFolder: () => ipcRenderer.invoke("nanoleaf-ha:open-folder"),
  prepareUpdate: () => ipcRenderer.invoke("nanoleaf-ha:prepare-update"),
});
