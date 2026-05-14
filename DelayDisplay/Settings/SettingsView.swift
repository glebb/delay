import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var coordinator: DelayCoordinator

    @State private var draftDelay = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                captureSection

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        leftColumn
                        rightColumn
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        leftColumn
                        rightColumn
                    }
                }

                runtimeSection
                actionSection
            }
            .padding(18)
            .frame(minWidth: 660, idealWidth: 720, maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            draftDelay = String(settingsStore.delayMilliseconds)
        }
        .onChange(of: settingsStore.delayMilliseconds) { newValue in
            draftDelay = String(newValue)
        }
        .task(id: settingsStore.captureMode) {
            switch settingsStore.captureMode {
            case .displayPreview:
                await coordinator.refreshAvailableDisplays()
            case .frontmostWindowFullscreen:
                await coordinator.refreshAvailableWindows()
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DelayDisplay")
                .font(.title2.weight(.semibold))

            Text("Choose what DelayDisplay captures, set the delay amount, and control how the delayed window behaves.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var captureSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Source", selection: $settingsStore.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settingsStore.captureMode.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch settingsStore.captureMode {
                case .displayPreview:
                    previewDisplayPicker
                case .frontmostWindowFullscreen:
                    windowPicker
                }
            }
        } label: {
            sectionTitle("Capture")
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            delaySection
            qualitySection
            presentationSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            liveModeSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var delaySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    TextField("Delay", text: $draftDelay)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                        .onSubmit(applyDraftDelay)

                    Slider(
                        value: Binding(
                            get: { Double(settingsStore.delayMilliseconds) },
                            set: { settingsStore.setDelay(Int($0.rounded())) }
                        ),
                        in: Double(SettingsStore.minimumDelay)...Double(SettingsStore.maximumDelay),
                        step: 50
                    )

                    Text("\(settingsStore.delayMilliseconds) ms")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 96, alignment: .trailing)
                }

                Text("Range: 0 - 10000 ms")
                    .foregroundStyle(.secondary)
            }
        } label: {
            sectionTitle("Delay")
        }
    }

    private var presentationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show debug HUD", isOn: $settingsStore.showsDebugHUD)

                Toggle("Keep delay window above other apps", isOn: $settingsStore.keepsOverlayOnTop)

                Text("Applies in the current Space only. Native macOS fullscreen Spaces stay isolated, so DelayDisplay does not pin itself above them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            sectionTitle("Presentation")
        }
    }

    private var qualitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Playback quality", selection: $settingsStore.captureQualityPreset) {
                    ForEach(CaptureQualityPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(settingsStore.captureQualityPreset.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            sectionTitle("Smoothness")
        }
    }

    private var liveModeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Temporarily switch to live mode while typing", isOn: $settingsStore.liveModeOnKeyPressEnabled)

                Stepper(
                    value: Binding(
                        get: { settingsStore.liveModeGracePeriodSeconds },
                        set: { settingsStore.setLiveModeGracePeriodSeconds($0) }
                    ),
                    in: SettingsStore.minimumLiveModeGracePeriodSeconds...SettingsStore.maximumLiveModeGracePeriodSeconds
                ) {
                    Text("Live mode grace period: \(settingsStore.liveModeGracePeriodSeconds) \(liveModeGracePeriodUnit)")
                }

                Text("When enabled, key presses in the focused app temporarily force 0 ms delay. DelayDisplay returns to the configured delay after \(settingsStore.liveModeGracePeriodSeconds) \(liveModeGracePeriodUnit) without new key presses. Detecting typing in other apps requires Accessibility access, and some macOS system shortcuts may still not be detected.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            sectionTitle("Live Mode")
        }
    }

    private var runtimeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(coordinator.statusLine)

                if let lastErrorMessage = coordinator.lastErrorMessage {
                    Text(lastErrorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } label: {
            sectionTitle("Runtime")
        }
    }

    private var actionSection: some View {
        HStack {
            Button(coordinator.isRunning ? "Stop" : "Start") {
                coordinator.toggleRunning()
            }
            .keyboardShortcut(.defaultAction)

            Spacer()
        }
    }

    private var previewDisplayPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Picker(
                    "Monitor",
                    selection: Binding(
                        get: { settingsStore.selectedDisplayID },
                        set: { settingsStore.setSelectedDisplayID($0) }
                    )
                ) {
                    ForEach(coordinator.availableDisplays) { display in
                        Text(display.displayName).tag(Optional(display.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(coordinator.availableDisplays.isEmpty)

                Button(coordinator.isRefreshingDisplays ? "Refreshing…" : "Refresh") {
                    Task {
                        await coordinator.refreshAvailableDisplays(requestPermission: true)
                    }
                }
                .disabled(coordinator.isRefreshingDisplays)
            }

            if let selectedDisplay = selectedDisplay {
                Text("Selected: \(selectedDisplay.displayName) • \(selectedDisplay.detail). The delayed window opens in that monitor's active Space.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let displaySelectionMessage = coordinator.displaySelectionMessage {
                Text(displaySelectionMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Text("Selected: \(selectedWindow.displayName) • \(selectedWindow.detail). DelayDisplay shows this source in a separate delayed window.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let windowSelectionMessage = coordinator.windowSelectionMessage {
                Text(windowSelectionMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedWindow: CapturedWindowOption? {
        guard let selectedWindowID = settingsStore.selectedWindowID else {
            return nil
        }

        return coordinator.availableWindows.first { $0.id == selectedWindowID }
    }

    private var selectedDisplay: CapturedDisplayOption? {
        guard let selectedDisplayID = settingsStore.selectedDisplayID else {
            return nil
        }

        return coordinator.availableDisplays.first { $0.id == selectedDisplayID }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
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
