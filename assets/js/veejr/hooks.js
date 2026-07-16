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

const currentLocationPath = () =>
  `${window.location.pathname}${window.location.search}${window.location.hash}`

// Encrypts one file with a fresh symmetric key and uploads the ciphertext.
// Returns the attachment descriptor that rides inside the envelope payload.
async function encryptAndUpload(file, metadata = {}) {
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
    name: metadata.name || file.name,
    mime: metadata.mime || file.type,
    size: metadata.size || file.size,
    duration_ms: metadata.durationMs,
  }
}

async function decryptAttachmentBlob(att) {
  const urls = [
    att.origin ? `${att.origin}/api/blobs/${att.id}` : null,
    `/api/blobs/${att.id}`,
    `/blobs/${att.id}`,
  ].filter(Boolean)

  let resp = null
  let lastError = null
  for (const url of [...new Set(urls)]) {
    try {
      resp = await fetch(url)
      if (resp.ok) break
      lastError = new Error(`download failed (${resp.status})`)
    } catch (err) {
      lastError = err
    }
    resp = null
  }

  if (!resp || !resp.ok) throw lastError || new Error("download failed")
  const cipher = new Uint8Array(await resp.arrayBuffer())
  const plain = decryptBlob(cipher, att.key, att.nonce)
  if (!plain) throw new Error("attachment failed authentication")
  return new Blob([plain], {type: att.mime || "application/octet-stream"})
}

// Downloads an encrypted blob, decrypts it locally, and hands it to the user
// as a normal file download. Cross-instance attachments carry their origin
// and are fetched from that instance's public capability endpoint; legacy
// attachments (no origin) live on this instance behind the session route.
async function downloadAttachment(att) {
  const blob = await decryptAttachmentBlob(att)
  const url = URL.createObjectURL(blob)
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

function preferredAudioMime() {
  const types = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
  return types.find((type) => window.MediaRecorder && MediaRecorder.isTypeSupported(type)) || ""
}

function attachmentMime(att) {
  const mime = att.mime || ""
  const name = (att.name || "").toLowerCase()
  if (mime.startsWith("image/")) return mime
  if (mime === "application/pdf" || mime === "application/x-pdf" || name.endsWith(".pdf")) {
    return "application/pdf"
  }
  return mime
}

function previewableMedia(att) {
  const mime = attachmentMime(att)
  return mime.startsWith("image/") || mime === "application/pdf"
}

function showMediaModal({blob, title, mime}) {
  const mediaBlob = mime === "application/pdf" && blob.type !== "application/pdf"
    ? new Blob([blob], {type: "application/pdf"})
    : blob
  const url = URL.createObjectURL(mediaBlob)
  const overlay = document.createElement("div")
  overlay.className = "fixed inset-0 z-[1100] flex items-center justify-center bg-black/70 p-4"
  overlay.setAttribute("role", "dialog")
  overlay.setAttribute("aria-modal", "true")

  const panel = document.createElement("div")
  panel.className = "flex max-h-[92vh] w-full max-w-5xl flex-col overflow-hidden rounded-lg bg-base-100 text-base-content shadow-2xl"

  const header = document.createElement("div")
  header.className = "flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3"

  const h = document.createElement("h3")
  h.className = "truncate text-sm font-medium text-base-content"
  h.textContent = title || "Attachment"

  const close = document.createElement("button")
  close.type = "button"
  close.className = "btn btn-ghost btn-sm"
  close.textContent = "Close"

  const body = document.createElement("div")
  body.className = "min-h-0 flex-1 overflow-auto bg-slate-950 p-3"
  body.addEventListener("contextmenu", (event) => event.preventDefault())

  if ((mime || "").startsWith("image/")) {
    const img = document.createElement("img")
    img.src = url
    img.alt = title || "Image attachment"
    img.draggable = false
    img.className = "mx-auto max-h-[78vh] max-w-full object-contain"
    body.appendChild(img)
  } else {
    const frame = document.createElement("iframe")
    frame.src = `${url}#toolbar=0&navpanes=0&scrollbar=1`
    frame.title = title || "PDF attachment"
    frame.className = "h-[78vh] w-full rounded bg-base-100"
    body.appendChild(frame)
  }

  const cleanup = () => {
    URL.revokeObjectURL(url)
    document.removeEventListener("keydown", onKeydown)
    overlay.remove()
  }
  const onKeydown = (event) => {
    if (event.key === "Escape") cleanup()
  }

  close.addEventListener("click", cleanup)
  overlay.addEventListener("click", (event) => {
    if (event.target === overlay) cleanup()
  })
  document.addEventListener("keydown", onKeydown)

  header.appendChild(h)
  header.appendChild(close)
  panel.appendChild(header)
  panel.appendChild(body)
  overlay.appendChild(panel)
  document.body.appendChild(overlay)
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
    this.threadId = this.el.id
    this.pinnedToBottom = true
    this.hasMore = () => {
      const value = this.el.dataset.hasMore
      return value === "" || value === "true"
    }
    this.loadMore = () => {
      if (this.loadingMore || !this.hasMore()) return

      this.loadingMore = true
      this.beforeLoadHeight = this.el.scrollHeight
      this.pushEvent("load_more_messages", {})
    }
    this.onScroll = () => {
      const distanceFromBottom =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.pinnedToBottom = distanceFromBottom <= 48

      if (this.loadingMore || !this.hasMore()) return
      if (this.el.scrollTop > 48) return

      this.loadMore()
    }
    this.onClick = (event) => {
      if (!event.target.closest("[data-role='load-more-messages']")) return
      if (this.loadingMore || !this.hasMore()) return

      // The button owns the LiveView event; record the pre-update height here
      // so updated() can preserve the user's viewport after older rows arrive.
      this.loadingMore = true
      this.beforeLoadHeight = this.el.scrollHeight
    }
    this.el.addEventListener("scroll", this.onScroll)
    this.el.addEventListener("click", this.onClick)
    this.handleEvent("scroll_to_bottom", ({thread_id}) => {
      if (thread_id !== this.el.id) return
      this.pinnedToBottom = true
      this.toBottom()
    })
    this.mutationObserver = new MutationObserver(() => {
      if (!this.loadingMore && this.pinnedToBottom) this.toBottom()
    })
    this.mutationObserver.observe(this.el, {childList: true, subtree: true})
    this.toBottom()
  },
  updated() {
    const threadChanged = this.threadId !== this.el.id
    this.threadId = this.el.id

    if (threadChanged) {
      this.loadingMore = false
      this.pinnedToBottom = true
      this.toBottom()
      return
    }

    if (this.loadingMore) {
      requestAnimationFrame(() => {
        const delta = this.el.scrollHeight - this.beforeLoadHeight
        this.el.scrollTop = this.el.scrollTop + delta
        this.loadingMore = false
      })
    } else if (this.pinnedToBottom) {
      this.toBottom()
    }
  },
  destroyed() {
    if (this.onScroll) this.el.removeEventListener("scroll", this.onScroll)
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.mutationObserver) this.mutationObserver.disconnect()
    clearTimeout(this.scrollRetry)
  },
  toBottom() {
    // Let decrypted bubbles and their media dimensions paint before measuring.
    const scroll = () => {
      requestAnimationFrame(() => {
        this.el.scrollTop = this.el.scrollHeight
        this.el.querySelector("[data-role='thread-end']")?.scrollIntoView({block: "end"})
      })
    }

    requestAnimationFrame(scroll)
    clearTimeout(this.scrollRetry)
    this.scrollRetry = setTimeout(scroll, 120)
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
      if (this.expired) return
      btn.disabled = true
      try {
        const permission = await Notification.requestPermission()
        if (permission !== "granted") {
          if (permission === "denied") {
            throw new Error(
              "Notifications are blocked for this site. Open the browser's site settings, allow Notifications, then reload this page."
            )
          }

          throw new Error("notification permission was not granted")
        }

        say("Registering service worker…")
        await navigator.serviceWorker.register("/sw.js")
        const registration = await navigator.serviceWorker.ready

        say("Subscribing…")
        const applicationServerKey = urlB64ToBytes(el.dataset.vapidKey)
        let subscription = await registration.pushManager.getSubscription()

        // A subscription is bound to the VAPID key used to create it. If the
        // instance was restored from a backup or its key was regenerated,
        // discard the stale browser subscription before creating a new one.
        const existingKey = subscription?.options?.applicationServerKey
        if (subscription && existingKey && !sameBytes(existingKey, applicationServerKey)) {
          say("Refreshing an old push subscriptionâ€¦")
          await subscription.unsubscribe()
          subscription = null
        }

        subscription ||= await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey,
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

function sameBytes(a, b) {
  const left = new Uint8Array(a)
  if (left.length !== b.length) return false
  return left.every((value, index) => value === b[index])
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

// The server stores only the wrapped secret key. This status is therefore
// resolved locally from the browser session cache and never sends key data
// over the LiveView socket.
export const AccountStatus = {
  mounted() {
    this.renderIdentityStatus()
  },
  updated() {
    this.renderIdentityStatus()
  },
  renderIdentityStatus() {
    const status = this.el.querySelector("[data-role=identity-status]")
    if (!status) return

    const hasIdentity = this.el.dataset.hasIdentity === "true"
    const unlocked = hasIdentity && Boolean(getSecretKey(this.el.dataset.userId))
    const label = !hasIdentity ? "Not configured" : unlocked ? "Unlocked" : "Locked"
    const tone = !hasIdentity ? "badge-neutral" : unlocked ? "badge-success" : "badge-warning"

    status.textContent = label
    status.classList.remove("badge-neutral", "badge-success", "badge-warning")
    status.classList.add(tone)
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
    this.recordedAudio = []
    this.textEl = this.el.querySelector("[data-role=text]")

    this.onTextKeydown = (e) => {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing) return
      e.preventDefault()
      if (!e.repeat) this.send().catch((err) => showError(this.el, err.message))
    }

    this.onComposerClick = (e) => {
      const optionsToggle = e.target.closest("[data-role=toggle-options]")
      if (optionsToggle && this.el.contains(optionsToggle)) {
        e.preventDefault()
        const options = this.el.querySelector("[data-role=message-options]")
        if (!options) return

        options.classList.toggle("hidden")
        optionsToggle.classList.toggle("bg-primary/10")
        optionsToggle.classList.toggle("text-primary")
        return
      }

      const toggle = e.target.closest("[data-role=emoji-toggle]")
      if (toggle && this.el.contains(toggle)) {
        e.preventDefault()
        e.stopPropagation()
        this.captureEmojiElements()
        this.setEmojiMenuOpen(this.emojiMenu.classList.contains("hidden"))
        return
      }

      const audioToggle = e.target.closest("[data-role=audio-toggle]")
      if (audioToggle && this.el.contains(audioToggle)) {
        e.preventDefault()
        this.toggleAudioRecording().catch((err) => showError(this.el, err.message))
        return
      }

      const discardAudio = e.target.closest("[data-role=discard-audio]")
      if (discardAudio && this.el.contains(discardAudio)) {
        e.preventDefault()
        this.discardAudio(parseInt(discardAudio.dataset.index))
      }
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
    if (this.textEl) this.textEl.addEventListener("keydown", this.onTextKeydown)

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
    this.stopMediaTracks()
    if (this.onComposerClick) this.el.removeEventListener("click", this.onComposerClick)
    if (this.onDocumentClick) document.removeEventListener("click", this.onDocumentClick)
    if (this.onDocumentKeydown) document.removeEventListener("keydown", this.onDocumentKeydown)
    if (this.textEl) this.textEl.removeEventListener("keydown", this.onTextKeydown)
    if (this.emojiMenu && this.emojiMenu.parentElement === document.body) this.emojiMenu.remove()
    this.recordedAudio.forEach((entry) => URL.revokeObjectURL(entry.url))
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

  async toggleAudioRecording() {
    if (this.mediaRecorder && this.mediaRecorder.state === "recording") {
      this.mediaRecorder.stop()
      this.setAudioStatus("Finishing recording...")
      return
    }

    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
      throw new Error("Audio recording is not supported in this browser.")
    }

    const mimeType = preferredAudioMime()
    const stream = await navigator.mediaDevices.getUserMedia({audio: true})
    const recorder = new MediaRecorder(stream, mimeType ? {mimeType} : undefined)
    const chunks = []
    const startedAt = Date.now()

    recorder.addEventListener("dataavailable", (event) => {
      if (event.data && event.data.size > 0) chunks.push(event.data)
    })

    recorder.addEventListener("stop", () => {
      this.stopMediaTracks()
      const type = recorder.mimeType || mimeType || "audio/webm"
      const blob = new Blob(chunks, {type})
      if (blob.size === 0) {
        this.setAudioStatus("Recording was empty.")
        return
      }

      const extension = type.includes("mp4") ? "m4a" : type.includes("ogg") ? "ogg" : "webm"
      const durationMs = Date.now() - startedAt
      const name = `voice-message-${new Date().toISOString().replace(/[:.]/g, "-")}.${extension}`
      const file = new File([blob], name, {type})
      this.recordedAudio.push({file, url: URL.createObjectURL(blob), durationMs})
      this.renderAudioPreview()
      this.setAudioStatus("Voice message ready to send.")
    })

    this.audioStream = stream
    this.mediaRecorder = recorder
    recorder.start()
    this.setAudioStatus("Recording... click the microphone again to stop.")
  },

  stopMediaTracks() {
    if (!this.audioStream) return
    this.audioStream.getTracks().forEach((track) => track.stop())
    this.audioStream = null
  },

  setAudioStatus(message) {
    const status = this.el.querySelector("[data-role=audio-status]")
    if (!status) return
    status.textContent = message
    status.classList.toggle("hidden", !message)
  },

  renderAudioPreview() {
    const preview = this.el.querySelector("[data-role=audio-preview]")
    if (!preview) return
    preview.textContent = ""

    this.recordedAudio.forEach((entry, index) => {
      const row = document.createElement("div")
      row.className = "flex items-center gap-2 rounded-lg bg-base-200 px-3 py-2"

      const audio = document.createElement("audio")
      audio.controls = true
      audio.src = entry.url
      audio.className = "min-w-0 flex-1"

      const btn = document.createElement("button")
      btn.type = "button"
      btn.dataset.role = "discard-audio"
      btn.dataset.index = index.toString()
      btn.className = "btn btn-ghost btn-xs"
      btn.textContent = "Remove"

      row.appendChild(audio)
      row.appendChild(btn)
      preview.appendChild(row)
    })
  },

  discardAudio(index) {
    const entry = this.recordedAudio[index]
    if (!entry) return
    URL.revokeObjectURL(entry.url)
    this.recordedAudio.splice(index, 1)
    this.renderAudioPreview()
    this.setAudioStatus(this.recordedAudio.length > 0 ? "Voice message ready to send." : "")
  },

  clearAudioRecordings() {
    this.recordedAudio.forEach((entry) => URL.revokeObjectURL(entry.url))
    this.recordedAudio = []
    this.renderAudioPreview()
    this.setAudioStatus("")
  },

  async send() {
    if (this.sending) return

    const form = this.el
    const {userId, myKey, kind} = form.dataset
    if (this.mediaRecorder && this.mediaRecorder.state === "recording") {
      throw new Error("Stop recording before sending.")
    }

    const mySecret = getSecretKey(userId)
    if (!mySecret) {
      window.location.assign(`/keys?return_to=${encodeURIComponent(currentLocationPath())}`)
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
    const includeSelf = !!form.querySelector("input[name='self']:checked, input[name='self'][type='hidden']")
    if (friendIds.length + groupIds.length === 0 && !includeSelf) {
      throw new Error("Pick at least one recipient.")
    }

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
    const recordedAudio = this.recordedAudio || []
    if (!text && files.length === 0 && recordedAudio.length === 0 && Object.keys(extra).length === 0) {
      throw new Error("Nothing to send.")
    }

    const btn = form.querySelector("button[type=submit]")
    this.sending = true
    if (btn) btn.disabled = true
    const originalLabel = btn?.textContent
    const busy = (label) => {
      if (btn) btn.textContent = label
    }

    try {
      busy("Resolving recipients…")
      const {recipients, missing_keys} = await this.pushWithReply("resolve_recipients", {
        friend_ids: friendIds,
        group_ids: groupIds,
        include_self: includeSelf,
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
      for (const [i, entry] of recordedAudio.entries()) {
        busy(`Encrypting voice message ${i + 1}/${recordedAudio.length}...`)
        attachments.push(
          await encryptAndUpload(entry.file, {
            name: entry.file.name,
            mime: entry.file.type,
            size: entry.file.size,
            durationMs: entry.durationMs,
          })
        )
      }

      // recipient handles ride inside the encrypted payload so group
      // messages can show all participants after decryption
      const to = recipients.map((r) => r.handle || `@${r.username}`)
      const payload = {v: 1, kind, text, attachments, to, sent_at: new Date().toISOString(), ...extra}
      const ttl = parseInt(form.querySelector("[data-role=ttl]")?.value || "", 10)
      const maxDisplays = parseInt(form.querySelector("[data-role=max-displays]")?.value || "", 10)
      const messageOptions = {}
      if (Number.isInteger(ttl) && ttl > 0) {
        messageOptions.expires_at = new Date(Date.now() + ttl * 1000).toISOString()
      }
      if (Number.isInteger(maxDisplays) && maxDisplays > 0) {
        messageOptions.max_displays = maxDisplays
      }

      busy("Encrypting…")
      const envelopes = recipients.map((r) => ({
        recipient_id: r.id,
        ...sealFor(r.public_key, payload, mySecret),
      }))
      // Self-copy so our own history stays readable.
      if (!recipients.some((r) => String(r.id) === String(userId))) {
        envelopes.push({recipient_id: parseInt(userId), ...sealFor(myKey, payload, mySecret)})
      }

      busy("Sending…")
      await this.pushWithReply("send_batch", {kind, envelopes, ...messageOptions})

      form.reset()
      this.clearAudioRecordings()
      const err = form.querySelector("[data-role=error]")
      if (err) err.classList.add("hidden")
    } finally {
      this.sending = false
      if (btn) {
        btn.disabled = false
        btn.textContent = originalLabel
      }
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
    this.displayRecorded = false
    this.expired = false
    this.expiryTimer = null
    this.render()
  },

  render() {
    const {userId, peerKey, ciphertext, nonce, kind} = this.el.dataset
    this.scheduleExpiry()
    if (this.expired) return

    const mySecret = getSecretKey(userId)

    this.el.textContent = ""

    if (!mySecret) {
      const a = document.createElement("a")
      a.href = `/keys?return_to=${encodeURIComponent(currentLocationPath())}`
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

    this.el.veejrPayload = payload
    this.recordDisplay()

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
      if (previewableMedia(att)) {
        this.renderMediaAttachment(att)
        continue
      }

      if ((att.mime || "").startsWith("audio/")) {
        this.renderAudioAttachment(att)
        continue
      }

      const btn = document.createElement("button")
      btn.className = "btn btn-outline btn-xs mt-1 mr-1"
      btn.textContent = `📎 ${att.name || "attachment"} (${Math.ceil((att.size || 0) / 1024)} KB)`
      btn.addEventListener("click", () =>
        (this.expired
          ? Promise.reject(new Error("This message has expired."))
          : downloadAttachment(att)
        ).catch((err) => (btn.textContent = `⚠ ${err.message}`))
      )
      this.el.appendChild(btn)
    }
  },

  renderMediaAttachment(att) {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "btn btn-outline btn-xs mt-1 mr-1"
    const mime = attachmentMime(att)
    const kind = mime.startsWith("image/") ? "Image" : "PDF"
    btn.textContent = `View ${kind}: ${att.name || "attachment"}`
    btn.addEventListener("click", async () => {
      if (this.expired) return
      btn.disabled = true
      const original = btn.textContent
      btn.textContent = `Opening ${kind.toLowerCase()}...`
      try {
        const blob = await decryptAttachmentBlob(att)
        if (this.expired) throw new Error("This message has expired.")
        showMediaModal({blob, title: att.name, mime})
        btn.textContent = original
      } catch (err) {
        btn.textContent = `Could not open ${kind.toLowerCase()}: ${err.message}`
      } finally {
        btn.disabled = false
      }
    })
    this.el.appendChild(btn)
  },

  renderAudioAttachment(att) {
    const wrap = document.createElement("div")
    wrap.className = "mt-2 rounded-2xl bg-black/5 p-2"

    const label = document.createElement("p")
    label.className = "mb-1 text-xs opacity-70"
    label.textContent = `Voice message (${Math.ceil((att.size || 0) / 1024)} KB)`

    const status = document.createElement("p")
    status.className = "text-xs opacity-70"
    status.textContent = "Loading voice message..."

    wrap.append(label, status)
    this.el.appendChild(wrap)

    this.loadAudioAttachment(att, wrap, status).catch((err) => {
      if (this.expired) return
      status.className = "text-xs text-error"
      status.textContent = `Could not load voice message: ${err.message}`
      wrap.appendChild(this.audioDownloadButton(att))
    })
  },

  async loadAudioAttachment(att, wrap, status) {
    const blob = await decryptAttachmentBlob(att)
    if (this.expired) return
    const url = URL.createObjectURL(blob)
    const mime = attachmentMime(att) || blob.type || "audio/webm"

    const audio = document.createElement("audio")
    audio.controls = true
    audio.preload = "metadata"
    audio.className = "w-full max-w-xs"

    const source = document.createElement("source")
    source.src = url
    source.type = mime
    audio.appendChild(source)

    const fallback = document.createElement("a")
    fallback.href = url
    fallback.download = att.name || "voice-message"
    fallback.className = "link text-xs"
    fallback.textContent = "Download voice message"
    audio.appendChild(fallback)

    audio.addEventListener(
      "error",
      () => {
        status.className = "text-xs text-error"
        status.textContent = "This browser cannot play this voice format."
        if (!status.isConnected) wrap.appendChild(status)
        wrap.appendChild(fallback.cloneNode(true))
      },
      {once: true}
    )

    status.remove()
    wrap.appendChild(audio)

    this.el.addEventListener(
      "phx:remove",
      () => {
        URL.revokeObjectURL(url)
      },
      {once: true}
    )
  },

  audioDownloadButton(att) {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "btn btn-outline btn-xs mt-2"
    btn.textContent = "Download voice message"
    btn.addEventListener("click", () =>
      (this.expired
        ? Promise.reject(new Error("This message has expired."))
        : downloadAttachment(att)
      ).catch((err) => {
        btn.textContent = `Could not download: ${err.message}`
      })
    )
    return btn
  },

  async recordDisplay() {
    if (this.displayRecorded || !this.el.dataset.publicId) return
    this.displayRecorded = true

    try {
      await pushWithReply(this, "message_displayed", {id: this.el.dataset.publicId})
    } catch {
      // Display accounting should never block reading a message.
    }
  },

  scheduleExpiry() {
    if (this.expiryTimer) clearTimeout(this.expiryTimer)

    const expiresAt = Date.parse(this.el.dataset.expiresAt || "")
    if (!Number.isFinite(expiresAt)) return

    const delay = expiresAt - Date.now()
    if (delay <= 0) {
      this.expire()
      return
    }

    this.expiryTimer = setTimeout(() => this.expire(), delay)
  },

  expire() {
    if (this.expired) return
    this.expired = true
    this.el.veejrPayload = null
    this.el.textContent = ""

    const p = document.createElement("p")
    p.className = "text-sm opacity-60"
    p.textContent = "This message has expired."
    this.el.appendChild(p)
  },

  destroyed() {
    if (this.expiryTimer) clearTimeout(this.expiryTimer)
  },
}

export const MessageBubble = {
  mounted() {
    const edit = this.el.querySelector("[data-role=edit-message]")
    if (!edit) return

    edit.addEventListener("click", () => {
      this.openEditor().catch((err) => window.alert(err.message))
    })
  },

  async openEditor() {
    if (this.editor) {
      this.editor.querySelector("textarea").focus()
      return
    }

    const decryptEl = this.el.querySelector("[phx-hook='Decrypt'], [data-peer-key]")
    const payload = decryptEl && decryptEl.veejrPayload
    if (!payload) throw new Error("Unlock this message before editing it.")
    if (payload.attachments && payload.attachments.length > 0) {
      throw new Error("Messages with attachments cannot be edited yet.")
    }

    const publicId = decryptEl.dataset.publicId
    const {copies} = await pushWithReply(this, "prepare_edit", {id: publicId})
    const textarea = document.createElement("textarea")
    textarea.className = "mt-2 w-full min-w-64 resize-none rounded-2xl border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content shadow-sm outline-none focus:ring-2 focus:ring-primary/30"
    textarea.rows = 3
    textarea.value = payload.text || ""

    const save = document.createElement("button")
    save.type = "button"
    save.className = "rounded-full bg-primary px-3 py-1.5 text-xs font-medium text-primary-content transition hover:bg-primary/90"
    save.textContent = "Save"

    const cancel = document.createElement("button")
    cancel.type = "button"
    cancel.className = "rounded-full px-3 py-1.5 text-xs font-medium opacity-70 transition hover:bg-base-200 hover:opacity-100"
    cancel.textContent = "Cancel"

    const actions = document.createElement("div")
    actions.className = "mt-2 flex justify-end gap-2"
    actions.append(cancel, save)

    const editor = document.createElement("div")
    editor.className = "max-w-[78%]"
    editor.append(textarea, actions)
    this.el.appendChild(editor)
    this.editor = editor
    textarea.focus()

    cancel.addEventListener("click", () => this.closeEditor())
    save.addEventListener("click", async () => {
      const text = textarea.value.trim()
      if (!text) return window.alert("Message text cannot be empty.")

      const mySecret = getSecretKey(decryptEl.dataset.userId)
      if (!mySecret) throw new Error("Unlock your keys before editing.")

      save.disabled = true
      save.textContent = "Saving..."

      try {
        const nextPayload = {...payload, text, edited_at: new Date().toISOString()}
        const envelopes = copies.map((copy) => ({
          public_id: copy.public_id,
          ...sealFor(copy.public_key, nextPayload, mySecret),
        }))
        await pushWithReply(this, "edit_batch", {id: publicId, envelopes})
        decryptEl.dataset.ciphertext = envelopes.find((entry) => entry.public_id === publicId)?.ciphertext || decryptEl.dataset.ciphertext
        decryptEl.dataset.nonce = envelopes.find((entry) => entry.public_id === publicId)?.nonce || decryptEl.dataset.nonce
        decryptEl.veejrPayload = nextPayload
        decryptEl.textContent = ""
        const p = document.createElement("p")
        p.className = "whitespace-pre-wrap"
        p.textContent = text
        decryptEl.appendChild(p)
        this.closeEditor()
      } finally {
        save.disabled = false
        save.textContent = "Save"
      }
    })
  },

  closeEditor() {
    if (this.editor) this.editor.remove()
    this.editor = null
  },
}

export const AutoDismissFlash = {
  mounted() {
    const ms = parseInt(this.el.dataset.autoDismissMs || "1000", 10)
    this.timer = setTimeout(() => {
      if (this.el.isConnected) this.el.click()
    }, Number.isInteger(ms) && ms >= 0 ? ms : 1000)
  },

  destroyed() {
    if (this.timer) clearTimeout(this.timer)
  },
}

export const PasswordVisibility = {
  mounted() {
    const input = this.el.querySelector("input[type=password]")
    const toggle = this.el.querySelector("[data-role=password-visibility-toggle]")
    const icon = this.el.querySelector("[data-role=password-visibility-icon] > span")

    if (!input || !toggle || !icon) return

    const secretLabel = toggle.dataset.secretLabel || "password"

    toggle.addEventListener("click", () => {
      const showing = input.type === "text"
      input.type = showing ? "password" : "text"
      toggle.setAttribute("aria-pressed", String(!showing))
      toggle.setAttribute("aria-label", `${showing ? "Show" : "Hide"} ${secretLabel}`)
      icon.classList.toggle("hero-eye", showing)
      icon.classList.toggle("hero-eye-slash", !showing)
    })
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
  AccountStatus,
  InstallApp,
  Composer,
  Decrypt,
  MessageBubble,
  AutoDismissFlash,
  PasswordVisibility,
  ReplyTo,
  ScrollBottom,
  VeejrMap,
}
