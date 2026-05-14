import SwiftUI

struct DelayedFrameView: View {
    @ObservedObject var model: OverlayContentModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black

                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(Color.black)
                }

                if model.image == nil {
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
                        Text("recv \(model.debugInfo.receivedFrames)  accept \(model.debugInfo.acceptedFrames)  emit \(model.debugInfo.emittedFrames)")
                            .font(.system(.caption, design: .monospaced))
                        Text("skip \(model.debugInfo.skippedFrames)  buffer \(model.debugInfo.bufferedFrames)  img \(model.debugInfo.latestImageDescription)")
                            .font(.system(.caption, design: .monospaced))
                        Text("span \(model.debugInfo.bufferedDurationMilliseconds) ms  delay \(effectiveDelayDescription)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(20)
                }
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
