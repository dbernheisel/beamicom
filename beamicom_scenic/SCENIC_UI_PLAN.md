# Scenic UI Improvement Plan

## Status

In progress. Phases 0–5 are implemented and covered by automated tests, with
native-dialog behavior still requiring hands-on verification on each target
desktop. This remains the tracked working plan for the long-lived,
ZSNES-inspired application shell.

## Scope

Target platforms:

- macOS
- Linux desktop environments with GTK 3

The finished UI should provide:

- A ZSNES-style, Scenic-drawn menu system.
- An animated idle/menu background with a starfield, perspective grid,
  scanlines, and looping vector spaceships.
- Native open and save file selectors through a small NIF boundary.
- Menu actions for loading and running media, resetting the active system, and
  saving or loading state.
- A status bar showing frame rate, loaded media, controller state, and transient
  messages.
- Optional ROM-aware emissive lighting driven by an explicit manifest of
  light-producing tiles, sprites, palette usage, and game-state predicates.
- A stable application window that remains open while emulator sessions are
  started, stopped, reset, or replaced.

## Non-goals

- Native operating-system menu bars.
- Reimplementing ROM parsing, emulation, or save-state formats in the UI layer.
- Reading or writing file contents inside the file-dialog NIF.
- Inferring light sources from generic brightness or color thresholds. A bright
  pixel emits light only when its rendering provenance matches an active rule
  in the loaded ROM's lighting manifest.

## Product behavior

The application starts in an idle menu with no ROM required. The animated
background runs while the idle menu is visible.

While a ROM is running, the viewport contains only the centered framebuffer on
a black field. The menu, status bar, logo, and animated background are removed
from the Scenic graph. Pressing `Escape` pauses emulation and restores the full
HUD; pressing it again resumes emulation and returns to the HUD-free graph.

The interaction model follows the spirit of ZSNES:

- `Load...` opens a native file selector and boots the selected ROM or save.
- Opening the menu during gameplay pauses the emulator.
- `Run` closes the menu and resumes the current session.
- `Reset` rebuilds the machine from the current media.
- `Save state...` and `Load state...` use native save/open selectors.
- `Escape` toggles between gameplay and the paused menu.
- Closing the native window shuts down the emulator session and application cleanly.

Application states:

```elixir
:idle
:loading
:running
:menu_paused
{:error, message}
```

## Architecture

The current `Beamicom.Scenic.Player` loads media, starts every emulator
resource, and then starts Scenic. That ownership must be inverted so the UI can
exist before a ROM is selected.

Target process structure:

```text
Long-lived Scenic shell
|-- Shell scene
|   |-- Animated background
|   |-- Menu bar and popup menu
|   |-- Game surface
|   `-- Status bar
|-- File dialog Task.Supervisor
|   `-- Native file-dialog NIF
`-- Replaceable emulator session
    |-- Runtime
    |-- Audio sink
    |-- Input server/client
    `-- Video output
```

### Ownership changes

1. Start one fixed logical Scenic viewport with a new shell root scene.
2. Refactor `Beamicom.Scenic.Player` so it owns only one emulator session and no
   longer starts or stops Scenic.
3. Add a session manager responsible for loading, pausing, resuming, resetting,
   replacing, and stopping the player.
4. Convert the framebuffer behavior in `Beamicom.Scenic.Screen` into a game
   surface hosted by the shell.
5. Preserve `Beamicom.Scenic.play/2` as a convenience API that starts the shell
   if needed and immediately loads the supplied path.

## UI components

### Shell scene

The shell owns the visible mode, current menu, selected item, status message,
and active session metadata. It coordinates components but does not perform
blocking filesystem or native-dialog work.

### Menu bar

Build reusable Scenic components for `MenuBar`, `PopupMenu`, and `MenuItem`.
They must support:

- Mouse hover and click.
- Arrow-key and Enter navigation.
- Escape to close.
- Gamepad navigation.
- Selected, disabled, checked, separator, and submenu presentation.
- Keyboard shortcuts.

Initial menu model:

```text
Game
  Load...
  Run
  Reset
  ----------
  Save state...
  Load state...

Config
  State folder...
  NES
    FILTER
    None
    Composite
    S-Video
    RGB
    ----------
    ENHANCEMENTS
    Remove sprite limit
    Trim borders
  GBC
    FILTER
    None
    Pixel transparency
  Integer scaling
  Audio
```

Run, Reset, and Save State are disabled without an active session. Menu item
availability is derived from shell state instead of being managed independently
by each component.

### Animated background

Implement `Beamicom.Scenic.Component.Background` using Scenic primitives.
Separate it into these layers:

1. Static navy backdrop, horizon, border, and scanline overlay.
2. A perspective grid whose depth phase advances and wraps.
3. A sparse starfield with deterministic positions and looping motion.
4. Three or four vector spaceships made from triangles and lines.

Each ship has a trajectory, loop duration, phase offset, depth curve, and color
palette. Its transform is derived from monotonic elapsed time:

```text
progress = (elapsed + phase_offset) modulo loop_duration
position = trajectory(progress)
scale    = depth_curve(progress)
opacity  = edge_fade(progress)
```

The animation should target approximately 60 FPS. Static primitives are built
once; each tick modifies only dynamic group transforms and pushes the updated
graph. Time-based animation avoids speed changes after scheduler stalls. Stop
animation ticks whenever the background is fully obscured by gameplay.

### Game surface

Move streamed framebuffer rendering out of the root scene and into a component
that can be shown or hidden without recreating the viewport. It continues to:

- Subscribe to the active core's video output.
- Convert the native frame to RGB24.
- Apply the selected presentation filter and scaling.
- Preserve aspect ratio within the shell's content region.
- Forward keyboard and gamepad state to the active session only while running.

### ROM-aware emissive lighting

Treat lighting as an optional presentation effect backed by explicit,
ROM-specific knowledge. It must not change PPU behavior, the native framebuffer,
save states, or unfiltered screenshot output. When no manifest profile matches,
presentation remains byte-for-byte equivalent to the existing path.

Identify a profile with a SHA-256 digest of the parsed PRG ROM plus CHR ROM,
excluding the container header and trainer. Permit multiple ROM hashes to share
one profile so verified regional or header variants do not duplicate emitter
definitions.

An emitter rule can match these sources:

```elixir
%{
  id: :castle_torch,
  source: %{
    layer: :background,
    chr_tiles: [0x184, 0x185],
    color_slots: [2, 3],
    subpalettes: [2],
    palette_signatures: [[0x0F, 0x06, 0x17, 0x27]]
  },
  context: %{
    all: [
      %{memory: :ram, address: 0x074E, mask: 0xFF, values: [3, 4]}
    ]
  },
  light: %{radius: 14, strength: 1.25, tint: :source}
}
```

`chr_tiles` are physical, mapper-resolved CHR tile identities rather than raw
nametable or OAM tile numbers. `color_slots` select the emitting two-bit pattern
values inside the tile, before palette lookup. This allows palette animation to
change the emitted color naturally while non-emitting pixels in the same tile
remain dark.

Match and refine an emitter in this order:

1. ROM profile and, when documented, the logical ROM structure that produced
   the artwork: screen, column, room, macro, square, metatile, or object ID.
2. Rendering layer and physical CHR tile or content identity.
3. Pattern color slot within the tile.
4. Background or sprite subpalette.
5. Optional resolved four-color palette signature.
6. Optional nametable address, logical world-tile region, or OAM provenance.
7. Selected CPU RAM or work-RAM predicates when visually identical uses still
   have different semantics.

#### ROM-layout provenance

Prefer published ROM maps and verified disassemblies over inferred RAM
correlations when they identify the level-data structures that generate the
visible scene. A profile may declare version-specific decoders for screen,
column, room, macro, square, metatile, palette-assignment, and object tables.
These logical identities survive graphical reuse and express the game's own
content model more directly than a screen position or palette coincidence.

The archived Data Crystal Legend of Zelda ROM map is the model for this input.
It identifies the overworld screen and column tables, dungeon rooms and macro
definitions, primary and secondary square tables, secret-square definitions,
and item-palette assignments. Combined with the current map-location and room
state from RAM, those tables can classify the logical source of a visible tile
before matching its emitting pattern color slots.

This is essential for CHR-RAM games such as The Legend of Zelda. A PPU tile
number in those games names a mutable upload slot rather than a stable piece of
artwork. Match such games by logical ROM content identity and, where necessary,
the hash of the decoded pattern bytes. Continue to use mapper-resolved physical
CHR identities for CHR-ROM games where they are stable.

ROM-map offsets must be normalized into parsed cartridge address spaces rather
than applied blindly to a headered `.nes` file. Tie every layout decoder to the
exact supported ROM hashes, retain its source URL and revision, and validate
decoded structures against observed nametable output before allowing its rules
to ship.

The palette dimensions are required for reused NES artwork. For example, Super
Mario Bros. uses the same CHR artwork for clouds and bushes. The selected
subpalette or resolved palette signature should distinguish those uses without
requiring a brightness heuristic. RAM predicates are reserved for cases where
tile, layer, palette, and spatial provenance are still identical.

At frame completion, evaluate only the manifest's declared memory predicates
using pure bus peeks and compile the result into a compact active-rule bitset.
Do not copy the full CPU address space into the renderer. Pass the bitset to the
frame-wide compositor, which has the physical background and sprite references,
pattern values, palette attributes, and visibility information needed to build
an emissive plane.

Emission must participate in the same background/sprite clipping and priority
selection as color. A covered source pixel must not glow through the winning
pixel. Blur the final visible 256x240 emissive plane, tint it from the live
palette snapshot, and composite the result into presentation RGB before Scenic
scaling. Support a Config menu toggle and a diagnostic mask-only view.

#### Lighting manifest authoring tools

Provide an inspector so manifests can be authored and validated without manual
PPU trace analysis. Clicking a rendered pixel should report and copy:

- Background or sprite layer.
- Physical CHR tile and row reference.
- Pattern color slot, subpalette, palette address, and resolved master color.
- The complete resolved four-color palette signature.
- Nametable address or OAM index and the screen coordinate.
- The currently active context predicates.

The inspector should highlight every visible use of the selected tile, allow
successive filters for palette and source location, collect animation-frame
tiles observed at one location, and export a manifest-rule stub. A recording
validation mode should capture or count every match so false positives can be
found across representative gameplay.

When visual provenance cannot separate positive and negative examples, support
a RAM-correlation workflow:

1. Capture several frames marked `emits` and `does_not_emit`.
2. Compare internal RAM and relevant work RAM across the two sets.
3. Rank addresses whose masked values consistently distinguish the sets while
   rejecting counters and other values unstable within positive samples.
4. Validate candidate predicates over a longer recording before exporting them
   to the manifest.

Profiles are tied to exact ROM hashes, so discovered RAM addresses and semantic
values are never assumed to transfer silently between ROM revisions.

### Status bar

Display:

- Actual emulator rendering FPS, or `FPS --` while idle.
- The current ROM basename, or `ROM: none`.
- Controller connection state.
- Temporary loading, saved, cancelled, and error messages.

## Native file-dialog boundary

Keep the Elixir-facing API deliberately small:

```elixir
Beamicom.Scenic.FileDialog.open(filters, initial_directory)
#=> {:ok, absolute_path} | :cancel | {:error, reason}

Beamicom.Scenic.FileDialog.save(filters, initial_directory, default_name)
#=> {:ok, absolute_path} | :cancel | {:error, reason}
```

It has no Rust dependency or Rust toolchain requirement:

- macOS uses a C NIF to launch an isolated `NSOpenPanel` or `NSSavePanel`
  helper executable, keeping AppKit on that process's main thread.
- Linux launches Zenity as an isolated port process. GTK must not run inside the
  BEAM after direct calls proved capable of hanging and crashing the VM.

The native boundary only gathers options and returns a UTF-8 path. Elixir code
remains responsible for validation, ROM reads, state encoding, and file writes.

Dialog calls are invoked through a supervised, unlinked task. This keeps the
Scenic scene responsive and allows the background animation to continue while a
dialog is open.

### File-dialog spike

Complete this before the larger lifecycle refactor. Scenic's GLFW window is
owned by the local driver's external port process. Consequently, the first spike
must verify on both macOS and Linux:

- The dialog opens in the foreground.
- Cancellation returns `:cancel` without logging an error.
- Unicode paths round-trip correctly.
- Focus returns to the Scenic window.
- Opening and closing repeatedly does not leak native resources.
- macOS does not create confusing application activation or Dock behavior.

An unparented dialog is acceptable for the first version if it reliably appears
in the foreground. If macOS cannot provide acceptable behavior from the BEAM
process, revisit the boundary before proceeding; do not spread platform-specific
workarounds into Scenic scenes.

## Command flow

### Load

1. Enter `:loading` and show a status message.
2. Start the open-dialog task with filters for `.nes`, `.gb`, `.gbc`, and
   supported save-state PNGs.
3. On cancellation, restore the prior UI state.
4. On selection, validate through `Beamicom.Scenic.Core` and ask the session
   manager to replace the active session.
5. Show the first frame and enter the HUD-free `:running` view.

### Run and menu pause

1. Escape from gameplay pauses the runtime and enters `:menu_paused`.
2. Escape again, or `Run`, resumes the runtime and returns to the HUD-free
   `:running` view.
3. Controller inputs are cleared when entering the menu so no button remains
   logically held.

### Reset

Stop the active session and construct a new one from the same path and options.
The shell and viewport remain alive throughout the reset.

### Save state

1. Snapshot the active runtime.
2. Open the native save selector with a generated default name.
3. Encode and write the save in an Elixir task.
4. Report success or failure in the status bar.

### Load state

Open the native selector, identify the selected save through the core registry,
and replace the current session after successful validation. A failed load must
leave the previous session usable.

## Delivery phases

### Phase 0: Native-dialog proof

- [x] Add the FileDialog facade and native platform boundary.
- [x] Implement `open` and `save` results, filters, and initial directory.
- [x] Add an injectable fake implementation for Elixir tests.
- [ ] Verify macOS behavior manually.
- [ ] Verify Linux GTK behavior manually.

### Phase 1: Long-lived shell

- [x] Add an application entry point that can start without a ROM.
- [x] Add the fixed logical viewport and shell scene.
- [x] Remove Scenic ownership from `Player`.
- [x] Add the session manager and clean replacement semantics.
- [x] Preserve `play/2` compatibility.

### Phase 2: Visual foundation

- [x] Establish the navy/cyan palette, borders, and typography.
- [x] Build the static background and scanline treatment.
- [x] Add the looping grid, stars, and spaceship animation.
- [x] Add the bottom status bar.

### Phase 3: Menu interaction

- [x] Implement menu components and the declarative menu model.
- [x] Add mouse and keyboard navigation.
- [x] Add gamepad navigation.
- [x] Add state-derived enablement and selection styling.
- [x] Wire Load, Run, and Reset.

### Phase 4: Gameplay integration

- [x] Convert the existing screen into a shell-hosted game surface.
- [x] Implement pause/menu/resume transitions.
- [x] Remove all HUD and animated-background components while gameplay runs.
- [x] Fit NES and Game Boy output within the content area.
- [x] Verify presentation filters and input behavior remain unchanged.

### Phase 5: Save-state workflow

- [x] Wire Save State to the native save dialog.
- [x] Wire Load State to the native open dialog.
- [x] Add F5/F8 quick-save and quick-load handlers for running and paused play.
- [x] Store one quick slot per ROM SHA-256 in the configured state directory.
- [x] Browse ROM-associated state screenshots in a horizontal in-window dialog.
- [x] Keep an Open action for loading arbitrary state images with the native picker.
- [x] Generalize current NES-specific UI save handling where necessary.
- [x] Preserve the active session after cancellation or failed state loading.

### Phase 5a: Persistent configuration

- [x] Persist settings as JSON under the XDG config directory.
- [x] Add a native save-state directory selector.
- [x] Expose separate NES and GBC presentation-filter defaults.
- [x] Apply filter changes to the active matching core without resetting gameplay.
- [x] Apply the integer-scaling preference with resize-driven 1×, 2×, 3×, ... stages.
- [x] Render integer-scaled frames at their final size without fractional texture transforms.
- [x] Persist audio enablement and apply it to newly loaded sessions.
- [x] Preserve explicit `play/2` and `replace/2` option precedence.
- [x] Share the Nintendo NES UI font with `beamicom_phx`.

### Phase 6: ROM-aware emissive lighting

- [ ] Define the versioned ROM lighting-manifest schema and profile lookup.
- [ ] Support versioned ROM-layout decoders and logical screen, room, macro,
  square, metatile, and object identities, beginning with a Zelda ROM-map spike.
- [ ] Retain physical tile, palette, nametable/OAM, and winning-layer provenance
  needed to classify visible emitter pixels.
- [ ] Add the pixel inspector, tile-use highlighting, and manifest-stub export.
- [ ] Add recording validation and RAM-correlation tools for ambiguous reuse.
- [ ] Evaluate declared RAM predicates once per frame and pass an active-rule
  bitset to the renderer.
- [ ] Generate a priority-correct emissive mask and composite configurable blur,
  tint, radius, and strength into Scenic presentation RGB.
- [ ] Add lighting and emissive-mask toggles to the Config menu.
- [ ] Ship at least one verified Castlevania III torch profile and one fixture
  demonstrating palette-disambiguated tile reuse.

### Phase 7: Hardening and documentation

- [x] Route native-window close through owner-controlled emulator cleanup.
- [x] Add lifecycle, reducer, menu-navigation, and animation tests.
- [x] Test repeated load/reset/quit cycles for leaked processes.
- [x] Test dialog cancellation and error paths.
- [x] Measure idle animation overhead and emulator frame pacing.
- [x] Update the Scenic README with graphical startup and controls.
- [x] Capture screenshots for idle, paused-menu, and running states.
- [x] Add a temporary shared-host adapter for visually checking SNES core progress.

Current headless measurements at the 960x800 logical size:

- The 60 FPS animated layer uses about 6.4 million reductions/second after
  moving the static scanline, border, and perspective geometry into a separate
  component (down from about 8.4 million reductions/second).
- The repository NES pacing fixture reports 60.0 presented frames/second at
  normal speed. Presentation fitting uses a Scenic transform so core and filter
  pixel scalers continue receiving supported dimensions.

## Testing strategy

Automated tests should cover:

- Pure background phase, wrapping, trajectory, and depth calculations.
- Menu selection, disabled items, keyboard navigation, and state transitions.
- File-dialog facade behavior with injected success, cancellation, and failure.
- Starting the shell without media.
- Loading a fixture ROM without restarting Scenic.
- Replacing and resetting sessions without leaking runtime, audio, output, or
  input processes.
- Keeping an existing session alive after picker cancellation or load failure.
- Compatibility of `Beamicom.Scenic.play/2`, `status/0`, and `stop/0`.
- ROM hash/profile selection, including multiple hashes sharing one profile.
- ROM-layout offset normalization, table decoding, CHR-RAM content identity,
  and validation of logical structures against observed nametable output.
- Emitter matching by physical tile, layer, pattern slot, subpalette, palette
  signature, spatial provenance, and RAM predicates.
- Background/sprite priority and clipping preventing covered sources from
  contributing to the emissive mask.
- Unmatched and disabled lighting preserving the existing RGB output exactly.
- Inspector export and RAM-correlation rejection of unstable candidate values.

Manual platform checks should cover native dialog behavior, focus restoration,
resizing, keyboard shortcuts, gamepad navigation, and visual animation quality
on macOS and Linux.

## Acceptance criteria

- The application opens to a functional animated menu without requiring a ROM.
- The background loops without a visible jump and does not rebuild its static
  graph on every frame.
- The native picker opens without blocking the Scenic UI.
- Loading, resetting, or replacing a game never recreates the application
  window.
- Escape pauses gameplay and displays the menu; Run resumes cleanly.
- Running gameplay has no menu, status bar, logo, or background animation;
  Escape pauses and restores them, then Escape resumes and removes them again.
- Save/load cancellation is harmless and failed loads preserve the active game.
- Repeated session changes leave no orphaned audio, runtime, output, or input
  processes.
- Existing NES and Game Boy frame pacing, filters, and controls continue to
  pass their tests.
- Lighting never activates from brightness alone, and unmatched ROMs retain the
  unmodified presentation path.
- A verified torch profile emits only from its declared tile color slots and
  follows animation, scrolling, palette changes, clipping, and occlusion.
- Palette or context predicates distinguish reused tile artwork without causing
  known false positives in the profile's validation recording.

## Decisions recorded

- Menus are Scenic-drawn rather than native operating-system menus.
- File selectors are native: a C NIF with an isolated AppKit helper on macOS
  and an isolated Zenity process on Linux.
- macOS and Linux are the only supported desktop targets for this work.
- The Scenic window is long-lived; emulator sessions are replaceable.
- Background motion is time-based and uses Scenic vector primitives.
- Emissive lighting is opt-in, ROM-specific presentation metadata rather than a
  change to emulation or a generic bright-pixel effect.
- Emitter classification uses rendering provenance first and declared game RAM
  only when visual and spatial provenance cannot distinguish semantic reuse.
