# FallSenseX Local OTA Flasher (Path B)

A small Tkinter GUI for flashing a firmware `.bin` straight from this PC to
a FallSenseX device on the same LAN - no Firebase Storage, no Cloud
Function, no version bump. Useful while iterating on firmware before the
remote (Path A / Firebase) OTA flow needs to be exercised.

## How it works

The device's `/ota_update` endpoint only ever *pulls* a firmware image from
a URL you give it - it has no raw-upload endpoint. So this script:

1. Starts a one-shot local HTTP server on this PC that serves only the
   `.bin` file you picked, bound to the IP this PC uses to reach the
   device (not `localhost` - the device needs to reach it too).
2. POSTs `{"url": "http://<this-pc>:<port>/firmware.bin"}` to the device's
   `/ota_update`, with the device's PIN in the `X-Device-PIN` header.
3. Polls `GET /ota_status` (no PIN required) to show live download/flash
   progress, until the device reports success/failure or reboots.

**The POST to `/ota_update` is expected to hang and then drop the
connection on success** - the device reboots into the new firmware before
it ever gets a chance to send an HTTP response. The script treats that as
the expected outcome, not an error; real progress comes from the separate
`/ota_status` polling loop.

## Usage

```bash
cd tools/ota_flash_pc
pip install -r requirements.txt
python ota_flash_pc.py
```

1. Enter the device's IP (shown on its settings page / serial log).
2. Enter its PIN (logged once on first boot, or whatever you changed it to
   via `/pin_change`).
3. Browse to the firmware `.bin` (e.g. `build/fall_sense_x_main.bin` after
   `idf.py build`).
4. Click **Flash Device** and watch the log panel.

Both PC and device must be on the same LAN/Wi-Fi network.

## Notes

- This bypasses the device's own version check (`OTA_FIRMWARE_VERSION` /
  `compare_versions()`) entirely - it always flashes whatever file you
  point it at, regardless of version. That's intentional for dev
  iteration; don't expect it to skip a "no update needed" case.
- If the device never starts downloading (status stays `idle`), double
  check the PIN and that nothing else is blocking the LAN connection
  between this PC and the device (e.g. AP/client isolation on the router).
- This is a dev tool, not part of the production app build - it isn't
  wired into CI or the Flutter app.
