import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct CapturedDisplayOption: Identifiable, Equatable {
    let displayID: CGDirectDisplayID
    let name: String
    let frameSize: CGSize

    var id: Int { Int(displayID) }

    var displayName: String {
        name
    }

    var detail: String {
        "\(Int(frameSize.width.rounded())) x \(Int(frameSize.height.rounded()))"
    }
}

struct CapturedWindowOption: Identifiable, Equatable {
    let windowID: CGWindowID
    let applicationName: String
    let title: String
    let frame: CGRect

    var id: Int { Int(windowID) }

    var displayName: String {
        if title.isEmpty {
            return applicationName
        }

        return "\(applicationName) - \(title)"
    }

    var detail: String {
        "\(Int(frame.width.rounded())) x \(Int(frame.height.rounded()))"
    }
}

struct CaptureBootstrap {
    let displayID: CGDirectDisplayID
    let frameSize: CGSize
    let display: SCDisplay?
    let window: SCWindow?
}

enum ScreenCaptureServiceError: LocalizedError {
    case noDisplaysFound
    case noActiveBootstrap
    case noEligibleWindowsFound
    case selectedDisplayUnavailable
    case selectedWindowUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplaysFound:
            return "No shareable display was found for capture."
        case .noActiveBootstrap:
            return "Capture was started before a display bootstrap was prepared."
        case .noEligibleWindowsFound:
            return "No eligible app windows were available to capture. Open the target window and refresh the list."
        case .selectedDisplayUnavailable:
            return "The selected monitor is no longer available. Refresh the monitor list and choose it again."
        case .selectedWindowUnavailable:
            return "The selected window is no longer available. Refresh the window list and choose it again."
        }
    }
}

@MainActor
final class ScreenCaptureService {
    private static let previewMaximumCaptureSize = CGSize(width: 1920, height: 1080)
    private static let windowMaximumCaptureSize = CGSize(width: 1600, height: 900)
    private static let opaqueBlackBackgroundColor = CGColor(gray: 0, alpha: 1)

    private(set) var activeBootstrap: CaptureBootstrap?
    private var stream: SCStream?
    private var outputHandler: ScreenStreamOutputHandler?
    private var capturePipeline: CapturePipeline?
    private let sampleHandlerQueue = DispatchQueue(label: "DelayDisplay.ScreenCapture.Video")

    func availableDisplays() async throws -> [CapturedDisplayOption] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.enumerated().map { index, display in
            makeCapturedDisplayOption(from: display, fallbackIndex: index)
        }
    }

    func availableWindows(excludingBundleIdentifier bundleIdentifier: String?) async throws -> [CapturedWindowOption] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return orderedEligibleWindows(from: content.windows, excludingBundleIdentifier: bundleIdentifier).map { window in
            CapturedWindowOption(
                windowID: window.windowID,
                applicationName: window.owningApplication?.applicationName ?? "Unknown App",
                title: window.title ?? "",
                frame: window.frame
            )
        }
    }

    func prepareBootstrap(
        excludingBundleIdentifier bundleIdentifier: String?,
        captureMode: CaptureMode,
        selectedDisplayID: Int?,
        selectedWindowID: Int?
    ) async throws -> CaptureBootstrap {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let bootstrap: CaptureBootstrap
        switch captureMode {
        case .displayPreview:
            let display: SCDisplay
            if let selectedDisplayID {
                guard let matchingDisplay = content.displays.first(where: { Int($0.displayID) == selectedDisplayID }) else {
                    throw ScreenCaptureServiceError.selectedDisplayUnavailable
                }

                display = matchingDisplay
            } else if let firstDisplay = content.displays.first {
                display = firstDisplay
            } else {
                throw ScreenCaptureServiceError.noDisplaysFound
            }

            let displaySize = CGSize(width: display.width, height: display.height)

            bootstrap = CaptureBootstrap(
                displayID: display.displayID,
                frameSize: fittedCaptureSize(for: displaySize, maximumSize: Self.previewMaximumCaptureSize),
                display: display,
                window: nil
            )
        case .frontmostWindowFullscreen:
            let windows = orderedEligibleWindows(from: content.windows, excludingBundleIdentifier: bundleIdentifier)

            let window: SCWindow
            if let selectedWindowID {
                guard let selectedWindow = windows.first(where: { Int($0.windowID) == selectedWindowID }) else {
                    throw ScreenCaptureServiceError.selectedWindowUnavailable
                }

                window = selectedWindow
            } else if let frontmostWindow = windows.first {
                window = frontmostWindow
            } else {
                throw ScreenCaptureServiceError.noEligibleWindowsFound
            }

            let targetSize = fittedCaptureSize(for: window.frame.size, maximumSize: Self.windowMaximumCaptureSize)

            bootstrap = CaptureBootstrap(
                displayID: CGMainDisplayID(),
                frameSize: targetSize,
                display: nil,
                window: window
            )
        }

        activeBootstrap = bootstrap
        return bootstrap
    }

    func startCapture(
        bootstrap: CaptureBootstrap,
        delayMilliseconds: Int,
        excludingBundleIdentifier bundleIdentifier: String?,
        overlayWindowID: CGWindowID?,
        onDelayedFrame: @escaping DelayedFrameConsumer
    ) async throws {
        stopCapture()

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = Int(bootstrap.frameSize.width)
        streamConfiguration.height = Int(bootstrap.frameSize.height)
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        streamConfiguration.queueDepth = 6
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = false

        if bootstrap.window != nil {
            streamConfiguration.backgroundColor = Self.opaqueBlackBackgroundColor
            streamConfiguration.scalesToFit = true

            if #available(macOS 14.0, *) {
                streamConfiguration.preservesAspectRatio = true
                streamConfiguration.shouldBeOpaque = true
                streamConfiguration.ignoreShadowsSingleWindow = true
            }

            if #available(macOS 14.2, *) {
                streamConfiguration.includeChildWindows = true
            }
        }

        let capturePipeline = CapturePipeline(
            delayMilliseconds: delayMilliseconds,
            frameConsumer: onDelayedFrame
        )
        let outputHandler = ScreenStreamOutputHandler(capturePipeline: capturePipeline)
        let filter = try await makeFilter(
            bootstrap: bootstrap,
            excludingBundleIdentifier: bundleIdentifier,
            overlayWindowID: overlayWindowID
        )
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)

        try stream.addStreamOutput(outputHandler, type: .screen, sampleHandlerQueue: sampleHandlerQueue)
        try await stream.startCapture()

        activeBootstrap = bootstrap
        self.capturePipeline = capturePipeline
        self.outputHandler = outputHandler
        self.stream = stream
    }

    func updateDelay(_ delayMilliseconds: Int) {
        guard let capturePipeline else {
            return
        }

        Task {
            await capturePipeline.updateDelay(delayMilliseconds)
        }
    }

    func stopCapture() {
        let stream = self.stream
        let capturePipeline = self.capturePipeline

        self.stream = nil
        self.outputHandler = nil
        self.capturePipeline = nil
        activeBootstrap = nil

        Task {
            try? await stream?.stopCapture()
            if let capturePipeline {
                await capturePipeline.reset()
            }
        }
    }

    private func makeFilter(
        bootstrap: CaptureBootstrap,
        excludingBundleIdentifier bundleIdentifier: String?,
        overlayWindowID: CGWindowID?
    ) async throws -> SCContentFilter {
        if let window = bootstrap.window {
            return SCContentFilter(desktopIndependentWindow: window)
        }

        guard let display = bootstrap.display else {
            throw ScreenCaptureServiceError.noActiveBootstrap
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        if let overlayWindowID,
           let overlayWindow = content.windows.first(where: { $0.windowID == overlayWindowID }) {
            let belowContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnlyBelow: overlayWindow
            )

            if !belowContent.windows.isEmpty {
                return SCContentFilter(display: display, including: belowContent.windows)
            }
        }

        let excludedApplications: [SCRunningApplication]
        if let bundleIdentifier {
            excludedApplications = content.applications.filter { $0.bundleIdentifier == bundleIdentifier }
        } else {
            excludedApplications = []
        }

        return SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
    }

    private func orderedEligibleWindows(
        from windows: [SCWindow],
        excludingBundleIdentifier bundleIdentifier: String?
    ) -> [SCWindow] {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        var orderedWindows: [SCWindow] = []
        var seenWindowIDs = Set<CGWindowID>()

        if let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for windowInfo in windowInfoList {
                guard let number = windowInfo[kCGWindowNumber as String] as? NSNumber,
                      let layer = windowInfo[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let candidate = windowsByID[CGWindowID(number.uint32Value)],
                      isEligibleWindow(candidate, excludingBundleIdentifier: bundleIdentifier),
                      seenWindowIDs.insert(candidate.windowID).inserted else {
                    continue
                }

                orderedWindows.append(candidate)
            }
        }

        for window in windows where isEligibleWindow(window, excludingBundleIdentifier: bundleIdentifier) {
            if seenWindowIDs.insert(window.windowID).inserted {
                orderedWindows.append(window)
            }
        }

        return orderedWindows
    }

    private func isEligibleWindow(
        _ window: SCWindow,
        excludingBundleIdentifier bundleIdentifier: String?
    ) -> Bool {
        let candidateBundleIdentifier = window.owningApplication?.bundleIdentifier
        if candidateBundleIdentifier == bundleIdentifier || candidateBundleIdentifier == Bundle.main.bundleIdentifier {
            return false
        }

        if window.frame.width < 160 || window.frame.height < 120 {
            return false
        }

        return true
    }

    private func fittedCaptureSize(for sourceSize: CGSize, maximumSize: CGSize) -> CGSize {
        let sourceWidth = max(sourceSize.width, 1)
        let sourceHeight = max(sourceSize.height, 1)

        let widthScale = maximumSize.width / sourceWidth
        let heightScale = maximumSize.height / sourceHeight
        let scale = min(widthScale, heightScale, 1)

        return CGSize(
            width: max((sourceWidth * scale).rounded(.down), 1),
            height: max((sourceHeight * scale).rounded(.down), 1)
        )
    }

    private func makeCapturedDisplayOption(from display: SCDisplay, fallbackIndex: Int) -> CapturedDisplayOption {
        let displayName = NSScreen.screen(withDisplayID: display.displayID)?.localizedName ?? "Display \(fallbackIndex + 1)"

        return CapturedDisplayOption(
            displayID: display.displayID,
            name: displayName,
            frameSize: CGSize(width: display.width, height: display.height)
        )
    }
}

private final class ScreenStreamOutputHandler: NSObject, SCStreamOutput {
    private let capturePipeline: CapturePipeline

    init(capturePipeline: CapturePipeline) {
        self.capturePipeline = capturePipeline
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else {
            return
        }

        Task {
            await capturePipeline.process(sampleBuffer: sampleBuffer)
        }
    }
}

extension NSScreen {
    static func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }

            return CGDirectDisplayID(screenNumber.uint32Value) == displayID
        }
    }
}
