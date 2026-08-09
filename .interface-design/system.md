# FS-UAE Mac Interface System

## Direction

- Feel: a quiet native instrument surrounding the emulated machine, not a dashboard.
- Domain: CRT glass, Amiga casework, drive bays, activity LEDs, Workbench blue, and physical media labels.
- Signature: the MacVICE shell—native unified titlebar controls, an uninterrupted black emulator stage, and a narrow live-status strip at the bottom.
- Avoid: dashboard navigation, card grids, decorative gradients, oversized headings, and web-style chrome.

## Foundations

- Depth: borders and subtle surface-color shifts only; no decorative shadows.
- Spacing: 4-point base grid. Prefer 8, 12, 16, and 24 points; status rails are 36 points high.
- Canvas: CRT charcoal `rgb(6, 7, 7)`.
- Primary action: the person’s system accent color; never impose an app-specific control tint.
- Media accent: aged case-label beige `rgb(184, 171, 138)`.
- Status: desaturated green at 75% opacity; inactive indicators use system gray at 45%.
- Surfaces: use native macOS window backgrounds so controls remain legible in light and dark appearances.
- Typography: San Francisco for controls and status; monospaced semibold with restrained tracking for machine identity and compact device labels.

## Patterns

### Emulator Stage

- Fill available window space with the Metal display over CRT charcoal.
- Keep the image aspect-correct and centered; unused space remains CRT charcoal.
- Focus the display on click and expose it as “Amiga display” to accessibility APIs.
- Pause only the selected machine; keep its last frame visible beneath a 52%-black veil with a centered white pause glyph, matching MacVICE without adding a modal card.

### Titlebar Toolbar

- Put session, reset, machine configuration, media, and fullscreen actions in native SwiftUI toolbar groups.
- Use compact SF Symbols and system menus; do not reproduce titlebar controls inside the content area.
- Configuration selection is a native collapsible sidebar of launcher-compatible `.fs-uae` files.
- The selected configuration is the atomic boot unit; machine model selection belongs inside its editor.

### Configuration Library

- Use a narrow native source-list sidebar, separated from the stage by a hairline border.
- Show the saved configuration name first and its Amiga model as compact monospaced metadata.
- Keep creation and editing in the unified titlebar toolbar and menu bar; never put critical actions at the bottom of the sidebar.
- Use single-line source-list rows with SF Symbols and the system selection treatment.
- Mark live configurations with a trailing 7-point LED: desaturated green while any session is active and amber only when every session is paused; retain the terminal count for headless sessions.
- Edit common hardware and drive values in a modal source-list task sheet with grouped native forms; keep the complete file available as monospaced text so every FS-UAE option remains accessible.
- Represent enumerated hardware values, including memory sizes, with native pop-up buttons sourced from FS-UAE 3.x choices; validate the same constraints before saving advanced text.
- Recompute model defaults and available controls when `amiga_model`, CPU, accelerator, or expansion bus changes; incompatible existing overrides remain visible as invalid until the person corrects them.
- Organize configuration by physical domains—Machine, Memory, Expansion, Drives, and Audio & Integration—while Advanced remains the lossless escape hatch for uncommon options.

### Drive and Status Rail

- Height: 36 points.
- Horizontal padding: 12 points; item gap: 12 points.
- Use a hairline divider at the top, never a raised card treatment.
- Order: configuration identity and an info popover, live state, flexible space, then inserted media.
- Keep static model, video, and ROM details in the info popover rather than permanent badges.
- Device and media text stays compact and single-line.
- Render configured DF/DH devices as compact capsule chips with an 8-point LED and monospaced semibold device name.
- Idle LEDs use secondary gray; floppy activity is green and hard-disk activity is red.
- Clicking a floppy chip opens a native management popover showing the inserted disk and explicit Load Disk… and Eject actions; only Load Disk… opens the file panel.

### Stopped Configuration Detail

- Reserve black exclusively for the live emulator surface.
- Present the selected configuration on the system control background with native title, secondary metadata, SF Symbol, and bordered actions.
- Use `ContentUnavailableView` for no-selection and empty-library states.
- Use the system accent color for the single prominent Boot action.

### Interaction

- Prefer native menus, file importers, fullscreen, keyboard shortcuts, disabled states, source-list selection, and focus behavior.
- Source-list selection owns the detail pane, status rail, toolbar state, and audible session. A running machine remains marked in the sidebar but never overrides another selected configuration.
- Protect unsaved sheet edits with explicit discard confirmation and reject accidental overwrite of another configuration.
- Color communicates action, media, or runtime state only; never decoration.

### Keyboard Mapping

- Keep keyboard remapping in the native Settings scene, not in the emulator stage or configuration editor.
- Use a searchable two-column table: physical Mac key and mapped Amiga key, with explicit Not Mapped and Reset Defaults controls.
- Keep table rows text-only; selecting a row exposes one native mapping picker below the table so large per-row menus never impede presentation or scrolling.
- Apply mappings immediately and persist them globally because every supported Amiga model shares the same physical keyboard.
- Route modifier-only keys through AppKit flags-changed events and release every held emulated key when focus leaves the display.

### Application Settings

- Use the standard macOS Settings scene with icon-labeled tabs; Keyboard and Agent Control are separate panes with identical fixed geometry.
- Keep automation opt-in and localhost-only. Show listening state, loopback address, editable port, and the exact MCP endpoint together.
- Headless applies only to MCP-started sessions: keep the emulator core running while replacing the Metal stage with a quiet session indicator.
- Make the exposed tool surface visible in Settings, and keep destructive configuration operations exact-name, non-overwriting, and recoverable through Trash.

### Concurrent Sessions

- Keep one localhost MCP endpoint for every emulator; identify each running machine with a UUID rather than opening a server per process.
- Run headless machines in isolated helper processes with no video or audio callbacks; show only a compact terminal-and-count marker beside their source-list configuration.
- Route audio only from the currently presented, selected machine. Background and headless machines remain silent.
- Pause and stop target the selected machine UUID only; background workers retain their independent state and the shell never waits synchronously for worker shutdown.
- Report lifecycle and health through the machine list—configuration, process, presentation, frame heartbeat, 68k PC, and raw Guru alert data—without adding a dashboard.
