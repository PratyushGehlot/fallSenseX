#!/usr/bin/env node
/**
 * Dev-only OTA firmware uploader.
 *
 * Pushes a built ESP32 firmware .bin straight to Firebase Storage at
 * firmware/{deviceModel}/{version}.bin. This is the same path the
 * `onFirmwareUploaded` Cloud Function watches in production, so a local
 * push here triggers the exact same manifest + notification pipeline as
 * a real release - useful for testing OTA end-to-end without going
 * through an app store or CI release process.
 *
 * Usage:
 *   node upload_firmware.js --bin <path/to/firmware.bin> --version 1.2.0 \
 *        --model fallsensex --service-account <path/to/serviceAccountKey.json>
 *
 * The service account needs Storage Object Admin on the project's default
 * bucket. Generate one from Firebase Console > Project Settings > Service
 * Accounts > Generate new private key.
 */

const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const value = argv[i + 1];
      args[key] = value;
      i++;
    }
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!args.bin || !args.version || !args["service-account"]) {
    console.error(
      "Usage: node upload_firmware.js --bin <firmware.bin> --version <x.y.z> " +
      "--service-account <serviceAccountKey.json> [--model fallsensex]"
    );
    process.exit(1);
  }

  const binPath = path.resolve(args.bin);
  if (!fs.existsSync(binPath)) {
    console.error(`Firmware file not found: ${binPath}`);
    process.exit(1);
  }

  const model = args.model || "fallsensex";
  const serviceAccount = require(path.resolve(args["service-account"]));

  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
    storageBucket: `${serviceAccount.project_id}.appspot.com`,
  });

  const destination = `firmware/${model}/${args.version}.bin`;
  console.log(`Uploading ${binPath} -> gs://${serviceAccount.project_id}.appspot.com/${destination}`);

  await admin.storage().bucket().upload(binPath, {
    destination,
    metadata: {
      contentType: "application/octet-stream",
      metadata: {
        version: args.version,
        model,
        notes: args.notes || "",
      },
    },
  });

  console.log("Upload complete. The onFirmwareUploaded Cloud Function will build the manifest and notify devices shortly.");
  process.exit(0);
}

main().catch((err) => {
  console.error("Upload failed:", err);
  process.exit(1);
});
