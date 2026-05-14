import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var coordinator: DelayCoordinator

    @State private var draftDelay = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DelayDisplay")
                .font(.title2.weight(.semibold))

            Text("Configure the delayed source and presentation mode. On a single monitor, fullscreen replay is only practical for a specific app window; display capture remains available in preview mode.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Capture mode")
                    .font(.headline)

                Picker("Capture mode", selection: $settingsStore.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settingsStore.captureMode.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settingsStore.captureMode == .frontmostWindowFullscreen {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Window")
                        .font(.headline)

                    HStack(alignment: .center, spacing: 12) {
                        Picker(
                            "Window",
                            selection: Binding(
                                get: { settingsStore.selectedWindowID },
                                set: { settingsStore.setSelectedWindowID($0) }
                            )
                        ) {
                            ForEach(coordinator.availableWindows) { window in
                                Text(window.displayName).tag(Optional(window.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .disabled(coordinator.availableWindows.isEmpty)

                        Button(coordinator.isRefreshingWindows ? "Refreshing…" : "Refresh") {
                            Task {
                                await coordinator.refreshAvailableWindows(requestPermission: true)
                            }
                        }
                        .disabled(coordinator.isRefreshingWindows)
                    }

                    if let selectedWindow = selectedWindow {
                        Text("Selected: \(selectedWindow.displayName) • \(selectedWindow.detail)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let windowSelectionMessage = coordinator.windowSelectionMessage {
                        Text(windowSelectionMessage)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Delay (milliseconds)")
                    .font(.headline)

                HStack(spacing: 12) {
                    TextField("Delay", text: $draftDelay)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                        .onSubmit(applyDraftDelay)

                    Text("0 - 10000")
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(settingsStore.delayMilliseconds) },
                        set: { settingsStore.setDelay(Int($0.rounded())) }
                    ),
                    in: Double(SettingsStore.minimumDelay)...Double(SettingsStore.maximumDelay),
                    step: 50
                )

                Text("Current delay: \(settingsStore.delayMilliseconds) ms")
                    .font(.system(.body, design: .monospaced))
            }

            Toggle("Show debug HUD", isOn: $settingsStore.showsDebugHUD)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Keep delay window above other apps", isOn: $settingsStore.keepsOverlayOnTop)

                Text("Applies in the current Space only. Native macOS fullscreen Spaces are not pinned above other apps.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Temporarily switch to live mode while typing", isOn: $settingsStore.liveModeOnKeyPressEnabled)

                Text("When enabled, key presses in the focused app temporarily force 0 ms delay. DelayDisplay returns to the configured delay after \(settingsStore.liveModeGracePeriodSeconds) \(liveModeGracePeriodUnit) without new key presses. Detecting typing in other apps requires Accessibility access, and some macOS system shortcuts may still not be detected.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Stepper(
                    value: Binding(
                        get: { settingsStore.liveModeGracePeriodSeconds },
                        set: { settingsStore.setLiveModeGracePeriodSeconds($0) }
                    ),
                    in: SettingsStore.minimumLiveModeGracePeriodSeconds...SettingsStore.maximumLiveModeGracePeriodSeconds
                ) {
                    Text("Live mode grace period: \(settingsStore.liveModeGracePeriodSeconds) \(liveModeGracePeriodUnit)")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Runtime")
                    .font(.headline)
                Text(coordinator.statusLine)
                if let lastErrorMessage = coordinator.lastErrorMessage {
                    Text(lastErrorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button(coordinator.isRunning ? "Stop" : "Start") {
                    coordinator.toggleRunning()
                }
                .keyboardShortcut(.defaultAction)

                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear {
            draftDelay = String(settingsStore.delayMilliseconds)
        }
        .onChange(of: settingsStore.delayMilliseconds) { newValue in
            draftDelay = String(newValue)
        }
        .task(id: settingsStore.captureMode) {
            guard settingsStore.captureMode == .frontmostWindowFullscreen else {
                return
            }

            await coordinator.refreshAvailableWindows()
        }
    }

    private var selectedWindow: CapturedWindowOption? {
        guard let selectedWindowID = settingsStore.selectedWindowID else {
            return nil
        }

        return coordinator.availableWindows.first { $0.id == selectedWindowID }
    }

    private func applyDraftDelay() {
        let parsedDelay = Int(draftDelay) ?? settingsStore.delayMilliseconds
        settingsStore.setDelay(parsedDelay)
        draftDelay = String(settingsStore.delayMilliseconds)
    }

    private var liveModeGracePeriodUnit: String {
        settingsStore.liveModeGracePeriodSeconds == 1 ? "second" : "seconds"
    }
}
