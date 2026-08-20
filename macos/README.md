# FS-UAE Mac

Native macOS proof of concept: SwiftUI owns the app, Metal presents copied
BGRA frames, AVFoundation plays copied PCM buffers, and `libfsuaemac.dylib`
runs the FS-UAE core on its own thread.

```sh
./macos/scripts/build-runtime.sh
./macos/scripts/smoke-test-runtime.sh
./macos/scripts/build-app.sh
./macos/scripts/smoke-test-app.sh
open ".build/macos/FS-UAE Mac.app"
```

The app boots an A500 with the built-in AROS ROM or an imported Kickstart ROM,
accepts a floppy by picker or drag-and-drop, and supports keyboard input,
pause, reset, resizing, and native fullscreen.

The local app bundles and rewrites its current runtime dependencies and is
ad-hoc signed. Developer ID signing, notarization, DMG packaging, RTG, mouse
capture, controllers, and broader model/media settings remain follow-up work.

## Guest service compatibility

The MCP guest service is machine-model independent and runs on the UAE host
filesystem process once AmigaDOS starts. Kickstart 1.x uses `Execute()` and
reports `exit_code_known=false`; DOS 2.0 and newer use `SystemTagList()` and
return the program's exit code. Both paths capture output and support binary
file transfer through the always-present `MCP:` volume.

The stress fixture is a self-contained 68000/Kickstart-1.3 executable, so the
test does not depend on `C:`, `RAM:`, Workbench commands, or the CPU model:

```sh
./macos/scripts/build-amiga-tools.sh
./macos/scripts/stress-test-mcp.py A500
./macos/scripts/stress-test-mcp.py A1200
./macos/scripts/stress-test-mcp.py A4000
```

Each run verifies commands, exact output, binary file transfer, stale-response
rejection, timeout/reset recovery, and repeated process lifecycles. The guest
service requires a bootable Exec/AmigaDOS environment; configurations with
missing or uninstalled OS media cannot provide guest control.
