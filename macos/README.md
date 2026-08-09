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
