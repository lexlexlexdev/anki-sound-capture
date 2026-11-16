import Foundation

enum StableVolume {
    static func render(_ source: URL, to destination: URL, executable: URL? = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")) throws {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CaptureError.message("The bundled FFmpeg is missing. Reinstall the app.")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", source.path, "-vn",
            "-af", "acompressor=threshold=0.125:ratio=4:attack=20:release=250:makeup=1,alimiter=limit=0.5:level=0:latency=1",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", destination.path
        ]
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() }
        catch { throw CaptureError.message("Could not start FFmpeg: \(error.localizedDescription)") }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CaptureError.message(detail.isEmpty ? "FFmpeg could not process the recording." : "FFmpeg could not process the recording: \(detail)")
        }
    }
}
