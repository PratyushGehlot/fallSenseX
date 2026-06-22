#!/usr/bin/env python3
"""
FallSenseX local OTA flasher (Path B / LAN-only).

Lets you pick a firmware .bin on this PC and flash it straight to a
FallSenseX device on the same network - no Firebase Storage upload, no
Cloud Function, no version bump required. This exercises exactly the same
device-side code (ota_update.c -> esp_https_ota) as the remote Firebase
path, just pointed at a file this script is serving instead of a
Firebase Storage URL.

How it works:
  1. You pick a .bin and enter the device's IP + its PIN (shown once on
     the device's serial log, or whatever you changed it to via
     /pin_change).
  2. This script starts a one-shot local HTTP server that serves *only*
     that file, on whatever port the OS hands it, bound to this PC's LAN
     IP (the address the device can actually reach - we do not bind to
     0.0.0.0/localhost since the device must be able to connect to it).
  3. It POSTs {"url": "http://<this-pc-ip>:<port>/firmware.bin"} to the
     device's /ota_update endpoint with the PIN header. The device then
     downloads from *this script*, flashes the inactive OTA partition,
     and reboots.

Important: the device's /ota_update handler runs the whole download+flash
synchronously and reboots *before* it ever sends an HTTP response back.
So the POST request will hang and then the connection will simply drop -
that is the expected, successful outcome, not an error. Live progress
comes from a separate, repeated GET to /ota_status (not PIN-gated),
which this script polls on its own.

Usage:
    python ota_flash_pc.py

Requires: Python 3.8+, the 'requests' package (pip install requests).
Everything else (Tkinter file dialog, the local HTTP server) is stdlib.
"""

import http.server
import json
import os
import queue
import socket
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import requests

POLL_INTERVAL_S = 1.0
# How long to keep polling /ota_status after the device stops responding
# (it's mid-reboot) before giving up and assuming it either succeeded or
# is back on old firmware after a failed boot.
POST_REBOOT_GRACE_S = 25


def find_local_ip_for(device_ip: str) -> str:
    """Returns this machine's IP on the interface that would be used to
    reach device_ip - this is the address we tell the device to download
    from, so it must be reachable from the device's side of the LAN, not
    just from this PC.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # UDP connect doesn't send anything - it just makes the OS pick
        # the right outbound interface/route for that destination.
        s.connect((device_ip, 80))
        return s.getsockname()[0]
    finally:
        s.close()


class _SingleFileHandler(http.server.BaseHTTPRequestHandler):
    """Serves exactly one file at /firmware.bin and nothing else - avoids
    exposing the rest of the filesystem like a generic directory server
    would.
    """

    file_path = None  # set per-instance via functools.partial in serve()

    def do_GET(self):
        if self.path != "/firmware.bin":
            self.send_error(404)
            return
        try:
            size = os.path.getsize(self.file_path)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(self.file_path, "rb") as f:
                while True:
                    chunk = f.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # device disconnected mid-download - not our problem

    def log_message(self, fmt, *args):
        pass  # quiet by default; flasher GUI shows its own progress log


def serve_file_once(file_path: str, bind_ip: str):
    """Starts a background HTTP server bound to bind_ip on an OS-chosen
    port, serving only file_path. Returns (server, port); call
    server.shutdown() when done.
    """
    handler = type("BoundHandler", (_SingleFileHandler,), {"file_path": file_path})
    server = http.server.ThreadingHTTPServer((bind_ip, 0), handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, port


class FlashJob:
    """Runs the flash on a background thread and reports progress lines
    and percentage updates through thread-safe queues the GUI polls.
    """

    def __init__(self, device_ip, pin, file_path, log_queue: "queue.Queue[str]",
                 progress_queue: "queue.Queue[tuple[int, str]]"):
        self.device_ip = device_ip.strip()
        self.pin = pin
        self.file_path = file_path
        self.log_queue = log_queue
        self.progress_queue = progress_queue
        self._stop = threading.Event()

    def log(self, msg):
        self.log_queue.put(msg)

    def report_progress(self, percent: int, label: str):
        self.progress_queue.put((percent, label))

    def run(self):
        server = None
        try:
            local_ip = find_local_ip_for(self.device_ip)
            server, port = serve_file_once(self.file_path, local_ip)
            url = f"http://{local_ip}:{port}/firmware.bin"
            size = os.path.getsize(self.file_path)
            self.log(f"Serving {os.path.basename(self.file_path)} ({size} bytes) at {url}")
            self.log(f"Telling device {self.device_ip} to download from this PC...")
            self.report_progress(0, "Starting...")

            self._post_ota_command(url)
            self._poll_status()
        except Exception as e:  # noqa: BLE001 - surface anything to the log
            self.log(f"ERROR: {e}")
            self.report_progress(0, f"Error: {e}")
        finally:
            if server is not None:
                server.shutdown()

    def _post_ota_command(self, url):
        try:
            resp = requests.post(
                f"http://{self.device_ip}/ota_update",
                json={"url": url},
                headers={"X-Device-PIN": self.pin},
                timeout=10,
            )
            data = resp.json()
            if not data.get("success", True):
                # Validation failures (bad PIN, malformed JSON) return
                # fast, before OTA even starts.
                raise RuntimeError(f"Device rejected request: {data}")
            self.log("Device accepted the OTA request (unexpected fast response - "
                     "OTA may have completed near-instantly, or this was a validation echo).")
        except requests.exceptions.Timeout:
            self.log("POST is still hanging after 10s - device is downloading/flashing. "
                     "This is normal: the device replies only after the OTA finishes, "
                     "and a successful OTA reboots before it can reply at all.")
        except (requests.exceptions.ConnectionError, json.JSONDecodeError):
            self.log("Connection dropped while waiting for a response - almost always "
                     "means the device is rebooting into the new firmware. Treating as success.")

    def _poll_status(self):
        last_state = None
        deadline = time.monotonic() + POST_REBOOT_GRACE_S
        saw_progress = False

        while time.monotonic() < deadline:
            try:
                resp = requests.get(f"http://{self.device_ip}/ota_status", timeout=3)
                status = resp.json()
                state = status.get("state")
                # ota_update_get_progress() on the device returns a 0-100
                # percentage (bytes-downloaded / image-size), not a raw
                # byte count - safe to feed straight into a progress bar.
                progress = status.get("progress", 0)
                error = status.get("error", "none")

                if state != last_state or saw_progress:
                    self.log(f"  status: {state}  progress={progress}%  error={error}")
                last_state = state
                if state in ("downloading", "writing"):
                    saw_progress = True
                    deadline = time.monotonic() + POST_REBOOT_GRACE_S  # keep extending while active
                    self.report_progress(progress, f"Flashing... {progress}%")

                if state == "success":
                    self.log("OTA reported success on-device. It will reboot into the new firmware now.")
                    self.report_progress(100, "Success - rebooting...")
                    return
                if state == "failed":
                    self.log(f"OTA FAILED on-device: {error}")
                    self.report_progress(progress, f"Failed: {error}")
                    return
            except requests.exceptions.RequestException:
                if saw_progress:
                    self.log("Device stopped responding (rebooting). "
                             "Waiting for it to come back online...")
                    self.report_progress(99, "Rebooting...")
                    self._wait_for_reboot()
                    return
                # Not started downloading yet and unreachable already -
                # likely a bad IP/PIN or it's not on this network.
            time.sleep(POLL_INTERVAL_S)

        self.log("Gave up waiting for a status update. Check the device's serial "
                 "log directly if you're unsure whether the flash succeeded.")

    def _wait_for_reboot(self):
        deadline = time.monotonic() + POST_REBOOT_GRACE_S
        while time.monotonic() < deadline:
            try:
                requests.get(f"http://{self.device_ip}/ota_status", timeout=2)
                self.log("Device is back online after reboot. Flash likely succeeded - "
                         "confirm the new version on its settings page.")
                self.report_progress(100, "Done - device back online")
                return
            except requests.exceptions.RequestException:
                time.sleep(1)
        self.log("Device hasn't come back online within the grace period. "
                 "Check it directly (serial log / power-cycle) if this persists.")
        self.report_progress(99, "No response after reboot grace period")


class FlasherApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("FallSenseX - Local OTA Flash (Path B)")
        self.geometry("560x460")
        self.resizable(False, False)

        self.log_queue: "queue.Queue[str]" = queue.Queue()
        self.progress_queue: "queue.Queue[tuple[int, str]]" = queue.Queue()
        self.file_path_var = tk.StringVar()
        self.ip_var = tk.StringVar()
        self.pin_var = tk.StringVar()
        self.progress_value = tk.IntVar(value=0)
        self.progress_label_var = tk.StringVar(value="Idle")

        self._build_ui()
        self.after(150, self._drain_log_queue)
        self.after(150, self._drain_progress_queue)

    def _build_ui(self):
        pad = {"padx": 10, "pady": 6}

        frm = ttk.Frame(self)
        frm.pack(fill="x", **pad)

        ttk.Label(frm, text="Device IP:").grid(row=0, column=0, sticky="w")
        ttk.Entry(frm, textvariable=self.ip_var, width=20).grid(row=0, column=1, sticky="w")

        ttk.Label(frm, text="Device PIN:").grid(row=1, column=0, sticky="w")
        ttk.Entry(frm, textvariable=self.pin_var, width=20, show="*").grid(row=1, column=1, sticky="w")

        ttk.Label(frm, text="Firmware (.bin):").grid(row=2, column=0, sticky="w")
        ttk.Entry(frm, textvariable=self.file_path_var, width=40, state="readonly").grid(
            row=2, column=1, sticky="w"
        )
        ttk.Button(frm, text="Browse...", command=self._browse).grid(row=2, column=2, padx=(8, 0))

        self.flash_btn = ttk.Button(self, text="Flash Device", command=self._start_flash)
        self.flash_btn.pack(pady=(4, 4))

        progress_frame = ttk.Frame(self)
        progress_frame.pack(fill="x", padx=10, pady=(0, 8))
        self.progress_bar = ttk.Progressbar(
            progress_frame, variable=self.progress_value, maximum=100
        )
        self.progress_bar.pack(fill="x")
        ttk.Label(progress_frame, textvariable=self.progress_label_var).pack(anchor="w", pady=(2, 0))

        log_frame = ttk.Frame(self)
        log_frame.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        self.log_text = tk.Text(log_frame, state="disabled", wrap="word")
        scroll = ttk.Scrollbar(log_frame, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=scroll.set)
        self.log_text.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

    def _browse(self):
        path = filedialog.askopenfilename(
            title="Select firmware .bin",
            filetypes=[("Firmware binary", "*.bin"), ("All files", "*.*")],
        )
        if path:
            self.file_path_var.set(path)

    def _append_log(self, msg: str):
        self.log_text.configure(state="normal")
        self.log_text.insert("end", msg + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _drain_log_queue(self):
        try:
            while True:
                msg = self.log_queue.get_nowait()
                self._append_log(msg)
        except queue.Empty:
            pass
        self.after(150, self._drain_log_queue)

    def _drain_progress_queue(self):
        try:
            while True:
                percent, label = self.progress_queue.get_nowait()
                self.progress_value.set(percent)
                self.progress_label_var.set(label)
        except queue.Empty:
            pass
        self.after(150, self._drain_progress_queue)

    def _start_flash(self):
        ip = self.ip_var.get().strip()
        pin = self.pin_var.get().strip()
        path = self.file_path_var.get().strip()

        if not ip or not pin or not path:
            messagebox.showerror("Missing info", "Device IP, PIN, and a firmware file are all required.")
            return
        if not os.path.isfile(path):
            messagebox.showerror("File not found", f"Can't find: {path}")
            return

        self.flash_btn.configure(state="disabled", text="Flashing...")
        self.progress_value.set(0)
        self.progress_label_var.set("Starting...")
        self._append_log(f"--- Starting flash of {os.path.basename(path)} to {ip} ---")

        job = FlashJob(ip, pin, path, self.log_queue, self.progress_queue)

        def run_and_reenable():
            job.run()
            self.log_queue.put("--- Done. Re-check the device before flashing again. ---")
            self.flash_btn.configure(state="normal", text="Flash Device")

        threading.Thread(target=run_and_reenable, daemon=True).start()


if __name__ == "__main__":
    FlasherApp().mainloop()
