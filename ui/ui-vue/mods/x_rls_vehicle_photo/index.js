// RLS Vehicle Photo: adds "New image" and "Photo studio..." to the vehicle menu on RLS's My Vehicles page.
// Left-click a vehicle as usual, or right-click it, and pick one. Nothing in RLS is replaced: the items are
// added to RLS's menu as it opens, so RLS updates keep working.
import { useBridge } from "@/bridge"

// The bridge's `lua` object only knows pre-registered functions, so call our extension directly.
function callLua(code) {
  return new Promise(resolve => useBridge().api.engineLua(code, resolve))
}

// Lua events reach the UI through the bridge's event bus.
function gameEvents() {
  try {
    const events = useBridge().events
    if (events && events.on) return events
  } catch (_) {}
  return window.bridge && window.bridge.events
}

const MENU_SELECTOR = '.bng-popover[data-bng-popover-name^="veh_options"]'
const TILE_SELECTOR = ".vehicle-tile-row"
const ITEM_CLASS = "rls-vehicle-photo-item"
const BUSY_LABEL = "Taking photo..."

const MENU_ITEMS = [
  { key: "photo", label: "New image", action: vehicle => takePhoto(vehicle) },
  { key: "studio", label: "Photo studio...", action: vehicle => openStudio(vehicle) },
]

let lastTile = null // { data, list } of the vehicle whose menu is open
let observer = null
let busy = false

function isVehicleRow(data) {
  return data && data.id !== undefined && !data._message
}

// The game's production Vue build doesn't link elements back to components, so find the tile's component
// by walking the render tree from the app root: the VehicleTileRow whose root element is this tile.
function findTileVnode(vnode, tile, depth) {
  if (!vnode || depth > 400) return null
  if (vnode.el === tile && vnode.component && isVehicleRow(vnode.props && vnode.props.data)) return vnode
  if (vnode.component) return findTileVnode(vnode.component.subTree, tile, depth + 1)
  if (vnode.suspense) return findTileVnode(vnode.suspense.activeBranch, tile, depth + 1)
  if (Array.isArray(vnode.children)) {
    for (const child of vnode.children) {
      const found = findTileVnode(child, tile, depth + 1)
      if (found) return found
    }
  }
  return null
}

// The tile's component holds the vehicle row data; its parent is RLS's VehicleList.
function tileVehicle(tile) {
  if (!tile) return null
  const dev = tile.__vueParentComponent // only present in dev builds
  if (dev && isVehicleRow(dev.props && dev.props.data)) return { data: dev.props.data, list: dev.parent }
  const root = window.bngVue && window.bngVue.app && window.bngVue.app._container && window.bngVue.app._container._vnode
  const vnode = findTileVnode(root, tile, 0)
  return vnode ? { data: vnode.props.data, list: vnode.component.parent } : null
}

function rememberTile(event) {
  const tile = event.target && event.target.closest && event.target.closest(TILE_SELECTOR)
  if (!tile) return
  const found = tileVehicle(tile)
  if (found) lastTile = found
  if (event.type === "contextmenu") {
    // Right-click opens the same menu a left-click does.
    event.preventDefault()
    tile.click()
  }
}

function closeMenu() {
  const hide = lastTile && lastTile.list && lastTile.list.setupState && lastTile.list.setupState.popHide
  if (typeof hide === "function") {
    try { hide() } catch (_) {}
  }
}

// Only touch the DOM on a real change, or the observer would wake itself up forever.
function setLabel(item, text) {
  const label = item.querySelector(".btn-label") || item
  if (label.textContent !== text) label.textContent = text
}

// In case the finished event never arrives, don't leave the menu stuck on "Taking photo...".
let busyTimer = null
function setBusy(value, timeout) {
  busy = value
  clearTimeout(busyTimer)
  if (value) busyTimer = setTimeout(() => onPhotoDone({}), timeout)
  refreshMenus()
}

async function takePhoto(vehicle) {
  setBusy(true, 30000)
  try {
    const started = await callLua(`xRlsVehiclePhoto.takePhoto(${JSON.stringify(vehicle.id)})`)
    if (!started) setBusy(false)
  } catch (err) {
    console.error("[x_rls_vehicle_photo] takePhoto failed", err)
    setBusy(false)
  }
}

function makeItem(template, def) {
  const item = template.cloneNode(true)
  item.classList.add(ITEM_CLASS)
  item.dataset.photoItem = def.key
  item.removeAttribute("disabled")
  item.removeAttribute("id")
  item.querySelectorAll(".btn-binding, .btn-icon").forEach(el => el.remove())
  const label = item.querySelector(".btn-label")
  if (label) label.replaceChildren()
  item.addEventListener("click", event => {
    event.preventDefault()
    event.stopPropagation()
    const vehicle = lastTile && lastTile.data
    if (busy || !vehicle) return
    closeMenu()
    def.action(vehicle)
  })
  return item
}

function updateMenu(menu) {
  const own = [...menu.querySelectorAll("." + ITEM_CLASS)]
  const rlsButtons = [...menu.querySelectorAll("button.house-button")].filter(b => !b.classList.contains(ITEM_CLASS))
  const vehicle = lastTile && lastTile.data
  const usable = vehicle && vehicle.owned !== false && !vehicle.missingFile
  if (!rlsButtons.length || !usable) {
    own.forEach(el => el.remove())
    return
  }
  const template = rlsButtons.find(b => !b.disabled) || rlsButtons[rlsButtons.length - 1]
  // Keep ours at the bottom, in order; only move them when needed so this observer doesn't trigger itself forever.
  let previous = rlsButtons[rlsButtons.length - 1]
  for (const def of MENU_ITEMS) {
    const item = own.find(el => el.dataset.photoItem === def.key) || makeItem(template, def)
    setLabel(item, busy ? BUSY_LABEL : def.label)
    item.disabled = busy
    if (previous.nextElementSibling !== item) previous.after(item)
    previous = item
  }
}

function refreshMenus() {
  document.querySelectorAll(MENU_SELECTOR).forEach(updateMenu)
}

// The whole UI mutates constantly (HUD apps), so coalesce observer wake-ups to one check per frame.
let refreshQueued = false
function queueRefresh() {
  if (refreshQueued) return
  refreshQueued = true
  requestAnimationFrame(() => {
    refreshQueued = false
    refreshMenus()
  })
}

// Photo studio panel -----------------------------------------------------------------------------------
// A live preview of the photo with sliders for the framing. Each change renders a new preview in the game.

const SLIDERS = [
  { key: "cameraDistance", label: "Distance", min: 0.5, max: 3, step: 0.05, format: v => v.toFixed(2) + "x" },
  { key: "yawDegrees", label: "Rotate", min: -180, max: 180, step: 1, format: v => v.toFixed(0) + "°" },
  { key: "cameraPitch", label: "Camera height", min: -30, max: 60, step: 1, format: v => v.toFixed(0) + "°" },
  { key: "frameShiftUp", label: "Move up / down", min: -0.5, max: 0.5, step: 0.01, format: v => v.toFixed(2) },
  { key: "frameShiftRight", label: "Move left / right", min: -0.5, max: 0.5, step: 0.01, format: v => v.toFixed(2) },
  { key: "fov", label: "Lens (field of view)", min: 10, max: 90, step: 1, format: v => v.toFixed(0) + "°" },
]

const STYLE = `
.xrvp-overlay { position: fixed; inset: 0; z-index: 10000; display: flex; align-items: center; justify-content: center;
  background: rgba(0, 0, 0, 0.55); font-family: inherit; color: #eee; }
.xrvp-panel { width: min(1100px, 94vw); max-height: 92vh; overflow: auto; background: rgba(24, 24, 26, 0.97);
  border-radius: 10px; box-shadow: 0 10px 40px rgba(0, 0, 0, 0.6); display: flex; flex-direction: column; }
.xrvp-title { padding: 14px 18px; font-size: 1.15em; font-weight: 600; border-bottom: 1px solid rgba(255, 255, 255, 0.1); }
.xrvp-body { display: flex; gap: 18px; padding: 18px; flex-wrap: wrap; }
.xrvp-preview { position: relative; flex: 1 1 560px; aspect-ratio: 16 / 9; background: #111; border-radius: 6px; overflow: hidden; }
.xrvp-preview img { width: 100%; height: 100%; object-fit: contain; display: block; }
.xrvp-status { position: absolute; left: 10px; bottom: 10px; padding: 4px 10px; border-radius: 4px;
  background: rgba(0, 0, 0, 0.65); font-size: 0.9em; }
.xrvp-status:empty { display: none; }
.xrvp-controls { flex: 1 1 280px; display: flex; flex-direction: column; gap: 14px; }
.xrvp-row label { display: flex; justify-content: space-between; font-size: 0.95em; margin-bottom: 4px; }
.xrvp-row .xrvp-value { color: #ff9a3c; font-variant-numeric: tabular-nums; }
.xrvp-row input[type=range] { width: 100%; accent-color: #ff6600; }
.xrvp-footer { display: flex; align-items: center; gap: 10px; padding: 14px 18px; border-top: 1px solid rgba(255, 255, 255, 0.1); }
.xrvp-footer .xrvp-check { flex: 1; display: flex; align-items: center; gap: 8px; cursor: pointer; }
.xrvp-footer button { padding: 8px 16px; border: 0; border-radius: 5px; font: inherit; cursor: pointer;
  background: rgba(255, 255, 255, 0.12); color: #eee; }
.xrvp-footer button:hover:not(:disabled) { background: rgba(255, 255, 255, 0.2); }
.xrvp-footer button.xrvp-primary { background: #ff6600; color: #fff; }
.xrvp-footer button.xrvp-primary:hover:not(:disabled) { background: #ff7a22; }
.xrvp-footer button:disabled { opacity: 0.45; cursor: default; }
`

let panel = null // { root, img, status, inputs, values, opened, ready, shooting, timer, inventoryId }

function el(tag, attrs, children) {
  const node = document.createElement(tag)
  for (const [key, value] of Object.entries(attrs || {})) {
    if (key === "text") node.textContent = value
    else node.setAttribute(key, value)
  }
  for (const child of children || []) node.append(child)
  return node
}

function ensureStyle() {
  if (document.getElementById("xrvp-style")) return
  document.head.append(el("style", { id: "xrvp-style", text: STYLE }))
}

function setStatus(text) {
  if (panel) panel.status.textContent = text || ""
}

function currentSettings() {
  const settings = {}
  for (const def of SLIDERS) settings[def.key] = Number(panel.inputs[def.key].value)
  return settings
}

function showSettings(settings) {
  for (const def of SLIDERS) {
    const value = Number(settings && settings[def.key])
    if (!Number.isFinite(value)) continue
    panel.inputs[def.key].value = String(value)
    panel.values[def.key].textContent = def.format(value)
  }
}

function setControlsEnabled(enabled) {
  for (const input of Object.values(panel.inputs)) input.disabled = !enabled
  for (const button of panel.root.querySelectorAll(".xrvp-footer button")) {
    button.disabled = !enabled && !button.classList.contains("xrvp-cancel")
  }
}

// Each slider move asks for a new preview; the game only renders the latest one it was sent.
function requestPreview() {
  if (!panel || !panel.ready || panel.shooting) return
  clearTimeout(panel.timer)
  panel.timer = setTimeout(() => {
    if (!panel || panel.shooting) return
    setStatus("Rendering...")
    callLua(`xRlsVehiclePhoto.studioPreview(${JSON.stringify(JSON.stringify(currentSettings()))})`)
  }, 120)
}

function closePanel() {
  if (!panel) return
  clearTimeout(panel.timer)
  panel.root.remove()
  document.removeEventListener("keydown", onPanelKey, true)
  panel = null
}

function cancelStudio() {
  callLua("xRlsVehiclePhoto.studioCancel()")
  closePanel()
  setBusy(false)
}

function shootStudio() {
  if (!panel || !panel.ready || panel.shooting) return
  panel.shooting = true
  clearTimeout(panel.timer)
  setControlsEnabled(false)
  setStatus("Taking photo...")
  const save = panel.root.querySelector(".xrvp-save").checked
  callLua(`xRlsVehiclePhoto.studioShoot(${JSON.stringify(JSON.stringify(currentSettings()))}, ${save})`).then(ok => {
    if (!ok) {
      closePanel()
      setBusy(false)
    }
  })
}

function onPanelKey(event) {
  if (event.key === "Escape" && panel) {
    event.preventDefault()
    event.stopPropagation()
    if (!panel.shooting) cancelStudio()
  }
}

function buildPanel(vehicle) {
  ensureStyle()
  const name = vehicle.niceName || vehicle.name || vehicle.model || ""
  const img = el("img", { alt: "" })
  img.style.visibility = "hidden"
  img.addEventListener("load", () => { img.style.visibility = "visible" })
  const status = el("div", { class: "xrvp-status", text: "Setting up the studio..." })
  const inputs = {}
  const values = {}
  const rows = SLIDERS.map(def => {
    const input = el("input", { type: "range", min: def.min, max: def.max, step: def.step })
    input.disabled = true
    const value = el("span", { class: "xrvp-value" })
    input.addEventListener("input", () => {
      value.textContent = def.format(Number(input.value))
      requestPreview()
    })
    // A double-click puts this slider back to where it was when the studio opened.
    input.addEventListener("dblclick", () => {
      if (!panel || !panel.opened) return
      showSettings({ [def.key]: panel.opened[def.key] })
      requestPreview()
    })
    inputs[def.key] = input
    values[def.key] = value
    return el("div", { class: "xrvp-row" }, [el("label", {}, [el("span", { text: def.label }), value]), input])
  })

  const reset = el("button", { text: "Reset" })
  reset.addEventListener("click", () => {
    if (!panel || !panel.opened) return
    showSettings(panel.opened)
    requestPreview()
  })
  const defaultsButton = el("button", { text: "Mod defaults" })
  defaultsButton.addEventListener("click", () => {
    if (!panel || !panel.defaults) return
    showSettings(panel.defaults)
    requestPreview()
  })
  const cancel = el("button", { class: "xrvp-cancel", text: "Cancel" })
  cancel.addEventListener("click", () => { if (panel && !panel.shooting) cancelStudio() })
  const shoot = el("button", { class: "xrvp-primary", text: "Take photo" })
  shoot.addEventListener("click", shootStudio)
  const save = el("input", { type: "checkbox", class: "xrvp-save" })
  save.checked = true

  const root = el("div", { class: "xrvp-overlay" }, [
    el("div", { class: "xrvp-panel" }, [
      el("div", { class: "xrvp-title", text: name ? `Photo studio – ${name}` : "Photo studio" }),
      el("div", { class: "xrvp-body" }, [
        el("div", { class: "xrvp-preview" }, [img, status]),
        el("div", { class: "xrvp-controls" }, rows),
      ]),
      el("div", { class: "xrvp-footer" }, [
        el("label", { class: "xrvp-check" }, [save, el("span", { text: "Use these settings for all photos" })]),
        reset, defaultsButton, cancel, shoot,
      ]),
    ]),
  ])
  // Keep clicks and keys in the panel from reaching the game UI behind it.
  for (const type of ["mousedown", "click", "contextmenu", "wheel"]) root.addEventListener(type, e => e.stopPropagation())
  document.body.append(root)
  document.addEventListener("keydown", onPanelKey, true)
  panel = { root, img, status, inputs, values, opened: null, defaults: null, ready: false, shooting: false, timer: null, inventoryId: vehicle.id }
  setControlsEnabled(false)
}

async function openStudio(vehicle) {
  if (panel) return
  buildPanel(vehicle)
  setBusy(true, 60 * 60 * 1000)
  try {
    const started = await callLua(`xRlsVehiclePhoto.openStudio(${JSON.stringify(vehicle.id)})`)
    if (!started) {
      closePanel()
      setBusy(false)
    }
  } catch (err) {
    console.error("[x_rls_vehicle_photo] openStudio failed", err)
    closePanel()
    setBusy(false)
  }
}

function onStudioEvent(data) {
  if (!panel || !data) return
  if (data.state === "ready") {
    panel.opened = data.settings
    panel.defaults = data.defaults
    panel.ready = true
    showSettings(data.settings)
    setControlsEnabled(true)
    setStatus("Rendering...")
  } else if (data.state === "preview" && !panel.shooting) {
    if (data.file) {
      panel.img.src = data.file
      setStatus("")
    } else {
      setStatus(data.error || "Could not render the preview")
    }
  }
}

function onPhotoDone() {
  closePanel()
  setBusy(false)
}

export function onLoad() {
  if (window.__xRlsVehiclePhotoLoaded) return
  window.__xRlsVehiclePhotoLoaded = true
  for (const type of ["mousedown", "click", "contextmenu", "focusin"]) {
    document.addEventListener(type, rememberTile, true)
  }
  observer = new MutationObserver(queueRefresh)
  observer.observe(document.body, { childList: true, subtree: true })
  const events = gameEvents()
  events?.on?.("XRlsVehiclePhotoDone", onPhotoDone)
  events?.on?.("XRlsVehiclePhotoStudio", onStudioEvent)
}

export function onUnload() {
  window.__xRlsVehiclePhotoLoaded = false
  for (const type of ["mousedown", "click", "contextmenu", "focusin"]) {
    document.removeEventListener(type, rememberTile, true)
  }
  if (observer) observer.disconnect()
  observer = null
  const events = gameEvents()
  events?.off?.("XRlsVehiclePhotoDone", onPhotoDone)
  events?.off?.("XRlsVehiclePhotoStudio", onStudioEvent)
  if (panel) cancelStudio()
  document.querySelectorAll("." + ITEM_CLASS).forEach(el => el.remove())
}
