import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
    case displayPreview
    case frontmostWindowFullscreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .displayPreview:
            return "Monitor"
        case .frontmostWindowFullscreen:
            return "Selected Window"
        }
    }

    var summary: String {
        switch self {
        case .displayPreview:
            return "Capture one monitor and show it in a delayed output window."
        case .frontmostWindowFullscreen:
            return "Capture a selected app window and show it in a delayed output window."
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let minimumDelay = 0
    static let maximumDelay = 10_000
    static let minimumLiveModeGracePeriodSeconds = 1
    static let maximumLiveModeGracePeriodSeconds = 30

    @Published var delayMilliseconds: Int {
        didSet {
            let clamped = Self.clamp(delayMilliseconds)
            if clamped != delayMilliseconds {
                delayMilliseconds = clamped
                return
            }

            userDefaults.set(clamped, forKey: Self.delayKey)
        }
    }

    @Published var captureMode: CaptureMode {
        didSet {
            userDefaults.set(captureMode.rawValue, forKey: Self.captureModeKey)
        }
    }

    @Published var selectedWindowID: Int? {
        didSet {
            if let selectedWindowID {
                userDefaults.set(selectedWindowID, forKey: Self.selectedWindowIDKey)
            } else {
                userDefaults.removeObject(forKey: Self.selectedWindowIDKey)
            }
        }
    }

    @Published var selectedDisplayID: Int? {
        didSet {
            if let selectedDisplayID {
                userDefaults.set(selectedDisplayID, forKey: Self.selectedDisplayIDKey)
            } else {
                userDefaults.removeObject(forKey: Self.selectedDisplayIDKey)
            }
        }
    }

    @Published var showsDebugHUD: Bool {
        didSet {
            userDefaults.set(showsDebugHUD, forKey: Self.showsDebugHUDKey)
        }
    }

    @Published var keepsOverlayOnTop: Bool {
        didSet {
            userDefaults.set(keepsOverlayOnTop, forKey: Self.keepsOverlayOnTopKey)
        }
    }

    @Published var liveModeOnKeyPressEnabled: Bool {
        didSet {
            userDefaults.set(liveModeOnKeyPressEnabled, forKey: Self.liveModeOnKeyPressEnabledKey)
        }
    }

    @Published var liveModeGracePeriodSeconds: Int {
        didSet {
            let clamped = Self.clampLiveModeGracePeriod(liveModeGracePeriodSeconds)
            if clamped != liveModeGracePeriodSeconds {
                liveModeGracePeriodSeconds = clamped
                return
            }

            userDefaults.set(clamped, forKey: Self.liveModeGracePeriodSecondsKey)
        }
    }

    private let userDefaults: UserDefaults
    private static let delayKey = "delayMilliseconds"
    private static let captureModeKey = "captureMode"
    private static let selectedWindowIDKey = "selectedWindowID"
    private static let selectedDisplayIDKey = "selectedDisplayID"
    private static let showsDebugHUDKey = "showsDebugHUD"
    private static let keepsOverlayOnTopKey = "keepsOverlayOnTop"
    private static let liveModeOnKeyPressEnabledKey = "liveModeOnKeyPressEnabled"
    private static let liveModeGracePeriodSecondsKey = "liveModeGracePeriodSeconds"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedValue = userDefaults.object(forKey: Self.delayKey) as? Int ?? 2_000
        self.delayMilliseconds = Self.clamp(storedValue)
        let storedCaptureMode = userDefaults.string(forKey: Self.captureModeKey)
        self.captureMode = CaptureMode(rawValue: storedCaptureMode ?? "") ?? .displayPreview
        self.selectedWindowID = userDefaults.object(forKey: Self.selectedWindowIDKey) as? Int
        self.selectedDisplayID = userDefaults.object(forKey: Self.selectedDisplayIDKey) as? Int
        if userDefaults.object(forKey: Self.showsDebugHUDKey) == nil {
            self.showsDebugHUD = true
        } else {
            self.showsDebugHUD = userDefaults.bool(forKey: Self.showsDebugHUDKey)
        }
        if userDefaults.object(forKey: Self.keepsOverlayOnTopKey) == nil {
            self.keepsOverlayOnTop = false
        } else {
            self.keepsOverlayOnTop = userDefaults.bool(forKey: Self.keepsOverlayOnTopKey)
        }
        if userDefaults.object(forKey: Self.liveModeOnKeyPressEnabledKey) == nil {
            self.liveModeOnKeyPressEnabled = false
        } else {
            self.liveModeOnKeyPressEnabled = userDefaults.bool(forKey: Self.liveModeOnKeyPressEnabledKey)
        }
        let storedLiveModeGracePeriod = userDefaults.object(forKey: Self.liveModeGracePeriodSecondsKey) as? Int ?? 4
        self.liveModeGracePeriodSeconds = Self.clampLiveModeGracePeriod(storedLiveModeGracePeriod)
    }

    func setDelay(_ value: Int) {
        delayMilliseconds = Self.clamp(value)
    }

    func setSelectedWindowID(_ value: Int?) {
        selectedWindowID = value
    }

    func setSelectedDisplayID(_ value: Int?) {
        selectedDisplayID = value
    }

    func setLiveModeGracePeriodSeconds(_ value: Int) {
        liveModeGracePeriodSeconds = Self.clampLiveModeGracePeriod(value)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, minimumDelay), maximumDelay)
    }

    private static func clampLiveModeGracePeriod(_ value: Int) -> Int {
        min(max(value, minimumLiveModeGracePeriodSeconds), maximumLiveModeGracePeriodSeconds)
    }
}
