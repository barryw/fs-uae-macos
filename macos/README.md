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
./macos/scripts/stress-test-mcp.sh A500
./macos/scripts/stress-test-mcp.sh A1200
./macos/scripts/stress-test-mcp.sh A4000
```

Each run verifies commands, exact output, binary file transfer, stale-response
rejection, timeout/reset recovery, and repeated process lifecycles. The guest
service requires a bootable Exec/AmigaDOS environment; configurations with
missing or uninstalled OS media cannot provide guest control.

## Debugging a Guru

The emulator records every CPU exception through `uae_cpu_exception_hook`
without stopping, so `fsuae_machine_diagnostics` reports the vector, the
faulting instruction's PC, the fault address and the task at any time. Nothing
has to be armed first, and nothing halts the machine - `libfsuaemac` has no
console for the built-in debugger to read from, so `console_get()` reports
end-of-input rather than hanging the emulator thread.

To get from an address to a source line, the segment tracker has to be
watching when the program is loaded:

1. `fsuae_debug_tracking` with `enabled: true`.
2. Reset, then launch the program. Only seglists loaded after tracking is on
   are recorded.
3. `fsuae_debug_segments` to see the seglist name and its load addresses.
4. `fsuae_debug_symbols` with that name and the host path of the same
   executable, linked with debug hunks.
5. `fsuae_debug_resolve` on any address - or just read
   `cpu_exception.location` from `fsuae_machine_diagnostics`, which resolves
   the faulting PC for you.

`fsuae_debug_command` still takes any built-in debugger command for anything
these do not cover.
