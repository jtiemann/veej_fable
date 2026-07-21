// 1:1 audio/video calls over WebRTC.
//
// Media flows peer-to-peer (DTLS-SRTP); this hook only exchanges signaling
// through the server, and every signaling payload (SDP, ICE) is sealed with
// nacl.box between the two participants' pinned identity keys before it
// leaves the browser. The server relays ciphertext it cannot read or alter,
// so it cannot substitute DTLS fingerprints to man-in-the-middle a call.

import {getSecretKey, sealFor, openFrom} from "./crypto.js"

const MICROPHONE_CONSTRAINTS = {
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
}

const CAMERA_CONSTRAINTS = {
  width: {ideal: 1280, max: 1280},
  height: {ideal: 720, max: 720},
  frameRate: {ideal: 30, max: 30},
}

export const VIDEO_PROFILES = [
  {label: "HD", maxBitrate: 1_500_000, maxFramerate: 30, scaleResolutionDownBy: 1},
  {label: "Balanced", maxBitrate: 800_000, maxFramerate: 30, scaleResolutionDownBy: 1.5},
  {label: "Data saver", maxBitrate: 350_000, maxFramerate: 30, scaleResolutionDownBy: 2},
]

export function nextVideoProfileIndex(current, quality, goodSamples, degradedSamples) {
  const downgradeAfter = quality === "poor" ? 2 : 3

  if (quality !== "good" && degradedSamples >= downgradeAfter) {
    return Math.min(current + 1, VIDEO_PROFILES.length - 1)
  }

  if (quality === "good" && goodSamples >= 10) return Math.max(current - 1, 0)
  return current
}

export function classifyCallQuality({loss = 0, rtt = 0, jitter = 0, bitrate} = {}) {
  if (loss >= 0.08 || rtt >= 0.6 || jitter >= 0.08 || (bitrate && bitrate < 150_000)) {
    return "poor"
  }

  if (loss >= 0.03 || rtt >= 0.3 || jitter >= 0.04 || (bitrate && bitrate < 400_000)) {
    return "unstable"
  }

  return "good"
}

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
    this.restartAttempts = 0
    this.maxRestartAttempts = 2
    this.restartInProgress = false
    this.previousInbound = null
    this.videoProfileIndex = 0
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
    this.remoteSharing = false
    this.remoteFitMode = "contain"
    this.popoutWindow = null
    this.popoutVideo = null
    this.remoteVideo = this.el.querySelector("[data-role=remote-video]")
    this.localVideo = this.el.querySelector("[data-role=local-video]")
    this.remoteShareStatus = this.el.querySelector("[data-role=remote-share-status]")
    this.setupVideo = this.el.querySelector("[data-role=setup-video]")
    this.setupEl = this.el.querySelector("[data-role=device-setup]")
    this.statusEl = this.el.querySelector("[data-role=call-status]")
    this.qualityEl = this.el.querySelector("[data-role=call-quality]")
    this.noticeEl = this.el.querySelector("[data-role=call-notice]")
    this.mediaReady = new Promise((resolve) => {
      this.resolveMediaReady = resolve
    })

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
    this.deviceChangeHandler = () => this.refreshDeviceChoices({recoverMissing: true})
    if (navigator.mediaDevices && navigator.mediaDevices.addEventListener) {
      navigator.mediaDevices.addEventListener("devicechange", this.deviceChangeHandler)
    }
    // Negotiation awaits this promise: building the peer connection before
    // the user confirms their preview would create a receive-only session or
    // send from a device they did not mean to use.
    this.acquireMedia()
  },

  destroyed() {
    this.clearRecoveryTimers()
    this.stopQualityMonitoring()
    clearTimeout(this.noticeTimer)
    if (navigator.mediaDevices && navigator.mediaDevices.removeEventListener) {
      navigator.mediaDevices.removeEventListener("devicechange", this.deviceChangeHandler)
    }
    if (this.fullscreenChangeHandler) {
      document.removeEventListener("fullscreenchange", this.fullscreenChangeHandler)
      document.removeEventListener("webkitfullscreenchange", this.fullscreenChangeHandler)
    }
    this.closeSharePopout()
    if (document.pictureInPictureElement === this.remoteVideo && document.exitPictureInPicture) {
      document.exitPictureInPicture().catch(() => {})
    }
    if (this.screenTrack) this.screenTrack.stop()
    if (this.localStream) this.localStream.getTracks().forEach((t) => t.stop())
    if (this.pc) this.pc.close()
  },

  async acquireMedia() {
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia({
        audio: MICROPHONE_CONSTRAINTS,
        video: CAMERA_CONSTRAINTS,
      })
    } catch {
      try {
        this.localStream = await navigator.mediaDevices.getUserMedia({
          audio: MICROPHONE_CONSTRAINTS,
        })
        this.showError("No camera available — continuing with audio only.")
      } catch {
        try {
          this.localStream = await navigator.mediaDevices.getUserMedia({
            video: CAMERA_CONSTRAINTS,
          })
          this.showError("Microphone unavailable — continuing with video only.")
        } catch (err) {
          this.captureFailed(err)
          return false
        }
      }
    }

    this.setTrackContentHints(this.localStream)

    if (this.localVideo && this.localStream.getVideoTracks().length > 0) {
      this.localVideo.srcObject = this.localStream
    }
    if (this.setupVideo && this.localStream.getVideoTracks().length > 0) {
      this.setupVideo.srcObject = this.localStream
    }

    await this.refreshDeviceChoices()
    this.setSetupReady()
    return true
  },

  async refreshDeviceChoices({recoverMissing = false} = {}) {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices()
      this.cameras = devices.filter((d) => d.kind === "videoinput")
      this.microphones = devices.filter((d) => d.kind === "audioinput")
      this.populateDeviceSelect("camera-select", this.cameras, "Camera")
      this.populateDeviceSelect("microphone-select", this.microphones, "Microphone")

      const btn = this.el.querySelector("[data-role=switch-cam]")
      if (btn) btn.classList.toggle("hidden", this.cameras.length < 2)

      if (recoverMissing && this.localStream) await this.recoverMissingDevices()
    } catch {
      this.cameras = []
      this.microphones = []
    }
  },

  populateDeviceSelect(role, devices, fallbackLabel) {
    const select = this.el.querySelector(`[data-role=${role}]`)
    if (!select) return

    const kind = role === "camera-select" ? "video" : "audio"
    const track = this.localStream && this.localStream.getTracks().find((item) => item.kind === kind)
    const selectedId = track && track.getSettings().deviceId
    select.replaceChildren()

    if (devices.length === 0) {
      const option = document.createElement("option")
      option.textContent = `No ${fallbackLabel.toLowerCase()} available`
      option.value = ""
      select.appendChild(option)
      select.disabled = true
      return
    }

    devices.forEach((device, index) => {
      const option = document.createElement("option")
      option.value = device.deviceId
      option.textContent = device.label || `${fallbackLabel} ${index + 1}`
      option.selected = device.deviceId === selectedId
      select.appendChild(option)
    })
    select.disabled = false
  },

  async recoverMissingDevices() {
    for (const [kind, devices] of [
      ["audio", this.microphones],
      ["video", this.cameras],
    ]) {
      const track = this.localStream.getTracks().find((item) => item.kind === kind)
      const activeId = track && track.getSettings().deviceId
      const missing = track && !devices.some((device) => device.deviceId === activeId)
      if (!track || (track.readyState !== "ended" && !missing)) continue

      if (devices.length > 0) {
        await this.replaceInput(kind, devices[0].deviceId)
        this.say(`${kind === "audio" ? "Microphone" : "Camera"} changed automatically`)
      } else {
        this.showError(`${kind === "audio" ? "Microphone" : "Camera"} disconnected.`)
      }
    }
  },

  captureFailed(err) {
    const blocked = err && ["NotAllowedError", "PermissionDeniedError"].includes(err.name)
    const message = blocked
      ? "Camera and microphone access is blocked. Allow access in your browser's site settings, then retry."
      : `Could not access a microphone or camera: ${err.message}`

    this.showError(message)
    this.say("Waiting for device access")
    const retry = this.el.querySelector("[data-role=retry-media]")
    const complete = this.el.querySelector("[data-role=complete-setup]")
    if (retry) retry.classList.remove("hidden")
    if (complete) {
      complete.disabled = true
      complete.textContent = "Devices unavailable"
    }
  },

  setSetupReady() {
    this.clearError()
    const complete = this.el.querySelector("[data-role=complete-setup]")
    const retry = this.el.querySelector("[data-role=retry-media]")
    const empty = this.el.querySelector("[data-role=setup-video-empty]")
    const help = this.el.querySelector("[data-role=setup-help]")
    const hasVideo = this.localStream && this.localStream.getVideoTracks().length > 0
    const hasAudio = this.localStream && this.localStream.getAudioTracks().length > 0

    if (complete) {
      complete.disabled = false
      complete.textContent = this.joinedCall ? "Done" : "Join call"
    }
    if (retry) retry.classList.add("hidden")
    if (help && !this.joinedCall) {
      help.textContent = hasVideo
        ? hasAudio
          ? "Your preview stays on this device. Choose what you want to use, then join."
          : "No microphone is active. You can join with video only or choose another device."
        : "No camera is active. You can join with audio only or choose another device."
    }
    if (empty) {
      empty.classList.toggle("hidden", hasVideo)
      empty.classList.toggle("flex", !hasVideo)
    }
  },

  completeDeviceSetup() {
    if (!this.localStream || this.localStream.getTracks().length === 0) return
    if (this.setupEl) this.setupEl.classList.add("hidden")

    if (!this.joinedCall) {
      this.joinedCall = true
      if (this.resolveMediaReady) this.resolveMediaReady(true)
      this.resolveMediaReady = null
      this.say(this.role === "caller" ? "Ringing…" : "Ready — connecting…")
    }
  },

  openDeviceSetup() {
    if (!this.setupEl || !this.localStream) return
    const title = this.el.querySelector("[data-role=setup-title]")
    const help = this.el.querySelector("[data-role=setup-help]")
    if (title) title.textContent = this.joinedCall ? "Call devices" : "Check your devices"
    if (help) {
      help.textContent = this.joinedCall
        ? "Changes apply immediately and stay on this device."
        : "Your preview stays on this device. Choose what you want to use, then join."
    }
    this.setSetupReady()
    this.setupEl.classList.remove("hidden")
  },

  async retryCapture() {
    if (this.localStream) this.localStream.getTracks().forEach((track) => track.stop())
    this.localStream = null
    const retry = this.el.querySelector("[data-role=retry-media]")
    const complete = this.el.querySelector("[data-role=complete-setup]")
    if (retry) retry.classList.add("hidden")
    if (complete) {
      complete.disabled = true
      complete.textContent = "Preparing devices…"
    }
    this.clearError()
    await this.acquireMedia()
  },

  async replaceInput(kind, deviceId) {
    if (!deviceId || !this.localStream) return
    if (kind === "video" && this.screenTrack) {
      return this.showError("Stop screen sharing before changing cameras.")
    }

    const constraints =
      kind === "audio"
        ? {
            audio: {...MICROPHONE_CONSTRAINTS, deviceId: {exact: deviceId}},
            video: false,
          }
        : {
            audio: false,
            video: {...CAMERA_CONSTRAINTS, deviceId: {exact: deviceId}},
          }

    try {
      const stream = await navigator.mediaDevices.getUserMedia(constraints)
      const newTrack = stream.getTracks().find((track) => track.kind === kind)
      const oldTrack = this.localStream.getTracks().find((track) => track.kind === kind)
      if (!newTrack) throw new Error(`The selected ${kind} device did not provide a track.`)
      newTrack.contentHint = kind === "audio" ? "speech" : "motion"
      if (oldTrack) newTrack.enabled = oldTrack.enabled

      const sender =
        this.pc && this.pc.getSenders().find((item) => item.track && item.track.kind === kind)
      if (this.pc && !sender) {
        newTrack.stop()
        throw new Error(`A new ${kind} track can only be added before joining the call.`)
      }
      if (sender) await sender.replaceTrack(newTrack)

      if (oldTrack) {
        this.localStream.removeTrack(oldTrack)
        oldTrack.stop()
      }
      this.localStream.addTrack(newTrack)

      if (kind === "video") {
        await this.applyVideoProfile({announce: false})
        if (this.localVideo) this.localVideo.srcObject = this.localStream
        if (this.setupVideo) this.setupVideo.srcObject = this.localStream
      }

      this.clearError()
      await this.refreshDeviceChoices()
    } catch (err) {
      this.showError(`Could not change ${kind === "audio" ? "microphone" : "camera"}: ${err.message}`)
      await this.refreshDeviceChoices()
    }
  },

  setTrackContentHints(stream) {
    for (const track of stream.getAudioTracks()) track.contentHint = "speech"
    for (const track of stream.getVideoTracks()) track.contentHint = "motion"
  },

  // Shares the whole screen or one window (the browser's picker offers the
  // choice). The screen track replaces the outgoing camera track on the
  // existing sender — no renegotiation — and the camera comes back when
  // sharing stops, including via the browser's own "Stop sharing" bar.
  async toggleScreenShare() {
    if (this.screenTrack) return this.stopScreenShare()

    const cameraTrack = this.localStream && this.localStream.getVideoTracks()[0]
    const sender =
      this.pc && this.pc.getSenders().find((s) => s.track && s.track.kind === "video")

    if (!cameraTrack || !sender) {
      return this.showError("Screen sharing needs a connected call with video.")
    }

    let stream
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({video: true})
    } catch {
      return // picker dismissed — not an error
    }

    try {
      const track = stream.getVideoTracks()[0]
      track.contentHint = "detail"
      this.screenTrack = track
      track.addEventListener("ended", () => this.stopScreenShare())
      await sender.replaceTrack(track)
      await this.applyScreenShareProfile(sender)
      if (this.localVideo) this.localVideo.srcObject = stream
      this.setShareUi(true)
      this.sendSignal({kind: "share_state", sharing: true})
    } catch (err) {
      this.screenTrack = null
      stream.getTracks().forEach((t) => t.stop())
      this.showError(`Could not share the screen: ${err.message}`)
    }
  },

  async stopScreenShare() {
    const track = this.screenTrack
    if (!track) return
    this.screenTrack = null
    track.stop()

    const cameraTrack = this.localStream && this.localStream.getVideoTracks()[0]
    const sender =
      this.pc && this.pc.getSenders().find((s) => s.track && s.track.kind === "video")

    try {
      if (sender && cameraTrack) {
        await sender.replaceTrack(cameraTrack)
        await this.applyVideoProfile({announce: false})
      }
    } catch (err) {
      this.showError(`Could not restore the camera: ${err.message}`)
    }

    if (this.localVideo) this.localVideo.srcObject = this.localStream
    this.setShareUi(false)
    this.sendSignal({kind: "share_state", sharing: false})
  },

  // While sharing, the camera controls would silently fight the screen
  // track, so they sit disabled until sharing stops.
  setShareUi(sharing) {
    const share = this.el.querySelector("[data-role=share-screen]")
    if (share) share.textContent = sharing ? "🖥 Stop sharing" : "🖥 Share screen"

    for (const role of ["toggle-cam", "switch-cam"]) {
      const btn = this.el.querySelector(`[data-role=${role}]`)
      if (btn) btn.disabled = sharing
    }
  },

  // Swaps the outgoing video to the next camera without renegotiating: the
  // new track replaces the old one on the existing RTCRtpSender.
  async switchCamera() {
    if (this.screenTrack) return
    const oldTrack = this.localStream && this.localStream.getVideoTracks()[0]
    if (!oldTrack || !this.cameras || this.cameras.length < 2) return

    const currentId = oldTrack.getSettings().deviceId
    const index = this.cameras.findIndex((d) => d.deviceId === currentId)
    const next = this.cameras[(index + 1) % this.cameras.length]

    await this.replaceInput("video", next.deviceId)
  },

  // The caller starts negotiation only after the callee's page joined, so
  // no offer is ever sent into the void — and only after local capture has
  // settled, so the offer actually carries this side's tracks.
  async startAsCaller() {
    if (this.negotiating || this.pc) return
    this.negotiating = true
    const mediaAvailable = await this.mediaReady
    if (!mediaAvailable) {
      this.negotiating = false
      return
    }
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
    this.applyVideoProfile({announce: false})

    this.pc.ontrack = (event) => {
      if (this.remoteVideo && event.streams[0]) {
        this.remoteVideo.srcObject = event.streams[0]
        if (this.popoutVideo) this.popoutVideo.srcObject = event.streams[0]
        // Nudge playback in case the browser's autoplay policy paused it.
        this.remoteVideo.play().catch(() => {})
      }
    }

    this.pc.onicecandidate = (event) => {
      if (event.candidate) this.sendSignal({kind: "ice", candidate: event.candidate.toJSON()})
    }

    this.pc.onconnectionstatechange = () => {
      const state = this.pc.connectionState
      if (state === "connected") {
        this.clearRecoveryTimers()
        this.restartAttempts = 0
        this.say("Connected — end-to-end encrypted")
        this.startQualityMonitoring()
      }
    }

    this.pc.oniceconnectionstatechange = () => {
      const state = this.pc.iceConnectionState

      if (state === "checking") this.say("Connecting…")

      if (state === "disconnected") {
        this.say("Connection interrupted — reconnecting…")
        clearTimeout(this.disconnectTimer)
        this.disconnectTimer = setTimeout(() => this.requestIceRecovery(), 5_000)
      }

      if (state === "failed") this.requestIceRecovery()
    }
  },

  async onSignal(payload) {
    try {
      if (payload.kind === "offer") {
        if (!this.pc) {
          // Wait for capture before answering — an answer built without
          // local tracks would be receive-only and the caller would never
          // see or hear this side.
          const mediaAvailable = await this.mediaReady
          if (!mediaAvailable) return
          if (!this.pc) this.createPeer()
        }

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
      } else if (payload.kind === "restart_request" && this.role === "caller") {
        await this.restartConnection()
      } else if (payload.kind === "share_state") {
        this.setRemoteShareState(payload.sharing === true)
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

  clearRecoveryTimers() {
    clearTimeout(this.disconnectTimer)
    clearTimeout(this.restartTimer)
    this.disconnectTimer = null
    this.restartTimer = null
  },

  async requestIceRecovery() {
    if (!this.pc || this.pc.connectionState === "closed") return

    if (this.restartAttempts >= this.maxRestartAttempts) {
      this.clearRecoveryTimers()
      this.stopQualityMonitoring()
      this.say("Connection failed")
      return this.showError(
        "The call could not reconnect after two attempts. Check your connection and try again."
      )
    }

    if (this.role === "caller") {
      await this.restartConnection()
    } else {
      this.restartAttempts += 1
      this.say(`Reconnecting (attempt ${this.restartAttempts}/${this.maxRestartAttempts})…`)
      this.sendSignal({kind: "restart_request"})
      clearTimeout(this.restartTimer)
      this.restartTimer = setTimeout(() => this.requestIceRecovery(), 8_000)
    }
  },

  // Only the original caller creates restart offers. That fixed ownership
  // avoids offer glare when both browsers notice the same network change.
  async restartConnection() {
    if (
      !this.pc ||
      this.restartInProgress ||
      this.restartAttempts >= this.maxRestartAttempts ||
      this.pc.signalingState !== "stable"
    ) {
      return
    }

    this.restartInProgress = true
    this.restartAttempts += 1
    this.say(`Reconnecting (attempt ${this.restartAttempts}/${this.maxRestartAttempts})…`)

    try {
      this.pc.restartIce()
      const offer = await this.pc.createOffer({iceRestart: true})
      await this.pc.setLocalDescription(offer)
      this.sendSignal({kind: "offer", sdp: this.pc.localDescription.sdp, restart: true})
    } catch (err) {
      this.showError(`Could not restart the connection: ${err.message}`)
    } finally {
      this.restartInProgress = false
    }

    clearTimeout(this.restartTimer)
    this.restartTimer = setTimeout(() => this.requestIceRecovery(), 8_000)
  },

  startQualityMonitoring() {
    if (!this.pc || this.qualityTimer) return
    if (this.qualityEl) this.qualityEl.classList.remove("hidden")
    this.updateCallQuality()
    this.qualityTimer = setInterval(() => this.updateCallQuality(), 2_000)
  },

  stopQualityMonitoring() {
    clearInterval(this.qualityTimer)
    this.qualityTimer = null
    this.previousInbound = null
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
  },

  // WebRTC statistics stay in this browser. Only a coarse quality label is
  // rendered; no IP addresses, candidate details, or metrics reach Phoenix.
  async updateCallQuality() {
    if (!this.pc || !this.qualityEl || this.pc.connectionState !== "connected") return

    try {
      const stats = await this.pc.getStats()
      let pair
      let transport
      let received = 0
      let lost = 0
      let jitter = 0

      stats.forEach((report) => {
        if (report.type === "transport" && report.selectedCandidatePairId) transport = report
        if (report.type === "candidate-pair" && report.state === "succeeded" && report.nominated) {
          pair = report
        }
        if (report.type === "inbound-rtp" && !report.isRemote) {
          received += report.packetsReceived || 0
          lost += report.packetsLost || 0
          jitter = Math.max(jitter, report.jitter || 0)
        }
      })

      if (transport) pair = stats.get(transport.selectedCandidatePairId) || pair

      const previous = this.previousInbound
      const receivedDelta = previous ? Math.max(0, received - previous.received) : 0
      const lostDelta = previous ? Math.max(0, lost - previous.lost) : 0
      const packetDelta = receivedDelta + lostDelta
      const loss = packetDelta > 0 ? lostDelta / packetDelta : 0
      this.previousInbound = {received, lost}

      const localCandidate = pair && stats.get(pair.localCandidateId)
      const remoteCandidate = pair && stats.get(pair.remoteCandidateId)
      const relayed =
        (localCandidate && localCandidate.candidateType === "relay") ||
        (remoteCandidate && remoteCandidate.candidateType === "relay")
      const rtt = (pair && pair.currentRoundTripTime) || 0
      const bitrate = pair && pair.availableOutgoingBitrate
      const quality = classifyCallQuality({loss, rtt, jitter, bitrate})

      await this.observeCallQuality(quality)
      this.renderCallQuality(quality, relayed, {loss, rtt})
    } catch {
      // Stats availability differs across browsers; the call itself should
      // never be interrupted because a quality sample is unavailable.
    }
  },

  async observeCallQuality(quality) {
    if (this.screenTrack || !this.localStream || this.localStream.getVideoTracks().length === 0) {
      return
    }

    if (quality === "good") {
      this.goodQualitySamples += 1
      this.degradedQualitySamples = 0
    } else {
      this.degradedQualitySamples += 1
      this.goodQualitySamples = 0
    }

    const nextIndex = nextVideoProfileIndex(
      this.videoProfileIndex,
      quality,
      this.goodQualitySamples,
      this.degradedQualitySamples
    )
    if (nextIndex === this.videoProfileIndex) return

    const previousIndex = this.videoProfileIndex
    this.videoProfileIndex = nextIndex
    const applied = await this.applyVideoProfile({announce: true})
    if (!applied) this.videoProfileIndex = previousIndex
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
  },

  async applyVideoProfile({announce = false} = {}) {
    const sender =
      this.pc && this.pc.getSenders().find((item) => item.track && item.track.kind === "video")
    if (!sender || !sender.getParameters || !sender.setParameters) return false

    const profile = VIDEO_PROFILES[this.videoProfileIndex]

    try {
      const parameters = sender.getParameters()
      if (!parameters.encodings || parameters.encodings.length === 0) parameters.encodings = [{}]
      parameters.encodings[0].maxBitrate = profile.maxBitrate
      parameters.encodings[0].maxFramerate = profile.maxFramerate
      parameters.encodings[0].scaleResolutionDownBy = profile.scaleResolutionDownBy
      await sender.setParameters(parameters)

      if (announce) {
        const reduced = this.videoProfileIndex > 0
        this.showCallNotice(
          reduced
            ? `Video adjusted to ${profile.label.toLowerCase()} to keep audio clear.`
            : "Connection improved — HD video restored."
        )
      }
      return true
    } catch {
      // Some browser versions expose getParameters without allowing encoding
      // changes. The call continues at the browser's own selected quality.
      return false
    }
  },

  async applyScreenShareProfile(sender) {
    if (!sender || !sender.getParameters || !sender.setParameters) return

    try {
      const parameters = sender.getParameters()
      if (!parameters.encodings || parameters.encodings.length === 0) parameters.encodings = [{}]
      parameters.encodings[0].maxBitrate = 1_500_000
      parameters.encodings[0].maxFramerate = 15
      parameters.encodings[0].scaleResolutionDownBy = 1
      await sender.setParameters(parameters)
    } catch {
      // Keep sharing with browser defaults when sender tuning is unavailable.
    }
  },

  renderCallQuality(quality, relayed, {loss, rtt}) {
    const styles = {
      good: "border-success/40 bg-success/10 text-success",
      unstable: "border-warning/50 bg-warning/10 text-warning",
      poor: "border-error/50 bg-error/10 text-error",
    }

    this.qualityEl.className =
      `rounded-full border px-2 py-0.5 text-xs font-medium ${styles[quality]}`
    this.qualityEl.textContent =
      `${quality === "good" ? "Good" : quality === "unstable" ? "Unstable" : "Poor"}` +
      ` · ${relayed ? "relayed" : "direct"}` +
      (this.videoProfileIndex > 0 ? ` · ${VIDEO_PROFILES[this.videoProfileIndex].label}` : "")
    this.qualityEl.title =
      `Round trip ${Math.round(rtt * 1000)} ms · packet loss ${Math.round(loss * 100)}%` +
      ` · video ${VIDEO_PROFILES[this.videoProfileIndex].label}`
  },

  showCallNotice(text) {
    if (!this.noticeEl) return
    clearTimeout(this.noticeTimer)
    this.noticeEl.textContent = text
    this.noticeEl.classList.remove("hidden")
    this.noticeTimer = setTimeout(() => this.noticeEl.classList.add("hidden"), 5_000)
  },

  setRemoteShareState(sharing) {
    this.remoteSharing = sharing

    if (this.remoteShareStatus) {
      this.remoteShareStatus.classList.toggle("hidden", !sharing)
      this.remoteShareStatus.classList.toggle("inline-flex", sharing)
    }

    const popout = this.el.querySelector("[data-role=popout-share]")
    if (popout) popout.classList.toggle("hidden", !sharing)

    if (sharing) {
      this.setRemoteFit("contain")
      this.showCallNotice("The other person started sharing their screen.")
    } else {
      this.closeSharePopout()
      this.showCallNotice("Screen sharing stopped.")
    }
  },

  toggleRemoteFit() {
    this.setRemoteFit(this.remoteFitMode === "contain" ? "cover" : "contain")
  },

  setRemoteFit(mode) {
    this.remoteFitMode = mode
    if (this.remoteVideo) {
      this.remoteVideo.classList.toggle("object-contain", mode === "contain")
      this.remoteVideo.classList.toggle("object-cover", mode === "cover")
    }

    const label = this.el.querySelector("[data-role=fit-label]")
    if (label) label.textContent = mode === "contain" ? "Fill" : "Fit"

    const button = this.el.querySelector("[data-role=toggle-fit]")
    if (button) button.setAttribute("aria-pressed", String(mode === "cover"))
  },

  async toggleFullscreen() {
    try {
      const fullscreenElement = document.fullscreenElement || document.webkitFullscreenElement
      if (fullscreenElement) {
        if (document.exitFullscreen) await document.exitFullscreen()
        else if (document.webkitExitFullscreen) document.webkitExitFullscreen()
      } else if (this.el.requestFullscreen) {
        await this.el.requestFullscreen()
      } else if (this.el.webkitRequestFullscreen) {
        this.el.webkitRequestFullscreen()
      }
    } catch (err) {
      this.showCallNotice(`Fullscreen is unavailable: ${err.message}`)
    }
  },

  updateFullscreenUi() {
    const active =
      document.fullscreenElement === this.el || document.webkitFullscreenElement === this.el
    const label = this.el.querySelector("[data-role=fullscreen-label]")
    if (label) label.textContent = active ? "Exit fullscreen" : "Fullscreen"
  },

  async togglePictureInPicture() {
    if (!this.remoteVideo || !document.pictureInPictureEnabled) return

    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture()
      } else {
        if (!this.remoteVideo.srcObject) {
          return this.showCallNotice("Picture in picture is available once the call connects.")
        }
        await this.remoteVideo.play()
        await this.remoteVideo.requestPictureInPicture()
      }
    } catch (err) {
      this.showCallNotice(`Picture in picture is unavailable: ${err.message}`)
    }
  },

  updatePictureInPictureUi() {
    const label = this.el.querySelector("[data-role=pip-label]")
    if (label) {
      label.textContent =
        document.pictureInPictureElement === this.remoteVideo
          ? "Exit picture in picture"
          : "Picture in picture"
    }
  },

  openSharePopout() {
    if (!this.remoteSharing) {
      return this.showCallNotice("The pop-out is available while the other person is sharing.")
    }

    if (this.popoutWindow && !this.popoutWindow.closed) {
      this.popoutWindow.focus()
      return
    }

    const popup = window.open(
      "",
      `veejr-share-${this.el.dataset.callId}`,
      "popup=yes,width=1100,height=760,resizable=yes"
    )
    if (!popup) return this.showCallNotice("Allow pop-ups to open the shared screen.")

    popup.document.title = "Shared screen · veejr"
    popup.document.body.replaceChildren()
    popup.document.body.style.cssText =
      "margin:0;display:grid;place-items:center;width:100vw;height:100vh;overflow:hidden;background:#050505;"

    const video = popup.document.createElement("video")
    video.autoplay = true
    video.playsInline = true
    video.muted = true
    video.style.cssText = "width:100%;height:100%;object-fit:contain;background:#050505;"
    video.srcObject = this.remoteVideo && this.remoteVideo.srcObject
    popup.document.body.appendChild(video)

    this.popoutWindow = popup
    this.popoutVideo = video
    video.play().catch(() => {})
    popup.addEventListener("beforeunload", () => {
      this.popoutWindow = null
      this.popoutVideo = null
    })
  },

  closeSharePopout() {
    const popup = this.popoutWindow
    this.popoutWindow = null
    this.popoutVideo = null
    if (popup && !popup.closed) popup.close()
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

    const switchCam = this.el.querySelector("[data-role=switch-cam]")
    if (switchCam) {
      switchCam.addEventListener("click", () => this.switchCamera())
    }

    // Screen capture is a desktop-browser feature; phones hide the button.
    const share = this.el.querySelector("[data-role=share-screen]")
    if (share && navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia) {
      share.classList.remove("hidden")
      share.addEventListener("click", () => this.toggleScreenShare())
    }

    const fit = this.el.querySelector("[data-role=toggle-fit]")
    if (fit) fit.addEventListener("click", () => this.toggleRemoteFit())

    const fullscreen = this.el.querySelector("[data-role=toggle-fullscreen]")
    if (fullscreen && (this.el.requestFullscreen || this.el.webkitRequestFullscreen)) {
      fullscreen.classList.remove("hidden")
      fullscreen.addEventListener("click", () => this.toggleFullscreen())
      this.remoteVideo.addEventListener("dblclick", () => this.toggleFullscreen())
      this.fullscreenChangeHandler = () => this.updateFullscreenUi()
      document.addEventListener("fullscreenchange", this.fullscreenChangeHandler)
      document.addEventListener("webkitfullscreenchange", this.fullscreenChangeHandler)
    }

    const pip = this.el.querySelector("[data-role=toggle-pip]")
    if (pip && document.pictureInPictureEnabled && this.remoteVideo.requestPictureInPicture) {
      pip.classList.remove("hidden")
      pip.addEventListener("click", () => this.togglePictureInPicture())
      this.remoteVideo.addEventListener("enterpictureinpicture", () =>
        this.updatePictureInPictureUi()
      )
      this.remoteVideo.addEventListener("leavepictureinpicture", () =>
        this.updatePictureInPictureUi()
      )
    }

    const popout = this.el.querySelector("[data-role=popout-share]")
    if (popout) popout.addEventListener("click", () => this.openSharePopout())

    const complete = this.el.querySelector("[data-role=complete-setup]")
    if (complete) complete.addEventListener("click", () => this.completeDeviceSetup())

    const retry = this.el.querySelector("[data-role=retry-media]")
    if (retry) retry.addEventListener("click", () => this.retryCapture())

    const devices = this.el.querySelector("[data-role=open-devices]")
    if (devices) devices.addEventListener("click", () => this.openDeviceSetup())

    const microphone = this.el.querySelector("[data-role=microphone-select]")
    if (microphone) {
      microphone.addEventListener("change", (event) =>
        this.replaceInput("audio", event.target.value)
      )
    }

    const camera = this.el.querySelector("[data-role=camera-select]")
    if (camera) {
      camera.addEventListener("change", (event) =>
        this.replaceInput("video", event.target.value)
      )
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

  clearError() {
    const el = this.el.querySelector("[data-role=media-error]")
    if (el) {
      el.textContent = ""
      el.classList.add("hidden")
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
