// LiveView hooks for veejr's client-side crypto.
//
// Security rule: passphrases and secret keys are read from plain DOM inputs
// inside these hooks and never travel over the LiveView socket. Only public
// keys and ciphertext are pushed to the server.

import {
  generateIdentity,
  unlockIdentity,
  cacheSecretKey,
  getSecretKey,
  forgetSecretKey,
  sealFor,
  openFrom,
  encryptBlob,
  decryptBlob,
} from "./crypto.js"

const csrfToken = () =>
  document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Encrypts one file with a fresh symmetric key and uploads the ciphertext.
// Returns the attachment descriptor that rides inside the envelope payload.
async function encryptAndUpload(file) {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const enc = encryptBlob(bytes)
  const resp = await fetch("/blobs", {
    method: "POST",
    headers: {"content-type": "application/octet-stream", "x-csrf-token": csrfToken()},
    body: enc.data,
  })
  if (!resp.ok) throw new Error(`upload failed (${resp.status})`)
  const {id} = await resp.json()
  return {id, key: enc.key, nonce: enc.nonce, name: file.name, mime: file.type, size: file.size}
}

// Downloads an encrypted blob, decrypts it locally, and hands it to the user
// as a normal file download.
async function downloadAttachment(att) {
  const resp = await fetch(`/blobs/${att.id}`)
  if (!resp.ok) throw new Error(`download failed (${resp.status})`)
  const cipher = new Uint8Array(await resp.arrayBuffer())
  const plain = decryptBlob(cipher, att.key, att.nonce)
  if (!plain) throw new Error("attachment failed authentication")
  const url = URL.createObjectURL(new Blob([plain], {type: att.mime || "application/octet-stream"}))
  const a = document.createElement("a")
  a.href = url
  a.download = att.name || "attachment"
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 30_000)
}

function showError(el, msg) {
  const err = el.querySelector("[data-role=error]")
  if (err) {
    err.textContent = msg
    err.classList.remove("hidden")
  }
}

// Key setup: generate a keypair, wrap the secret key with the passphrase,
// push only public material to the server.
export const KeySetup = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const pass = form.querySelector("[data-role=passphrase]").value
      const confirm = form.querySelector("[data-role=confirm]").value
      if (pass.length < 8) return showError(form, "Passphrase must be at least 8 characters.")
      if (pass !== confirm) return showError(form, "Passphrases do not match.")

      const btn = form.querySelector("button[type=submit]")
      btn.disabled = true
      btn.textContent = "Generating keys…"
      try {
        const id = await generateIdentity(pass)
        cacheSecretKey(this.el.dataset.userId, id.secretKey)
        this.pushEvent("keys_generated", {
          public_key: id.publicKey,
          enc_secret_key: id.encSecretKey,
          key_salt: id.keySalt,
          key_nonce: id.keyNonce,
        })
      } catch (err) {
        btn.disabled = false
        btn.textContent = "Generate my keys"
        showError(form, `Key generation failed: ${err.message}`)
      }
    })
  },
}

// Key unlock: derive the wrapping key from the passphrase and unwrap the
// roaming secret key. Entirely client-side; on success we just navigate.
export const KeyUnlock = {
  mounted() {
    const form = this.el
    const {userId, encSecretKey, keySalt, keyNonce, returnTo} = form.dataset

    if (getSecretKey(userId)) {
      this.pushEvent("unlocked", {})
      return
    }

    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const pass = form.querySelector("[data-role=passphrase]").value
      const btn = form.querySelector("button[type=submit]")
      btn.disabled = true
      btn.textContent = "Unlocking…"
      const secretKey = await unlockIdentity(pass, encSecretKey, keySalt, keyNonce)
      if (secretKey) {
        cacheSecretKey(userId, secretKey)
        window.location.assign(returnTo || "/")
      } else {
        btn.disabled = false
        btn.textContent = "Unlock"
        showError(form, "Wrong passphrase.")
      }
    })
  },
}

// Lock button: drop the cached secret key for this session.
export const KeyLock = {
  mounted() {
    this.el.addEventListener("click", () => {
      forgetSecretKey(this.el.dataset.userId)
      window.location.reload()
    })
  },
}

// Composer: a plain (non-LiveView) form. Message text, files, and recipient
// choices are read locally; only ciphertext leaves this hook.
//
// Expects inside this.el:
//   [data-role=text]                the message textarea (optional for kinds
//                                   whose payload comes from data-payload)
//   input[name="friends[]"]:checked / input[name="groups[]"]:checked
//   [data-role=files]               file input (optional)
//   [data-role=error]               error line
// Dataset: user-id, my-key, kind
export const Composer = {
  mounted() {
    this.el.addEventListener("submit", (e) => {
      e.preventDefault()
      this.send().catch((err) => showError(this.el, err.message))
    })
  },

  async send() {
    const form = this.el
    const {userId, myKey, kind} = form.dataset
    const mySecret = getSecretKey(userId)
    if (!mySecret) {
      window.location.assign(`/keys?return_to=${encodeURIComponent(location.pathname)}`)
      return
    }

    const friendIds = [...form.querySelectorAll("input[name='friends[]']:checked")].map((el) => el.value)
    const groupIds = [...form.querySelectorAll("input[name='groups[]']:checked")].map((el) => el.value)
    if (friendIds.length + groupIds.length === 0) throw new Error("Pick at least one friend or group.")

    const textEl = form.querySelector("[data-role=text]")
    // Payload providers let other hooks (the map) contribute client-side-only
    // fields like coordinates without routing them through the server.
    const provider = window.veejrPayloadProviders && window.veejrPayloadProviders[form.id]
    const extra = provider
      ? provider()
      : form.dataset.payload
        ? JSON.parse(form.dataset.payload)
        : {}
    if (extra === null) throw new Error("Pick or acquire a location first.")
    const text = textEl ? textEl.value.trim() : ""
    const filesEl = form.querySelector("[data-role=files]")
    const files = filesEl ? [...filesEl.files] : []
    if (!text && files.length === 0 && Object.keys(extra).length === 0) {
      throw new Error("Nothing to send.")
    }

    const btn = form.querySelector("button[type=submit]")
    btn.disabled = true
    const originalLabel = btn.textContent
    const busy = (label) => (btn.textContent = label)

    try {
      busy("Resolving recipients…")
      const {recipients, missing_keys} = await this.pushWithReply("resolve_recipients", {
        friend_ids: friendIds,
        group_ids: groupIds,
      })
      if (missing_keys.length > 0) {
        throw new Error(`No encryption keys yet: ${missing_keys.join(", ")}. They must finish key setup first.`)
      }
      if (recipients.length === 0) throw new Error("Nobody to send to.")

      const attachments = []
      for (const [i, file] of files.entries()) {
        busy(`Encrypting attachment ${i + 1}/${files.length}…`)
        attachments.push(await encryptAndUpload(file))
      }

      const payload = {v: 1, kind, text, attachments, sent_at: new Date().toISOString(), ...extra}

      busy("Encrypting…")
      const envelopes = recipients.map((r) => ({
        recipient_id: r.id,
        ...sealFor(r.public_key, payload, mySecret),
      }))
      // Self-copy so our own history stays readable.
      envelopes.push({recipient_id: parseInt(userId), ...sealFor(myKey, payload, mySecret)})

      busy("Sending…")
      await this.pushWithReply("send_batch", {kind, envelopes})

      form.reset()
      const err = form.querySelector("[data-role=error]")
      if (err) err.classList.add("hidden")
    } finally {
      btn.disabled = false
      btn.textContent = originalLabel
    }
  },

  pushWithReply(event, params) {
    return new Promise((resolve, reject) => {
      this.pushEvent(event, params, (reply) => {
        if (reply.error) reject(new Error(reply.error))
        else resolve(reply)
      })
    })
  },
}

// Decrypt: renders one envelope's plaintext. The ciphertext arrives as data
// attributes; decryption happens here and the result is written with
// textContent (never innerHTML).
//
// Dataset: user-id, peer-key, ciphertext, nonce, kind
export const Decrypt = {
  mounted() {
    this.render()
  },

  render() {
    const {userId, peerKey, ciphertext, nonce, kind} = this.el.dataset
    const mySecret = getSecretKey(userId)

    this.el.textContent = ""

    if (!mySecret) {
      const a = document.createElement("a")
      a.href = `/keys?return_to=${encodeURIComponent(location.pathname)}`
      a.className = "link text-sm opacity-70"
      a.textContent = "🔒 Locked — unlock your keys to read"
      this.el.appendChild(a)
      return
    }

    const payload = openFrom(ciphertext, nonce, peerKey, mySecret)
    if (!payload) {
      const p = document.createElement("p")
      p.className = "text-error text-sm"
      p.textContent = "⚠ Could not decrypt (wrong keys or tampered data)."
      this.el.appendChild(p)
      return
    }

    if (kind === "note" && payload.title) {
      const h = document.createElement("p")
      h.className = "font-semibold"
      h.textContent = payload.title
      this.el.appendChild(h)
    }

    if (payload.text) {
      const p = document.createElement("p")
      p.className = "whitespace-pre-wrap"
      p.textContent = payload.text
      this.el.appendChild(p)
    }

    if (kind === "location" || kind === "note") {
      if (typeof payload.lat === "number" && typeof payload.lng === "number") {
        const p = document.createElement("p")
        p.className = "text-sm opacity-70"
        p.textContent = `📍 ${payload.lat.toFixed(5)}, ${payload.lng.toFixed(5)}`
        this.el.appendChild(p)
      }
    }

    for (const att of payload.attachments || []) {
      const btn = document.createElement("button")
      btn.className = "btn btn-outline btn-xs mt-1 mr-1"
      btn.textContent = `📎 ${att.name || "attachment"} (${Math.ceil((att.size || 0) / 1024)} KB)`
      btn.addEventListener("click", () =>
        downloadAttachment(att).catch((err) => (btn.textContent = `⚠ ${err.message}`))
      )
      this.el.appendChild(btn)
    }
  },
}

import VeejrMap from "./map_hook.js"

export default {KeySetup, KeyUnlock, KeyLock, Composer, Decrypt, VeejrMap}
