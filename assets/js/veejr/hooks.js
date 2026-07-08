// LiveView hooks for veejr's client-side crypto.
//
// Security rule: passphrases and secret keys are read from plain DOM inputs
// inside these hooks and never travel over the LiveView socket. Only public
// keys and ciphertext are pushed to the server.

import {
  generateIdentity,
  unlockIdentity,
  wrapSecretKey,
  cacheSecretKey,
  getSecretKey,
  forgetSecretKey,
  sealFor,
  openFrom,
  encryptBlob,
  decryptBlob,
} from "./crypto.js"

// Promise wrapper around pushEvent-with-reply, shared by several hooks.
function pushWithReply(hook, event, params) {
  return new Promise((resolve, reject) => {
    hook.pushEvent(event, params, (reply) => {
      if (reply && reply.error) reject(new Error(reply.error))
      else resolve(reply)
    })
  })
}

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
  // `origin` records which instance holds the blob, so a recipient on a
  // different instance knows where to fetch it from.
  return {
    id,
    origin: window.location.origin,
    key: enc.key,
    nonce: enc.nonce,
    name: file.name,
    mime: file.type,
    size: file.size,
  }
}

// Downloads an encrypted blob, decrypts it locally, and hands it to the user
// as a normal file download. Cross-instance attachments carry their origin
// and are fetched from that instance's public capability endpoint; legacy
// attachments (no origin) live on this instance behind the session route.
async function downloadAttachment(att) {
  const fetchUrl = att.origin ? `${att.origin}/api/blobs/${att.id}` : `/blobs/${att.id}`
  const resp = await fetch(fetchUrl)
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
      if (returnTo) {
        // the user was sent here to unlock before doing something else
        this.pushEvent("unlocked", {})
      } else {
        // visiting the keys page directly while unlocked: show state, keep
        // the management sections below reachable
        form.querySelectorAll("input, button, label").forEach((el) => el.classList.add("hidden"))
        const note = document.createElement("p")
        note.className = "text-sm text-success"
        note.textContent = "✓ Keys are unlocked for this session."
        form.appendChild(note)
      }
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
        if (returnTo) window.location.assign(returnTo)
        else window.location.reload()
      } else {
        btn.disabled = false
        btn.textContent = "Unlock"
        showError(form, "Wrong passphrase.")
      }
    })
  },
}

// Passphrase change: unwrap with the current passphrase, re-wrap under the
// new one. The keypair — and therefore everything encrypted — is unchanged.
export const KeyRewrap = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const current = form.querySelector("[data-role=current]").value
      const next = form.querySelector("[data-role=next]").value
      const confirm = form.querySelector("[data-role=confirm]").value
      if (next.length < 8) return showError(form, "New passphrase must be at least 8 characters.")
      if (next !== confirm) return showError(form, "New passphrases do not match.")

      const {userId, encSecretKey, keySalt, keyNonce} = form.dataset
      const secretKey = await unlockIdentity(current, encSecretKey, keySalt, keyNonce)
      if (!secretKey) return showError(form, "Current passphrase is wrong.")

      const wrapped = await wrapSecretKey(secretKey, next)
      await pushWithReply(this, "rewrap_keys", {
        enc_secret_key: wrapped.encSecretKey,
        key_salt: wrapped.keySalt,
        key_nonce: wrapped.keyNonce,
      })
      cacheSecretKey(userId, secretKey)
      form.reset()
    })
  },
}

// Key rotation: decrypt the entire history with the old key, generate a new
// keypair, re-encrypt everything to it, and hand the server new wrapped keys
// plus the resealed ciphertext in one push. All crypto happens here.
export const KeyRotate = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const current = form.querySelector("[data-role=current]").value
      const next = form.querySelector("[data-role=next]").value
      if (next.length < 8) return showError(form, "New passphrase must be at least 8 characters.")

      const btn = form.querySelector("button[type=submit]")
      const busy = (label) => (btn.textContent = label)
      btn.disabled = true

      try {
        const {userId, encSecretKey, keySalt, keyNonce} = form.dataset
        const oldSecret = await unlockIdentity(current, encSecretKey, keySalt, keyNonce)
        if (!oldSecret) throw new Error("Current passphrase is wrong.")

        busy("Fetching history…")
        const {envelopes} = await pushWithReply(this, "list_resealable", {})

        busy(`Re-encrypting ${envelopes.length} items…`)
        const identity = await generateIdentity(next)
        const resealed = []
        let unreadable = 0
        for (const entry of envelopes) {
          const payload = openFrom(entry.ciphertext, entry.nonce, entry.peer_key, oldSecret)
          if (!payload) {
            unreadable++
            continue
          }
          resealed.push({
            public_id: entry.public_id,
            ...sealFor(identity.publicKey, payload, identity.secretKey),
          })
        }

        busy("Saving new keys…")
        await pushWithReply(this, "rotate_keys", {
          keys: {
            public_key: identity.publicKey,
            enc_secret_key: identity.encSecretKey,
            key_salt: identity.keySalt,
            key_nonce: identity.keyNonce,
          },
          envelopes: resealed,
          unreadable: unreadable,
        })
        cacheSecretKey(userId, identity.secretKey)
        window.location.reload()
      } catch (err) {
        btn.disabled = false
        btn.textContent = "Rotate my keys"
        showError(form, err.message)
      }
    })
  },
}

// Key reset for a lost passphrase: brand-new keypair; old ciphertext is
// gone for good (the server deletes this user's undecryptable copies).
export const KeyReset = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const next = form.querySelector("[data-role=next]").value
      const confirm = form.querySelector("[data-role=confirm]").value
      if (next.length < 8) return showError(form, "Passphrase must be at least 8 characters.")
      if (next !== confirm) return showError(form, "Passphrases do not match.")
      if (!window.confirm("Really reset? Every message you've received so far becomes permanently unreadable."))
        return

      const identity = await generateIdentity(next)
      await pushWithReply(this, "reset_keys", {
        keys: {
          public_key: identity.publicKey,
          enc_secret_key: identity.encSecretKey,
          key_salt: identity.keySalt,
          key_nonce: identity.keyNonce,
        },
      })
      cacheSecretKey(this.el.dataset.userId, identity.secretKey)
      window.location.assign("/")
    })
  },
}

// PWA install button: visible only when the browser offered an install
// prompt (Chrome/Edge; other browsers install from their own menus).
export const InstallApp = {
  mounted() {
    const btn = this.el
    const show = () => btn.classList.remove("hidden")
    if (window.veejrInstallPrompt) show()
    window.addEventListener("veejr:installable", show)

    btn.addEventListener("click", async () => {
      const prompt = window.veejrInstallPrompt
      if (!prompt) return
      prompt.prompt()
      const {outcome} = await prompt.userChoice
      if (outcome === "accepted") {
        btn.textContent = "✅ Installed"
        btn.disabled = true
        window.veejrInstallPrompt = null
      }
    })
  },
}

// Keeps a chat thread scrolled to the newest message at the bottom, the way
// a messaging app does. Runs on mount and whenever the thread re-renders.
export const ScrollBottom = {
  mounted() {
    this.loadingMore = false
    this.beforeLoadHeight = 0
    this.loadMore = () => {
      if (this.loadingMore || this.el.dataset.hasMore !== "true") return

      this.loadingMore = true
      this.beforeLoadHeight = this.el.scrollHeight
      this.pushEvent("load_more_messages", {})
    }
    this.onScroll = () => {
      if (this.loadingMore || this.el.dataset.hasMore !== "true") return
      if (this.el.scrollTop > 48) return

      this.loadMore()
    }
    this.onClick = (event) => {
      if (!event.target.closest("[data-role='load-more-messages']")) return
      event.preventDefault()
      this.loadMore()
    }
    this.el.addEventListener("scroll", this.onScroll)
    this.el.addEventListener("click", this.onClick)
    this.toBottom()
  },
  updated() {
    if (this.loadingMore) {
      requestAnimationFrame(() => {
        const delta = this.el.scrollHeight - this.beforeLoadHeight
        this.el.scrollTop = this.el.scrollTop + delta
        this.loadingMore = false
      })
    } else {
      this.toBottom()
    }
  },
  destroyed() {
    if (this.onScroll) this.el.removeEventListener("scroll", this.onScroll)
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
  },
  toBottom() {
    // let decrypted bubbles paint first
    requestAnimationFrame(() => {
      this.el.scrollTop = this.el.scrollHeight
    })
  },
}

// Reply button on a conversation: preselects its participants in the
// composer and jumps there.
export const ReplyTo = {
  mounted() {
    this.el.addEventListener("click", () => {
      const ids = (this.el.dataset.friendIds || "").split(",").filter(Boolean)
      const composer = document.querySelector("#message-composer")
      if (!composer) return
      composer
        .querySelectorAll("input[name='friends[]']")
        .forEach((cb) => (cb.checked = ids.includes(cb.value)))
      composer.scrollIntoView({behavior: "smooth", block: "center"})
      const text = composer.querySelector("[data-role=text]")
      if (text) text.focus()
    })
  },
}

// Web Push opt-in for this device: permission → service worker → subscribe
// with the instance's VAPID key → register the subscription server-side.
export const PushSetup = {
  mounted() {
    const el = this.el
    const btn = el.querySelector("[data-role=push-enable]")
    const status = el.querySelector("[data-role=push-status]")
    const say = (msg) => status && (status.textContent = msg)

    if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
      btn.disabled = true
      say("Push is not supported in this browser.")
      return
    }

    btn.addEventListener("click", async () => {
      btn.disabled = true
      try {
        const permission = await Notification.requestPermission()
        if (permission !== "granted") throw new Error("notification permission was not granted")

        say("Registering service worker…")
        const registration = await navigator.serviceWorker.register("/sw.js")
        await navigator.serviceWorker.ready

        say("Subscribing…")
        const subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlB64ToBytes(el.dataset.vapidKey),
        })

        const resp = await fetch("/push/subscriptions", {
          method: "POST",
          headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
          body: JSON.stringify(subscription.toJSON()),
        })
        if (!resp.ok) throw new Error(`server refused the subscription (${resp.status})`)

        say("✅ Push notifications are enabled on this device.")
      } catch (err) {
        say(`Could not enable push: ${err.message}`)
        btn.disabled = false
      }
    })
  },
}

function urlB64ToBytes(b64url) {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/")
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4)
  const bin = atob(padded)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes
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
//   input[name="friends[]"] / input[name="groups[]"] checked or hidden
//   [data-role=files]               file input (optional)
//   [data-role=error]               error line
// Dataset: user-id, my-key, kind
export const Composer = {
  mounted() {
    this.onComposerClick = (e) => {
      const toggle = e.target.closest("[data-role=emoji-toggle]")
      if (!toggle || !this.el.contains(toggle)) return

      e.preventDefault()
      e.stopPropagation()
      this.captureEmojiElements()
      this.setEmojiMenuOpen(this.emojiMenu.classList.contains("hidden"))
    }

    this.onDocumentClick = (e) => {
      if (this.emojiMenu && this.emojiMenu.contains(e.target)) {
        const btn = e.target.closest("[data-role=emoji-option]")
        if (!btn) return

        e.preventDefault()
        this.insertEmoji(btn.dataset.emoji || "")
        this.setEmojiMenuOpen(false)
        return
      }

      if (this.el.contains(e.target)) return
      this.setEmojiMenuOpen(false)
    }

    this.onDocumentKeydown = (e) => {
      if (e.key === "Escape") this.setEmojiMenuOpen(false)
    }

    this.el.addEventListener("click", this.onComposerClick)
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("keydown", this.onDocumentKeydown)

    this.el.addEventListener("submit", (e) => {
      e.preventDefault()
      this.send().catch((err) => showError(this.el, err.message))
    })
  },

  captureEmojiElements() {
    const previousMenu = this.emojiMenu
    this.emojiMenu = this.el.querySelector("[data-role=emoji-menu]")
    this.emojiToggle = this.el.querySelector("[data-role=emoji-toggle]")
    this.textEl = this.el.querySelector("[data-role=text]")
    if (this.emojiMenu && this.emojiMenu !== previousMenu) {
      this.originalEmojiParent = this.emojiMenu.parentElement
      this.originalEmojiNextSibling = this.emojiMenu.nextSibling
    }
  },

  destroyed() {
    if (this.onComposerClick) this.el.removeEventListener("click", this.onComposerClick)
    if (this.onDocumentClick) document.removeEventListener("click", this.onDocumentClick)
    if (this.onDocumentKeydown) document.removeEventListener("keydown", this.onDocumentKeydown)
    if (this.emojiMenu && this.emojiMenu.parentElement === document.body) this.emojiMenu.remove()
  },

  setEmojiMenuOpen(open) {
    if (!this.emojiMenu || !this.emojiToggle) return
    if (open && this.emojiMenu.parentElement !== document.body) {
      document.body.appendChild(this.emojiMenu)
    }

    this.emojiMenu.classList.toggle("hidden", !open)
    this.emojiToggle.setAttribute("aria-expanded", open ? "true" : "false")

    if (!open) {
      if (
        this.originalEmojiParent &&
        this.originalEmojiParent.isConnected &&
        this.emojiMenu.parentElement === document.body
      ) {
        this.originalEmojiParent.insertBefore(this.emojiMenu, this.originalEmojiNextSibling)
      }
      return
    }

    const rect = this.emojiToggle.getBoundingClientRect()
    const gap = 8
    const menuWidth = this.emojiMenu.offsetWidth
    const menuHeight = this.emojiMenu.offsetHeight
    const left = Math.min(
      Math.max(gap, rect.right - menuWidth),
      Math.max(gap, window.innerWidth - menuWidth - gap)
    )
    let top = rect.top - menuHeight - gap
    if (top < gap) top = Math.min(window.innerHeight - menuHeight - gap, rect.bottom + gap)

    Object.assign(this.emojiMenu.style, {
      position: "fixed",
      bottom: "auto",
      right: "auto",
      left: `${left}px`,
      top: `${Math.max(gap, top)}px`,
      zIndex: "1000",
    })
  },

  insertEmoji(emoji) {
    if (!emoji || !this.textEl) return
    const textEl = this.textEl
    const start = textEl.selectionStart ?? textEl.value.length
    const end = textEl.selectionEnd ?? textEl.value.length
    textEl.setRangeText(emoji, start, end, "end")
    textEl.dispatchEvent(new Event("input", {bubbles: true}))
    textEl.focus()
  },

  async send() {
    const form = this.el
    const {userId, myKey, kind} = form.dataset
    const mySecret = getSecretKey(userId)
    if (!mySecret) {
      window.location.assign(`/keys?return_to=${encodeURIComponent(location.pathname)}`)
      return
    }

    const selectedValues = (name) => [
      ...new Set(
        [...form.querySelectorAll(`input[name='${name}']`)]
          .filter((el) => el.type === "hidden" || el.checked)
          .map((el) => el.value)
          .filter(Boolean),
      ),
    ]

    const friendIds = selectedValues("friends[]")
    const groupIds = selectedValues("groups[]")
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

      // recipient handles ride inside the encrypted payload so group
      // messages can show all participants after decryption
      const to = recipients.map((r) => r.handle || `@${r.username}`)
      const payload = {v: 1, kind, text, attachments, to, sent_at: new Date().toISOString(), ...extra}

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

    if (Array.isArray(payload.to) && payload.to.length > 1) {
      const p = document.createElement("p")
      p.className = "text-xs opacity-60 mt-1"
      p.textContent = `👥 ${payload.to.join(", ")}`
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

export default {
  KeySetup,
  KeyUnlock,
  KeyLock,
  KeyRewrap,
  KeyRotate,
  KeyReset,
  PushSetup,
  InstallApp,
  Composer,
  Decrypt,
  ReplyTo,
  ScrollBottom,
  VeejrMap,
}
