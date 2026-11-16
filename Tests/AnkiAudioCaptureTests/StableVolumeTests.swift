import XCTest
import AVFoundation
@testable import AnkiAudioCapture

final class StableVolumeTests: XCTestCase {
    func testProcessingDoesNotBoostQuietAudioAndReducesLoudAudio() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/Anki Audio Capture.app/Contents/MacOS/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build the app first to create its bundled FFmpeg")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        let output = directory.appendingPathComponent("processed.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192000], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
            buffer.frameLength = 192000
            for i in 0..<192000 {
                let amplitude: Float = i < 96000 ? 0.03 : 0.9
                buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 2 * .pi * 440 / 48000)
            }
            try file.write(from: buffer)
        }
        try StableVolume.render(source, to: output, executable: executable)
        let file = try AVAudioFile(forReading: output)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        XCTAssertGreaterThanOrEqual(buffer.frameLength, 190000)
        guard buffer.frameLength >= 190000, let samples = buffer.floatChannelData?[0] else { return }
        func rms(_ range: Range<Int>) -> Double {
            sqrt(range.reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / Double(range.count))
        }
        XCTAssertLessThan(rms(48000..<90000), 0.03 / sqrt(2) * 1.1)
        XCTAssertLessThan(rms(144000..<186000), 0.9 / sqrt(2) * 0.75)
        XCTAssertLessThan((0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 1, 0.6)
    }
}
