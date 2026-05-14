import AppKit
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
                    Text("skip \(model.debugInfo.skippedFrames)  underrun \(model.debugInfo.underrunCount)  img \(model.debugInfo.latestImageDescription)")
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

    final class Coordinator {
        private var model: OverlayContentModel
        private weak var surfaceView: DelayedFrameSurfaceView?
        private var frameSubscription: AnyCancellable?

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
            frameSubscription = model.framePublisher.sink { [weak surfaceView] image in
                surfaceView?.update(image: image)
            }
        }
    }
}

private final class DelayedFrameSurfaceView: NSView {
    private let imageLayer = CALayer()
    private var displayedImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layerContentsRedrawPolicy = .never

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        updateContentsScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    func update(image: CGImage?) {
        guard displayedImage !== image else {
            return
        }

        displayedImage = image
        imageLayer.contents = image
    }

    private func updateContentsScale() {
        let contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = contentsScale
        imageLayer.contentsScale = contentsScale
    }
}
