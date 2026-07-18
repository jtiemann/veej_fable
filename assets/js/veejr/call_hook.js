// 1:1 audio/video calls over WebRTC.
//
// Media flows peer-to-peer (DTLS-SRTP); this hook only exchanges signaling
// through the server, and every signaling payload (SDP, ICE) is sealed with
// nacl.box between the two participants' pinned identity keys before it
// leaves the browser. The server relays ciphertext it cannot read or alter,
// so it cannot substitute DTLS fingerprints to man-in-the-middle a call.

import {getSecretKey, sealFor, openFrom} from "./crypto.js"

export const CallSession = {
  mounted() {
    const {callId, role, userId, peerKey} = this.el.dataset
    this.role = role
    this.peerKey = peerKey
    this.mySecret = getSecretKey(userId)
    this.iceServers = JSON.parse(this.el.dataset.iceServers || "[]")
    this.pc = null
    this.localStream = null
    this.pendingIce = []
    this.remoteVideo = this.el.querySelector("[data-role=remote-video]")
    this.localVideo = this.el.querySelector("[data-role=local-video]")
    this.statusEl = this.el.querySelector("[data-role=call-status]")

    if (!this.mySecret) {
      return this.fail("🔒 Your keys are locked — unlock them and try the call again.")
    }

    this.handleEvent("call:peer_joined", () => {
      this.say("Connecting…")
      if (this.role === "caller") this.startAsCaller()
    })

    this.handleEvent("call:signal", ({ciphertext, nonce}) => {
      const payload = openFrom(ciphertext, nonce, this.peerKey, this.mySecret)
      if (!payload) return // tampered or stale — never act on unauthenticated signaling
      this.onSignal(payload)
    })

    this.setupControls()
    this.acquireMedia()
  },

  destroyed() {
    if (this.localStream) this.localStream.getTracks().forEach((t) => t.stop())
    if (this.pc) this.pc.close()
  },

  async acquireMedia() {
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia({audio: true, video: true})
    } catch {
      try {
        this.localStream = await navigator.mediaDevices.getUserMedia({audio: true})
        this.showError("No camera available — continuing with audio only.")
      } catch (err) {
        return this.fail(`Could not access microphone or camera: ${err.message}`)
      }
    }

    if (this.localVideo && this.localStream.getVideoTracks().length > 0) {
      this.localVideo.srcObject = this.localStream
    }
  },

  // The caller starts negotiation only after the callee's page joined, so
  // no offer is ever sent into the void.
  async startAsCaller() {
    if (this.pc) return
    this.createPeer()
    const offer = await this.pc.createOffer()
    await this.pc.setLocalDescription(offer)
    this.sendSignal({kind: "offer", sdp: this.pc.localDescription.sdp})
  },

  createPeer() {
    this.pc = new RTCPeerConnection({iceServers: this.iceServers})

    for (const track of this.localStream ? this.localStream.getTracks() : []) {
      this.pc.addTrack(track, this.localStream)
    }

    this.pc.ontrack = (event) => {
      if (this.remoteVideo && event.streams[0]) this.remoteVideo.srcObject = event.streams[0]
    }

    this.pc.onicecandidate = (event) => {
      if (event.candidate) this.sendSignal({kind: "ice", candidate: event.candidate.toJSON()})
    }

    this.pc.onconnectionstatechange = () => {
      const state = this.pc.connectionState
      if (state === "connected") this.say("Connected — end-to-end encrypted")
      if (state === "disconnected") this.say("Connection interrupted…")
      if (state === "failed") {
        this.showError(
          "Could not establish a direct connection between your networks. " +
            "The instance may need a TURN relay (see the operations guide)."
        )
        this.say("Connection failed")
      }
    }
  },

  async onSignal(payload) {
    try {
      if (payload.kind === "offer") {
        if (!this.pc) this.createPeer()
        await this.pc.setRemoteDescription({type: "offer", sdp: payload.sdp})
        const answer = await this.pc.createAnswer()
        await this.pc.setLocalDescription(answer)
        this.sendSignal({kind: "answer", sdp: this.pc.localDescription.sdp})
        await this.flushPendingIce()
      } else if (payload.kind === "answer") {
        if (!this.pc) return
        await this.pc.setRemoteDescription({type: "answer", sdp: payload.sdp})
        await this.flushPendingIce()
      } else if (payload.kind === "ice") {
        if (this.pc && this.pc.remoteDescription) {
          await this.pc.addIceCandidate(payload.candidate)
        } else {
          this.pendingIce.push(payload.candidate)
        }
      }
    } catch (err) {
      this.showError(`Call negotiation failed: ${err.message}`)
    }
  },

  async flushPendingIce() {
    while (this.pendingIce.length > 0) {
      await this.pc.addIceCandidate(this.pendingIce.shift())
    }
  },

  sendSignal(payload) {
    const sealed = sealFor(this.peerKey, payload, this.mySecret)
    this.pushEvent("signal", sealed)
  },

  setupControls() {
    const mic = this.el.querySelector("[data-role=toggle-mic]")
    const cam = this.el.querySelector("[data-role=toggle-cam]")

    if (mic) {
      mic.addEventListener("click", () => {
        const track = this.localStream && this.localStream.getAudioTracks()[0]
        if (!track) return
        track.enabled = !track.enabled
        mic.textContent = track.enabled ? "🎙 Mute" : "🎙 Unmute"
      })
    }

    if (cam) {
      cam.addEventListener("click", () => {
        const track = this.localStream && this.localStream.getVideoTracks()[0]
        if (!track) return
        track.enabled = !track.enabled
        cam.textContent = track.enabled ? "🎥 Camera off" : "🎥 Camera on"
      })
    }
  },

  say(text) {
    if (this.statusEl) this.statusEl.textContent = text
  },

  showError(text) {
    const el = this.el.querySelector("[data-role=media-error]")
    if (el) {
      el.textContent = text
      el.classList.remove("hidden")
    }
  },

  fail(text) {
    this.showError(text)
    this.say("Cannot start the call")
  },
}

// Incoming-call banner: rings in every open veejr tab via the LiveNotify
// push event. Accept and Decline are plain navigations, so this works from
// any page without a dedicated reply channel.
export function installRingBanner() {
  window.addEventListener("phx:veejr:ring", ({detail}) => {
    const id = `veejr-ring-${detail.call_id}`
    if (document.getElementById(id)) return

    const banner = document.createElement("div")
    banner.id = id
    banner.className =
      "fixed inset-x-0 top-4 z-[1200] mx-auto flex w-fit max-w-[92vw] items-center gap-4 rounded-full border border-base-300 bg-base-100 py-2 pl-5 pr-2 shadow-2xl"

    const label = document.createElement("span")
    label.className = "text-sm font-medium"
    label.textContent = `📞 ${detail.from} is calling…`

    const accept = document.createElement("a")
    accept.href = `/call/${detail.call_id}`
    accept.className = "btn btn-primary btn-sm rounded-full"
    accept.textContent = "Accept"

    const decline = document.createElement("a")
    decline.href = `/call/${detail.call_id}?reject=1`
    decline.className = "btn btn-ghost btn-sm rounded-full"
    decline.textContent = "Decline"

    banner.append(label, accept, decline)
    document.body.appendChild(banner)
    setTimeout(() => banner.remove(), 60_000)

    if ("Notification" in window && Notification.permission === "granted") {
      new Notification("veejr", {
        body: `${detail.from} is calling you.`,
        tag: `veejr-call-${detail.call_id}`,
      })
    }
  })
}

export default CallSession
