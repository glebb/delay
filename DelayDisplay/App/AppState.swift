import Combine
import Foundation

@MainActor
final class AppState {
    static let shared = AppState()

    let model: AppModel

    private init() {
        let settingsStore = SettingsStore()
        let coordinator = DelayCoordinator(
            settingsStore: settingsStore,
            permissionsService: PermissionsService(),
            screenCaptureService: ScreenCaptureService(),
            overlayWindowController: OverlayWindowController()
        )
        let settingsWindowController = SettingsWindowController(
            settingsStore: settingsStore,
            coordinator: coordinator
        )
        model = AppModel(
            settingsStore: settingsStore,
            coordinator: coordinator,
            settingsWindowController: settingsWindowController
        )
    }
}

@MainActor
final class AppModel: ObservableObject {
    let settingsStore: SettingsStore
    let coordinator: DelayCoordinator
    private let settingsWindowController: SettingsWindowController

    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: SettingsStore,
        coordinator: DelayCoordinator,
        settingsWindowController: SettingsWindowController
    ) {
        self.settingsStore = settingsStore
        self.coordinator = coordinator
        self.settingsWindowController = settingsWindowController

        // Each applied delay change flushes the renderer, so a slider drag is applied once it
        // settles rather than at every step.
        settingsStore.$delayMilliseconds
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedDelay()
            }
            .store(in: &cancellables)

        settingsStore.$captureMode
            .dropFirst()
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedCaptureConfiguration()
            }
            .store(in: &cancellables)

        settingsStore.$captureQualityPreset
            .dropFirst()
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedCaptureConfiguration()
            }
            .store(in: &cancellables)

        settingsStore.$selectedWindowID
            .dropFirst()
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedCaptureConfiguration()
            }
            .store(in: &cancellables)

        settingsStore.$selectedDisplayID
            .dropFirst()
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedCaptureConfiguration()
            }
            .store(in: &cancellables)

        settingsStore.$showsDebugHUD
            .dropFirst()
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedPresentationSettings()
            }
            .store(in: &cancellables)

        settingsStore.$keepsOverlayOnTop
            .dropFirst()
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedPresentationSettings()
            }
            .store(in: &cancellables)

        settingsStore.$liveModeOnKeyPressEnabled
            .dropFirst()
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedKeyboardActivitySetting()
            }
            .store(in: &cancellables)

        settingsStore.$liveModeGracePeriodSeconds
            .dropFirst()
            .sink { [weak coordinator] _ in
                coordinator?.applyUpdatedLiveModeGracePeriod()
            }
            .store(in: &cancellables)
    }

    func showSettingsWindow() {
        settingsWindowController.showSettingsWindow()
    }
}
