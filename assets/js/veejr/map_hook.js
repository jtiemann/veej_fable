// Leaflet map for encrypted location shares and geo-notes.
//
// The server hands us ciphertext envelopes as data attributes; coordinates
// only ever exist decrypted in this browser. Outgoing coords are fed to the
// composers via window.veejrPayloadProviders, never through LiveView.

import {getSecretKey, openFrom} from "./crypto.js"

const LEAFLET_JS = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
const LEAFLET_CSS = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"

function ensureLeaflet() {
  if (window.L) return Promise.resolve(window.L)
  return new Promise((resolve, reject) => {
    const css = document.createElement("link")
    css.rel = "stylesheet"
    css.href = LEAFLET_CSS
    document.head.appendChild(css)

    const script = document.createElement("script")
    script.src = LEAFLET_JS
    script.onload = () => resolve(window.L)
    script.onerror = () => reject(new Error("Could not load the map library (offline?)."))
    document.head.appendChild(script)
  })
}

function popupContent(entry) {
  const div = document.createElement("div")
  const who = document.createElement("p")
  who.style.fontWeight = "600"
  who.textContent = `${entry.kind === "note" ? "📝" : "📍"} ${entry.label}`
  div.appendChild(who)

  if (entry.payload.text) {
    const p = document.createElement("p")
    p.textContent = entry.payload.text
    div.appendChild(p)
  }

  const when = document.createElement("p")
  when.style.opacity = "0.6"
  when.style.fontSize = "0.8em"
  when.textContent = entry.time
  div.appendChild(when)
  return div
}

export const VeejrMap = {
  async mounted() {
    const userId = this.el.dataset.userId
    const status = this.el.querySelector("[data-role=map-status]")
    const say = (msg) => status && (status.textContent = msg)

    let L
    try {
      L = await ensureLeaflet()
    } catch (err) {
      say(err.message)
      return
    }

    const mySecret = getSecretKey(userId)
    if (!mySecret) {
      say("🔒 Unlock your keys to see the map content.")
    }

    const map = L.map(this.el.querySelector("[data-role=map-canvas]")).setView([20, 0], 2)
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: "&copy; OpenStreetMap contributors",
    }).addTo(map)
    this.map = map

    // Decrypt every envelope the server rendered and pin it.
    const points = []
    for (const el of this.el.querySelectorAll("[data-role=map-envelope]")) {
      if (!mySecret) break
      const {peerKey, ciphertext, nonce, kind, label, time} = el.dataset
      const payload = openFrom(ciphertext, nonce, peerKey, mySecret)
      if (!payload || typeof payload.lat !== "number" || typeof payload.lng !== "number") continue
      const entry = {payload, kind, label, time}
      const marker = L.marker([payload.lat, payload.lng]).addTo(map)
      marker.bindPopup(popupContent(entry))
      points.push([payload.lat, payload.lng])
    }

    if (points.length > 0) {
      map.fitBounds(points, {padding: [40, 40], maxZoom: 14})
      say(`${points.length} shared location${points.length === 1 ? "" : "s"} decrypted.`)
    } else if (mySecret) {
      say("Nothing on the map yet. Share your location or drop a note below.")
    }

    // --- outgoing coordinates (client-side only) --------------------
    this.picked = null
    this.located = null

    const pickedMarker = L.circleMarker([0, 0], {radius: 8, color: "#e11d48"})
    map.on("click", (e) => {
      this.picked = {lat: e.latlng.lat, lng: e.latlng.lng}
      pickedMarker.setLatLng(e.latlng).addTo(map)
      const readout = this.el.querySelector("[data-role=picked-readout]")
      if (readout) readout.textContent = `Pinned: ${e.latlng.lat.toFixed(5)}, ${e.latlng.lng.toFixed(5)}`
    })

    const locateBtn = this.el.querySelector("[data-role=locate]")
    if (locateBtn) {
      locateBtn.addEventListener("click", () => {
        locateBtn.disabled = true
        locateBtn.textContent = "Locating…"
        navigator.geolocation.getCurrentPosition(
          (pos) => {
            this.located = {lat: pos.coords.latitude, lng: pos.coords.longitude}
            map.setView([this.located.lat, this.located.lng], 15)
            L.circleMarker([this.located.lat, this.located.lng], {radius: 8, color: "#2563eb"}).addTo(map)
            locateBtn.disabled = false
            locateBtn.textContent = `📍 ${this.located.lat.toFixed(5)}, ${this.located.lng.toFixed(5)}`
          },
          (err) => {
            locateBtn.disabled = false
            locateBtn.textContent = "Location unavailable"
            say(`Geolocation failed: ${err.message}`)
          },
          {enableHighAccuracy: true, timeout: 15_000}
        )
      })
    }

    window.veejrPayloadProviders = window.veejrPayloadProviders || {}
    window.veejrPayloadProviders["location-composer"] = () =>
      this.located ? {...this.located, located_at: new Date().toISOString()} : null
    window.veejrPayloadProviders["note-composer"] = () => (this.picked ? {...this.picked} : null)
  },

  destroyed() {
    if (window.veejrPayloadProviders) {
      delete window.veejrPayloadProviders["location-composer"]
      delete window.veejrPayloadProviders["note-composer"]
    }
    if (this.map) this.map.remove()
  },
}

export default VeejrMap
