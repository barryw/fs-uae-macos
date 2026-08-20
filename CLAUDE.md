# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Upstream FS-UAE (Amiga emulator built on the WinUAE core, autotools/C++) plus a
native macOS frontend under `macos/`. Active work happens on the `macos-swiftui`
branch and lives in two places: `macos/` (Swift) and a small number of patched
core files (`src/od-fs/macos/fsuaemac.cpp`, `src/filesys.asm`, `src/filesys.cpp`,
`src/newcpu.cpp`).

The stock `fs-uae` binary, launcher, and the Linux/Windows targets are upstream
code — do not restructure them for the macOS work.

## Commands

```sh
macos/scripts/build-runtime.sh      # bootstrap + configure + make libfsuaemac.dylib
macos/scripts/smoke-test-runtime.sh # boots the dylib headlessly against a config
macos/scripts/build-app.sh          # builds runtime + Amiga tools + SwiftPM app bundle
macos/scripts/smoke-test-app.sh     # launches the bundle with --fsuae-mac-smoke-test
open ".build/macos/FS-UAE Mac.app"
```

Swift unit tests (Swift Testing, not XCTest):

```sh
swift test --package-path macos/MacFSUAEKit
swift test --package-path macos/MacFSUAEKit --filter guestStatusRejectsPartialAndStaleResponses
```

End-to-end guest-automation stress test — requires the app running with the MCP
server enabled on `http://127.0.0.1:6800/mcp`:

```sh
macos/scripts/build-amiga-tools.sh              # vbcc, expects VBCC=~/amiga-cc/vbcc
macos/scripts/stress-test-mcp.py A500|A1200|A4000
```

Smoke tests default to `~/Documents/FS-UAE/Configurations/A500.fs-uae`; pass a
different path as `$2`.

Build artifacts all land under `.build/` (`fsuae-3/` for autotools, `macos/` for
the app, `amiga/` for the vbcc-built guest tools).

## Architecture

### Three processes, one runtime

`libfsuaemac.dylib` is the whole FS-UAE core relinked as a dylib
(`Makefile.am:1141`, sources in `src/od-fs/macos/fsuaemac.cpp`). It exposes a
flat C ABI declared in `macos/include/fsuaemac.h`: start/stop, queued input,
video/audio/log/drive callbacks, `fsuaemac_get_health`, and
`fsuaemac_debug_command`. The core runs on its own pthread; every frame and audio
buffer handed to Swift is a copy.

Swift never links the dylib. `Sources/CMacFSUAEEngine/MacFSUAEEngine.c` `dlopen`s
it and resolves each symbol by name, so a missing or stale runtime is a runtime
error, not a link error. Add a new ABI entry point in **three** places:
`macos/include/fsuaemac.h`, `src/od-fs/macos/fsuaemac.cpp`, and the `LOAD(...)`
table plus wrapper in `MacFSUAEEngine.c`.

Processes:

- **`FS-UAE Mac`** (`Sources/FSUAEMacApp`) — SwiftUI app. Owns the foreground
  session, Metal presentation, AVFoundation audio, and the MCP server.
- **`FS-UAE Worker`** (`Sources/FSUAEWorker/main.swift`) — one per MCP-started
  machine. Loads its own copy of the dylib, publishes frames into an mmap'd
  `MacFSUAEFrameTransport` file, and speaks a line protocol on stdio: JSON
  commands in on stdin, `FSUAE_STATUS` / `FSUAE_HEALTH` / `FSUAE_DRIVES` /
  `FSUAE_ACK` lines out on stderr. It exits when its parent pid changes.
- **The emulated Amiga**, driven through the guest service below.

Workers are configured entirely through the environment (`MCPServer.swift`
`startWorker`, consumed in `fsuaemac.cpp`): `FSUAE_MAC_RUNTIME`,
`FSUAE_MAC_FRAME_FILE`, `FSUAE_MAC_EXCHANGE_DIRECTORY`, `FSUAE_MAC_ABSOLUTE_MOUSE`,
`FSUAE_MAC_FLOPPY_<0-3>`, `FSUAE_MAC_HARD_DRIVE_<0-9>[_READ_ONLY]`. These are
overlays — they never mutate the saved `.fs-uae` configuration.

### MCP server and guest automation

`Sources/MacFSUAEKit/MCPServer.swift` is a JSON-RPC-over-HTTP MCP server bound to
`127.0.0.1` (default port 6800, persisted in `UserDefaults`). Tools cover machine
lifecycle, floppies/HDFs, input, screen capture, UAE debugger access, and guest
command execution (`fsuae_command_run` / `_execute` / `_result`, `fsuae_file_put`
/ `_get`, `fsuae_exchange_put` / `_get`).

Guest control is implemented **in 68k assembly inside the Amiga**, not on the
host. `control_init` / `control_proc` in `src/filesys.asm` spawn a DOS process in
the UAE host-filesystem handler that polls a set of files on the `MCP:` volume:

| File | Role |
| --- | --- |
| `MCP:FSUAE-Control-Command` | request written by the host |
| `MCP:FSUAE-Control-Output` | captured stdout |
| `MCP:FSUAE-Control-Status` | 10-byte result: success, exit code, 4-byte request token |
| `MCP:FSUAE-Control-Transfer` | binary file staging |
| `MCP:FSUAE-Control-Input` | empty file used as a distinct input handle |

`MCP:` is a host directory mounted read-write at non-bootable priority `-128` by
`fs_uae_configure_host_directory(exchange, "MCP", "MCP", -128)`, backed by the
per-machine temp dir in `FSUAE_MAC_EXCHANGE_DIRECTORY`. The host reads and writes
those files directly; `parseGuestStatus` rejects short or stale (wrong-token)
status blobs, which is what makes timeout/reset recovery deterministic.

DOS version matters and is branched on explicitly (`cmp.w #36,20(a5)`): DOS 2.0+
uses `SystemTagList` and returns a real exit code; Kickstart 1.x falls back to
`Execute` and reports `exit_code_known=false`. Kickstart 1.x also deadlocks if the
control process locks another automounting filesystem during startup, so the
`MCP:` current-directory setup is skipped there and all paths stay
device-qualified.

`src/filesys_bootrom.cpp` is **generated**, never hand-edited. Editing
`src/filesys.asm` requires regenerating it:

```sh
macos/scripts/build-filesys-bootrom.sh   # needs vasmm68k_mot and vlink
```

`build-runtime.sh` regenerates it automatically when the `.asm` is newer, so the
2000-line diff in that file is expected whenever `filesys.asm` changes.

### Health and crash reporting

`fsuaemac_health` carries the frame sequence, PC, `ExecBase`, the last Guru alert,
guest-control readiness/heartbeat/generation, and the last CPU exception with its
task name. `src/newcpu.cpp` splits `report_exception` out of `exception_debug` so
exceptions are captured even when the debugger is not active. Workers forward this
once a second as `FSUAE_HEALTH`; `fsuae_machine_diagnostics` surfaces it.

### Guest-side tools

`macos/amiga/FSUAE-Diag.c` and `FSUAE-WaitWB.c` are built with vbcc for
`+kick13 -cpu=68000` so the automation tests do not depend on `C:`, `RAM:`,
Workbench, or the CPU model. They ship in
`FS-UAE Mac.app/Contents/Resources/Amiga/` and are copied onto `MCP:` when a
worker starts.

## Conventions

- Swift 6 language mode, strict concurrency. `MacFSUAEMCPServer` and the session
  types are `@MainActor`; anything crossing to the emulator thread is a copy.
- The app bundle is self-contained: `build-app.sh` recursively rewrites install
  names into `Contents/Frameworks` and **fails the build** if any
  `/opt/homebrew/` dependency survives. It is ad-hoc signed only — Developer ID
  signing, notarization, and DMG packaging are not wired up.
- UI work should follow `.interface-design/system.md` (CRT charcoal canvas, system
  accent for primary actions, no dashboard/card chrome).
- Follow-up work explicitly out of scope so far: RTG, mouse capture, controllers,
  broader model/media settings.
