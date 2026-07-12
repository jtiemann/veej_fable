import assert from "node:assert/strict"
import crypto from "node:crypto"
import fs from "node:fs"
import {createRequire} from "node:module"
import path from "node:path"
import {fileURLToPath} from "node:url"

const require = createRequire(import.meta.url)
const nacl = require("../assets/vendor/tweetnacl.min.js")
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const fixturePath = path.join(root, "protocol-fixtures", "v1.json")
const te = new TextEncoder()

const bytes = (hex) => new Uint8Array(Buffer.from(hex, "hex"))
const b64 = (value) => Buffer.from(value).toString("base64")

const senderSecret = bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
const recipientSecret = bytes("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
const wrapSalt = bytes("404142434445464748494a4b4c4d4e4f")
const wrapNonce = bytes("505152535455565758595a5b5c5d5e5f6061626364656667")
const boxNonce = bytes("707172737475767778797a7b7c7d7e7f8081828384858687")
const attachmentKey = bytes("909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
const attachmentNonce = bytes("b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7")
const passphrase = "veejr fixture 🔐"
const payloadJson =
  '{"v":1,"kind":"message","text":"Hello, Bob 👋","attachments":[],"to":["@bob@example.test"],"sent_at":"2026-07-12T14:00:00.000Z"}'
const attachmentPlaintext = te.encode("fixture attachment\n")

function buildFixture() {
  const sender = nacl.box.keyPair.fromSecretKey(senderSecret)
  const recipient = nacl.box.keyPair.fromSecretKey(recipientSecret)
  const wrappingKey = crypto.pbkdf2Sync(passphrase, wrapSalt, 310_000, 32, "sha256")
  const wrappedSecret = nacl.secretbox(sender.secretKey, wrapNonce, wrappingKey)
  const ciphertext = nacl.box(te.encode(payloadJson), boxNonce, recipient.publicKey, sender.secretKey)
  const attachmentCiphertext = nacl.secretbox(attachmentPlaintext, attachmentNonce, attachmentKey)

  return {
    schema: "org.veejr.protocol-fixtures",
    schema_version: 1,
    protocol: {api_version: 1, payload_version: 1},
    encoding: "standard-padded-base64",
    identity: {
      sender_secret_key: b64(sender.secretKey),
      sender_public_key: b64(sender.publicKey),
      recipient_secret_key: b64(recipient.secretKey),
      recipient_public_key: b64(recipient.publicKey),
    },
    wrapping: {
      passphrase,
      kdf: "PBKDF2-HMAC-SHA256",
      iterations: 310_000,
      salt: b64(wrapSalt),
      derived_key: b64(wrappingKey),
      algorithm: "XSalsa20-Poly1305",
      nonce: b64(wrapNonce),
      plaintext_secret_key: b64(sender.secretKey),
      wrapped_secret_key: b64(wrappedSecret),
    },
    envelope: {
      algorithm: "nacl.box",
      payload_json: payloadJson,
      nonce: b64(boxNonce),
      sender_secret_key: b64(sender.secretKey),
      sender_public_key: b64(sender.publicKey),
      recipient_secret_key: b64(recipient.secretKey),
      recipient_public_key: b64(recipient.publicKey),
      ciphertext: b64(ciphertext),
    },
    attachment: {
      algorithm: "nacl.secretbox",
      plaintext_utf8: "fixture attachment\n",
      key: b64(attachmentKey),
      nonce: b64(attachmentNonce),
      ciphertext: b64(attachmentCiphertext),
    },
  }
}

function verifyFixture(actual) {
  const expected = buildFixture()
  assert.deepEqual(actual, expected, "protocol fixture differs from deterministic source values")

  const fromB64 = (value) => new Uint8Array(Buffer.from(value, "base64"))
  const unwrapped = nacl.secretbox.open(
    fromB64(actual.wrapping.wrapped_secret_key),
    fromB64(actual.wrapping.nonce),
    fromB64(actual.wrapping.derived_key),
  )
  assert.equal(b64(unwrapped), actual.wrapping.plaintext_secret_key)

  const opened = nacl.box.open(
    fromB64(actual.envelope.ciphertext),
    fromB64(actual.envelope.nonce),
    fromB64(actual.envelope.sender_public_key),
    fromB64(actual.envelope.recipient_secret_key),
  )
  assert.equal(new TextDecoder().decode(opened), actual.envelope.payload_json)

  const attachment = nacl.secretbox.open(
    fromB64(actual.attachment.ciphertext),
    fromB64(actual.attachment.nonce),
    fromB64(actual.attachment.key),
  )
  assert.equal(new TextDecoder().decode(attachment), actual.attachment.plaintext_utf8)
}

const mode = process.argv[2] || "verify"

if (mode === "generate") {
  fs.mkdirSync(path.dirname(fixturePath), {recursive: true})
  fs.writeFileSync(fixturePath, `${JSON.stringify(buildFixture(), null, 2)}\n`)
  console.log(`generated ${path.relative(root, fixturePath)}`)
} else if (mode === "verify") {
  verifyFixture(JSON.parse(fs.readFileSync(fixturePath, "utf8")))
  console.log(`verified ${path.relative(root, fixturePath)}`)
} else {
  throw new Error(`unknown mode: ${mode}`)
}
