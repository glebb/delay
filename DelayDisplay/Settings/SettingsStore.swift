import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
    case displayPreview
    case frontmostWindowFullscreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .displayPreview:
            return "Display preview"
        case .frontmostWindowFullscreen:
            return "Selected window fullscreen"
        }
    }

    var summary: String {
        switch self {
        case .displayPreview:
            return "Reliable on one monitor; shows a movable delayed preview window."
        case .frontmostWindowFullscreen:
            return "Captures a selected app window and replays it fullscreen with delay."
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let minimumDelay = 0
    static let maximumDelay = 10_000

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

    private let userDefaults: UserDefaults
    private static let delayKey = "delayMilliseconds"
    private static let captureModeKey = "captureMode"
    private static let selectedWindowIDKey = "selectedWindowID"
    private static let showsDebugHUDKey = "showsDebugHUD"
    private static let keepsOverlayOnTopKey = "keepsOverlayOnTop"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedValue = userDefaults.object(forKey: Self.delayKey) as? Int ?? 2_000
        self.delayMilliseconds = Self.clamp(storedValue)
        let storedCaptureMode = userDefaults.string(forKey: Self.captureModeKey)
        self.captureMode = CaptureMode(rawValue: storedCaptureMode ?? "") ?? .displayPreview
        self.selectedWindowID = userDefaults.object(forKey: Self.selectedWindowIDKey) as? Int
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
    }

    func setDelay(_ value: Int) {
        delayMilliseconds = Self.clamp(value)
    }

    func setSelectedWindowID(_ value: Int?) {
        selectedWindowID = value
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, minimumDelay), maximumDelay)
    }
}
