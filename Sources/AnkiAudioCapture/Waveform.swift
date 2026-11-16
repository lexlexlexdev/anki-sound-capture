import SwiftUI
import AVFoundation

enum AudioWaveform {
    static func peaks(from url: URL, count: Int = 160) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw CaptureError.message("Could not read the recording waveform.")
        }
        var peaks = [Float](repeating: 0, count: count)
        let total = file.length
        var position: Int64 = 0
        while position < total {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for i in 0..<Int(buffer.frameLength) {
                let index = min(count - 1, Int((position + Int64(i)) * Int64(count) / total))
                for channel in 0..<Int(buffer.format.channelCount) {
                    peaks[index] = max(peaks[index], abs(channels[channel][i]))
                }
            }
            position += Int64(buffer.frameLength)
        }
        return peaks.map { sqrt(min(1, $0)) }
    }
}

struct WaveformTrimView: View {
    let peaks: [Float]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let playbackPosition: Double?
    let onChange: () -> Void
    @State private var activeHandle: Handle?
    private enum Handle { case start, end }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 10
            let width = max(1, geometry.size.width - 2 * inset)
            let startX = inset + width * start / max(duration, 0.001)
            let endX = inset + width * end / max(duration, 0.001)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.04))
                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let step = width / CGFloat(peaks.count)
                    for (index, peak) in peaks.enumerated() {
                        let x = inset + (CGFloat(index) + 0.5) * step
                        let height = max(2, CGFloat(peak) * (size.height - 16))
                        let rect = CGRect(x: x - max(1, step * 0.3), y: (size.height - height) / 2, width: max(2, step * 0.6), height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(x >= startX && x <= endX ? .accentColor : .secondary.opacity(0.28)))
                    }
                }
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
                    .frame(width: max(0, endX - startX), height: geometry.size.height - 4)
                    .position(x: (startX + endX) / 2, y: geometry.size.height / 2)
                if let playbackPosition {
                    let position = min(end, max(start, playbackPosition))
                    let x = inset + width * position / max(duration, 0.001)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 2, height: geometry.size.height - 12)
                        .shadow(color: .black.opacity(0.55), radius: 2)
                        .position(x: x, y: geometry.size.height / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                handle(at: startX, height: geometry.size.height, label: "Start trim", value: start, isStart: true)
                handle(at: endX, height: geometry.size.height, label: "End trim", value: end, isStart: false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if activeHandle == nil {
                        activeHandle = abs(gesture.startLocation.x - startX) <= abs(gesture.startLocation.x - endX) ? .start : .end
                        onChange()
                    }
                    let value = Double(min(1, max(0, (gesture.location.x - inset) / width))) * duration
                    let gap = min(0.05, duration)
                    if activeHandle == .start { start = min(max(0, value), max(0, end - gap)) }
                    else { end = max(min(duration, value), min(duration, start + gap)) }
                }
                .onEnded { _ in activeHandle = nil })
        }
        .frame(height: 68)
    }

    private func handle(at x: CGFloat, height: CGFloat, label: String, value: Double, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: 7, height: height - 4)
            .overlay(Image(systemName: "line.3.horizontal").font(.system(size: 5, weight: .bold)).rotationEffect(.degrees(90)).foregroundStyle(.white))
            .position(x: x, y: height / 2)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.1f seconds", value))
            .accessibilityAdjustableAction { direction in
                onChange()
                let delta = direction == .increment ? 0.1 : -0.1
                let gap = min(0.05, duration)
                if isStart { start = min(max(0, start + delta), max(0, end - gap)) }
                else { end = max(min(duration, end + delta), min(duration, start + gap)) }
            }
    }
}
