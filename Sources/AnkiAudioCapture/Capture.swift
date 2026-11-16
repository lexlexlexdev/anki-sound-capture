import Foundation
import ScreenCaptureKit
import AVFoundation

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "audio.capture.samples")
    private var started = false
    private var failure: Error?
    private(set) var url: URL?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.message("No display available for system audio capture.") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.message("Unable to configure audio recording.") }
        writer.add(input)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.writer = writer
        self.input = input
        self.stream = stream
        self.url = destination
        started = false
        failure = nil
        do { try await stream.startCapture() } catch {
            self.stream = nil
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let writer, let input else { return }
        if !started {
            guard writer.startWriting() else { failure = writer.error; return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if input.isReadyForMoreMediaData && !input.append(sampleBuffer) { failure = writer.error }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.failure = error }
    }

    func stop() async throws -> URL {
        guard let stream, let writer, let input, let url else { throw CaptureError.message("No recording is in progress.") }
        try await stream.stopCapture()
        self.stream = nil
        let state = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: (self.started, self.failure)) }
        }
        guard state.0, state.1 == nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw state.1 ?? CaptureError.message("No audio was captured. Play some audio and try again.")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CaptureError.message("Could not save the recording.") }
        return url
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
