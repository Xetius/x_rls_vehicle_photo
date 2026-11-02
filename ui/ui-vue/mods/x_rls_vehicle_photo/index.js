// RLS Vehicle Photo: adds "New image" to the vehicle menu on RLS's My Vehicles page.
// Left-click a vehicle as usual, or right-click it, and pick "New image". Nothing in RLS is replaced:
// the item is added to RLS's menu as it opens, so RLS updates keep working.
import { useBridge } from "@/bridge"

// The bridge's `lua` object only knows pre-registered functions, so call our extension directly.
function callLua(code) {
  return new Promise(resolve => useBridge().api.engineLua(code, resolve))
}

const MENU_SELECTOR = '.bng-popover[data-bng-popover-name^="veh_options"]'
const TILE_SELECTOR = ".vehicle-tile-row"
const ITEM_CLASS = "rls-vehicle-photo-item"
const LABEL = "New image"
const BUSY_LABEL = "Taking photo..."

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

async function takePhoto(event) {
  event.preventDefault()
  event.stopPropagation()
  const vehicle = lastTile && lastTile.data
  if (busy || !vehicle) return
  busy = true
  refreshMenus()
  // In case the finished event never arrives, don't leave the item stuck on "Taking photo...".
  setTimeout(onPhotoDone, 30000)
  try {
    const started = await callLua(`xRlsVehiclePhoto.takePhoto(${JSON.stringify(vehicle.id)})`)
    if (!started) busy = false
  } catch (err) {
    console.error("[x_rls_vehicle_photo] takePhoto failed", err)
    busy = false
  }
  refreshMenus()
  closeMenu()
}

function makeItem(template) {
  const item = template.cloneNode(true)
  item.classList.add(ITEM_CLASS)
  item.removeAttribute("disabled")
  item.removeAttribute("id")
  item.querySelectorAll(".btn-binding, .btn-icon").forEach(el => el.remove())
  const label = item.querySelector(".btn-label")
  if (label) label.replaceChildren()
  item.addEventListener("click", takePhoto)
  return item
}

function updateMenu(menu) {
  const own = menu.querySelector("." + ITEM_CLASS)
  const rlsButtons = [...menu.querySelectorAll("button.house-button")].filter(b => !b.classList.contains(ITEM_CLASS))
  const vehicle = lastTile && lastTile.data
  const usable = vehicle && vehicle.owned !== false && !vehicle.missingFile
  if (!rlsButtons.length || !usable) {
    if (own) own.remove()
    return
  }
  const last = rlsButtons[rlsButtons.length - 1]
  const item = own || makeItem(rlsButtons.find(b => !b.disabled) || last)
  setLabel(item, busy ? BUSY_LABEL : LABEL)
  item.disabled = busy
  // Keep it at the bottom; only move it when needed so this observer doesn't trigger itself forever.
  if (last.nextElementSibling !== item) last.after(item)
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

function onPhotoDone() {
  busy = false
  refreshMenus()
}

export function onLoad() {
  if (window.__xRlsVehiclePhotoLoaded) return
  window.__xRlsVehiclePhotoLoaded = true
  for (const type of ["mousedown", "click", "contextmenu", "focusin"]) {
    document.addEventListener(type, rememberTile, true)
  }
  observer = new MutationObserver(queueRefresh)
  observer.observe(document.body, { childList: true, subtree: true })
  window.vueEventBus?.on?.("XRlsVehiclePhotoDone", onPhotoDone)
}

export function onUnload() {
  window.__xRlsVehiclePhotoLoaded = false
  for (const type of ["mousedown", "click", "contextmenu", "focusin"]) {
    document.removeEventListener(type, rememberTile, true)
  }
  if (observer) observer.disconnect()
  observer = null
  window.vueEventBus?.off?.("XRlsVehiclePhotoDone", onPhotoDone)
  document.querySelectorAll("." + ITEM_CLASS).forEach(el => el.remove())
}
