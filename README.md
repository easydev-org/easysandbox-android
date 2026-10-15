# easysandbox-android

The Android (emulator) sandbox image: the official Android emulator + a system
image + adb, run headless. The screen is served by the **easystream** daemon
*inside* the guest (est:// H.264), not by VNC/noVNC.

## Layout

```
Containerfile   two stages: SDK fetch/pre-create the AVD, then the runtime
build.sh        build + push the image (buildctl)
entrypoint.sh   guest bring-up: push the worker + APK in, start them
```

## Guest binaries

Both come from GitHub **releases** at build time — nothing is vendored:

| binary | from |
|---|---|
| `agent-worker` (static linux/amd64) | `easydev-org/easyworker` release `WORKER_VERSION` |
| `easystream.apk` (Kotlin est daemon) | `easydev-org/easystream-android` release `EASYSTREAM_VERSION` |

## Build

```sh
WORKER_VERSION=v0.0.1 EASYSTREAM_VERSION=v0.0.1 \
  ./build.sh aosp          # or: ./build.sh gms
```

Screen is 1024x768 (matching the Windows/macOS/Linux sandboxes).
