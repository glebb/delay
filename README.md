# DelayDisplay

DelayDisplay is a native macOS app with a Dock icon and companion menu bar control that captures either a selected monitor or a specific window, buffers frames in memory, and presents them with delay. The current implementation supports a delayed monitor window, a delayed selected-window output, and an optional always-on-top presentation setting.

## Current status

- Menu bar app shell with start, stop, settings, and quit actions
- Delay setting stored in `UserDefaults` and constrained to `0...10000` milliseconds
- Capture mode setting for monitor or selected-window capture
- Monitor picker for monitor capture, persisted in `UserDefaults`
- Refreshable window picker for choosing the app window used by selected-window capture
- Optional debug HUD toggle for the delayed output window
- Optional always-on-top toggle for keeping the delayed window above normal app windows in the current Space
- Optional temporary live-mode toggle that forces 0 ms delay while keys are pressed in another app, then restores the configured delay after a user-configurable inactivity grace period once Accessibility access is granted
- Direct `CGImage` rendering in the output window to avoid per-frame `NSImage` conversion overhead
- Debug HUD instrumentation for buffered span and effective emitted delay
- Capture tuned for smoother playback with a 60 fps target plus capped capture resolution to limit pixel workload
- Screen recording permission wrapper via CoreGraphics
- ScreenCaptureKit bootstrap that resolves the selected display for preview mode and excludes the app's own process from capture
- ScreenCaptureKit stream output converted into delayed image updates
- In-memory frame buffer keyed by presentation timestamps
- Movable delayed window for monitor capture and delayed output window for selected-window capture
- Optional always-on-top window level for both presentation modes within the active Space
- Preview windows open on the selected monitor in that monitor's active Space; native macOS fullscreen Spaces remain isolated
- Emergency Escape shortcut and preview-window close button both stop delayed output
- Optional global key activity monitoring for temporary live mode while another app has focus, which requires Accessibility access and still may not detect some macOS system shortcuts

## Project structure

- `project.yml`: XcodeGen specification for the macOS app target
- `DelayDisplay/App`: application lifecycle and coordinator
- `DelayDisplay/MenuBar`: status item and menu wiring
- `DelayDisplay/Settings`: settings persistence and SwiftUI settings view
- `DelayDisplay/Capture`: permissions, ScreenCaptureKit bootstrap, source selection, and frame processing pipeline
- `DelayDisplay/Buffer`: timestamp-based frame ring buffer
- `DelayDisplay/Render`: delayed preview window, fullscreen presentation, and delayed image view

## Build

1. Generate the Xcode project:

   ```sh
   xcodegen generate
   ```

2. Build from the command line:

   ```sh
   xcodebuild -project DelayDisplay.xcodeproj -scheme DelayDisplay -configuration Debug build
   ```

3. Build a workspace-local app bundle you can launch directly:

   ```sh
   xcodebuild -project DelayDisplay.xcodeproj -scheme DelayDisplay -configuration Debug CONFIGURATION_BUILD_DIR="$PWD/build/Debug" build
   ```

4. Launch the app bundle:

   ```sh
   open build/Debug/DelayDisplay.app
   ```

## Next implementation slice

- Add a user-facing quality/performance mode so capture size and frame rate can be tuned explicitly
- Consider a Spaces policy for preview windows, such as optional all-Spaces behavior vs. keeping the current active-Space-only model
- Extend soak-test instrumentation with long-run frame pacing and dropped-frame trends
- Tune frame pacing and verify effective delay on real hardware at 60 fps