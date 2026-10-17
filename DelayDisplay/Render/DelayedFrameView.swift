import AppKit
import AVFoundation
import Combine
import SwiftUI

struct DelayedFrameView: View {
    @ObservedObject var model: OverlayContentModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            DelayedFrameSurface(model: model)
                .background(Color.black)

            if !model.hasImage {
                VStack(spacing: 16) {
                    Text("DelayDisplay")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("\(model.delayMilliseconds) ms")
                        .font(.system(size: 72, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)

                    Text(model.isWarmingUp ? "Warming up delay buffer" : model.statusLine)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.showsDebugHUD {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DelayDisplay")
                        .font(.headline.weight(.semibold))
                    Text("\(model.delayMilliseconds) ms")
                        .font(.system(.title3, design: .monospaced, weight: .bold))
                    Text(model.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text("quality \(model.debugInfo.qualityPresetDescription)")
                        .font(.system(.caption, design: .monospaced))
                    Text("recv \(model.debugInfo.receivedFrames)  accept \(model.debugInfo.acceptedFrames)  emit \(model.debugInfo.emittedFrames)")
                        .font(.system(.caption, design: .monospaced))
                    Text("skip \(model.debugInfo.skippedFrames)  late \(model.debugInfo.lateFrameCount)  img \(model.debugInfo.latestImageDescription)")
                        .font(.system(.caption, design: .monospaced))
                    Text("capture \(model.debugInfo.captureFramesPerSecond) fps  display \(model.debugInfo.presentationFramesPerSecond) fps  buffer \(model.debugInfo.bufferedFrames)")
                        .font(.system(.caption, design: .monospaced))
                    Text("span \(model.debugInfo.bufferedDurationMilliseconds) ms  delay \(effectiveDelayDescription)")
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(20)
            }
        }
        .ignoresSafeArea()
    }

    private var effectiveDelayDescription: String {
        if let effectiveDelayMilliseconds = model.debugInfo.effectiveDelayMilliseconds {
            return "\(effectiveDelayMilliseconds) ms"
        }

        return "warming"
    }
}

private struct DelayedFrameSurface: NSViewRepresentable {
    let model: OverlayContentModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> DelayedFrameSurfaceView {
        let surfaceView = DelayedFrameSurfaceView()
        context.coordinator.attach(to: surfaceView)
        return surfaceView
    }

    func updateNSView(_ nsView: DelayedFrameSurfaceView, context: Context) {
        context.coordinator.update(model: model)
    }

    @MainActor
    final class Coordinator {
        private var model: OverlayContentModel
        private weak var surfaceView: DelayedFrameSurfaceView?
        private var playbackSubscription: AnyCancellable?

        init(model: OverlayContentModel) {
            self.model = model
        }

        func attach(to surfaceView: DelayedFrameSurfaceView) {
            self.surfaceView = surfaceView
            subscribe(to: model)
        }

        func update(model: OverlayContentModel) {
            guard self.model !== model else {
                return
            }

            self.model = model
            subscribe(to: model)
        }

        private func subscribe(to model: OverlayContentModel) {
            playbackSubscription = model.playbackPublisher.sink { [weak surfaceView] command in
                surfaceView?.handle(command: command)
            }
        }
    }
}

private final class DelayedFrameSurfaceView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let hostClock = CMClockGetHostTimeClock()
    private var timebase: CMTimebase?
    private var currentDelayMilliseconds = 0
    private var currentContentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layerContentsRedrawPolicy = .never

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        configureTimebaseIfNeeded()
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func handle(command: OverlayContentModel.PlaybackCommand) {
        switch command {
        case .clear:
            displayLayer.flushAndRemoveImage()
        case .configure(let delayMilliseconds, let shouldFlush):
            currentDelayMilliseconds = delayMilliseconds
            configureTimebaseIfNeeded()
            updateTimebaseDelay(delayMilliseconds: delayMilliseconds)

            if shouldFlush {
                displayLayer.flushAndRemoveImage()
            }
        case .enqueue(let frame):
            configureTimebaseIfNeeded()

            if displayLayer.status == .failed {
                displayLayer.flushAndRemoveImage()
                updateTimebaseDelay(delayMilliseconds: currentDelayMilliseconds)
            }

            if currentContentsRect != frame.contentsRect {
                currentContentsRect = frame.contentsRect
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                displayLayer.contentsRect = frame.contentsRect
                CATransaction.commit()
            }

            displayLayer.enqueue(frame.sampleBuffer)
        }
    }

    private func configureTimebaseIfNeeded() {
        guard timebase == nil else {
            return
        }

        var createdTimebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: hostClock,
            timebaseOut: &createdTimebase
        )

        guard status == noErr,
              let createdTimebase else {
            return
        }

        timebase = createdTimebase
        displayLayer.controlTimebase = createdTimebase
        updateTimebaseDelay(delayMilliseconds: currentDelayMilliseconds)
    }

    private func updateTimebaseDelay(delayMilliseconds: Int) {
        guard let timebase else {
            return
        }

        let hostTime = CMClockGetTime(hostClock)
        let delayedTime = CMTimeSubtract(
            hostTime,
            CMTime(milliseconds: delayMilliseconds)
        )
        _ = CMTimebaseSetRateAndAnchorTime(
            timebase,
            rate: 1,
            anchorTime: delayedTime,
            immediateSourceTime: hostTime
        )
    }
}

private extension CMTime {
    init(milliseconds: Int) {
        self = CMTime(value: CMTimeValue(milliseconds), timescale: 1_000)
    }
}
