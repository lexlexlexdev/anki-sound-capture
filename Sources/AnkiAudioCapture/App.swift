import SwiftUI
import AppKit
import AVFoundation
import Carbon

@main
@MainActor
struct CaptureApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var panel: NSPanel!
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var settingsWindow: NSWindow?
    private var toggleMenuItem: NSMenuItem?
    private let model = CaptureModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CaptureSettings.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 530, height: 570), styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isRestorable = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CaptureView(model: model))
        panel.center()
        model.show = { [weak self] in self?.showPanel() }
        model.hide = { [weak self] in self?.panel.orderOut(nil) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Anki Audio Capture")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start / Stop Recording", action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggleMenuItem = toggle
        menu.addItem(toggle)
        let open = NSMenuItem(title: "Show Capture", action: #selector(showPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggleRecording() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let defaults = UserDefaults.standard
        let code = UInt32(defaults.integer(forKey: CaptureSettings.keyCode))
        let modifiers = UInt32(defaults.integer(forKey: CaptureSettings.modifiers))
        if let error = registerShortcut(code, modifiers, defaults.string(forKey: CaptureSettings.shortcutLabel) ?? "⌃⌥⌘9") {
            model.error = error; showPanel()
        }
    }

    private func registerShortcut(_ code: UInt32, _ modifiers: UInt32, _ label: String) -> String? {
        let defaults = UserDefaults.standard
        let oldCode = UInt32(defaults.integer(forKey: CaptureSettings.keyCode))
        let oldModifiers = UInt32(defaults.integer(forKey: CaptureSettings.modifiers))
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        let identifier = EventHotKeyID(signature: 0x414E4B49, id: 1)
        let result = RegisterEventHotKey(code, modifiers, identifier, GetApplicationEventTarget(), 0, &hotkey)
        guard result == noErr else {
            _ = RegisterEventHotKey(oldCode, oldModifiers, identifier, GetApplicationEventTarget(), 0, &hotkey)
            return "That shortcut is unavailable. Choose another shortcut."
        }
        defaults.set(Int(code), forKey: CaptureSettings.keyCode)
        defaults.set(Int(modifiers), forKey: CaptureSettings.modifiers)
        defaults.set(label, forKey: CaptureSettings.shortcutLabel)
        toggleMenuItem?.title = "Start / Stop Recording  \(label)"
        return nil
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView { [weak self] code, modifiers, label in
                self?.registerShortcut(code, modifiers, label)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Anki Audio Capture Settings"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleRecording() { model.toggle() }
    @objc private func showPanel() { panel.makeKeyAndOrderFront(nil) }
}

@MainActor
final class CaptureModel: ObservableObject {
    enum State { case idle, starting, recording, stopping, preview, saving }
    @Published var state: State = .idle
    @Published var error: String?
    @Published var elapsed: TimeInterval = 0
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var waveform: [Float] = []
    @Published var note: AnkiNote?
    @Published var field = ""
    @Published var search = ""
    @Published var results: [AnkiNote] = []
    @Published var searching = false
    @Published var choosing = false
    @Published var playing = false
    @Published var playbackPosition: Double?
    @Published var stableVolume = false
    @Published var processing = false
    @Published var confirmation: String?
    @Published var confirmationDetail: String?
    var show: (() -> Void)?
    var hide: (() -> Void)?
    private var recorder = AudioCapture()
    private let anki = AnkiClient()
    private var recording: URL?
    private var processed: URL?
    private var originalWaveform: [Float] = []
    private var processedWaveform: [Float] = []
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var playbackTimer: Timer?
    private var began = Date()
    private var searchTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        default: show?()
        }
    }

    func start() {
        guard state == .idle else { return }
        confirmationTask?.cancel(); confirmationTask = nil
        stableVolume = UserDefaults.standard.bool(forKey: CaptureSettings.stableVolume)
        error = nil; confirmation = nil; confirmationDetail = nil; elapsed = 0; state = .starting; show?()
        Task {
            do {
                try await recorder.start()
                state = .recording; began = Date()
                timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor in guard let self else { return }; self.elapsed = Date().timeIntervalSince(self.began) }
                }
            } catch { state = .idle; self.error = error.localizedDescription }
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .stopping; timer?.invalidate()
        Task {
            do {
                let url = try await recorder.stop()
                recording = url
                let asset = AVURLAsset(url: url)
                duration = try await asset.load(.duration).seconds
                guard duration.isFinite && duration > 0 else { throw CaptureError.message("The recording has no playable audio.") }
                originalWaveform = try await Task.detached(priority: .userInitiated) { try AudioWaveform.peaks(from: url) }.value
                waveform = originalWaveform
                trimStart = 0; trimEnd = duration
                await latest()
                if stableVolume {
                    do { _ = try await audioForCurrentSetting() }
                    catch { stableVolume = false; self.error = error.localizedDescription }
                }
                state = .preview
            } catch { state = .idle; self.error = error.localizedDescription }
        }
    }

    func latest() async {
        do {
            let deck = UserDefaults.standard.string(forKey: CaptureSettings.defaultDeck) ?? ""
            let escaped = deck.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let query = deck.isEmpty ? "" : "deck:\"\(escaped)\""
            guard let selected = try await anki.search(query, limit: 1).first else {
                throw AnkiError.message("No notes found in the default deck. Choose another deck or search for a note.")
            }
            select(selected)
        } catch { self.error = error.localizedDescription }
    }

    func select(_ selected: AnkiNote) {
        note = selected
        let defaults = UserDefaults.standard.dictionary(forKey: CaptureSettings.defaultFields) as? [String: String] ?? [:]
        let preferred = defaults[selected.modelName]
        if let preferred, selected.fields.contains(where: { $0.name == preferred }) {
            field = preferred
            error = nil
        } else {
            field = preferred == nil ? (selected.fields.first(where: { $0.name.localizedCaseInsensitiveContains("audio") })?.name ?? selected.fields.first?.name ?? "") : ""
            error = preferred == nil ? nil : "The default field for \(selected.modelName) is no longer available. Choose a field."
        }
        choosing = false
    }

    func searchNotes() {
        searchTask?.cancel()
        let query = search
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                searching = true
                let found = try await anki.search(query)
                guard !Task.isCancelled else { return }
                results = found; searching = false; error = nil
            } catch {
                guard !Task.isCancelled else { return }
                searching = false; self.error = error.localizedDescription
            }
        }
    }

    private func audioForCurrentSetting() async throws -> URL {
        guard let recording else { throw CaptureError.message("Recording is unavailable.") }
        guard stableVolume else { return recording }
        if let processed { waveform = processedWaveform; return processed }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        processing = true
        defer { processing = false }
        do {
            let peaks = try await Task.detached(priority: .userInitiated) {
                try StableVolume.render(recording, to: output)
                return try AudioWaveform.peaks(from: output)
            }.value
            processedWaveform = peaks
            waveform = peaks
            processed = output
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    func stableVolumeChanged() {
        stopPlayback()
        guard state == .preview else { return }
        if !stableVolume {
            waveform = originalWaveform
            return
        }
        processing = true
        Task {
            defer { processing = false }
            do { _ = try await audioForCurrentSetting() }
            catch {
                stableVolume = false
                waveform = originalWaveform
                self.error = error.localizedDescription
            }
        }
    }

    func stopPlayback() {
        playbackTimer?.invalidate(); playbackTimer = nil
        player?.stop(); playing = false; playbackPosition = nil
    }

    func play() {
        if playing { stopPlayback(); return }
        guard !processing else { return }
        Task {
            do {
                let url = try await audioForCurrentSetting()
                let player = try AVAudioPlayer(contentsOf: url)
                self.player = player
                player.currentTime = trimStart
                guard player.play() else { throw CaptureError.message("Could not play the recording.") }
                playbackPosition = trimStart
                playing = true
                playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
                    Task { @MainActor in
                        guard let self, self.playbackTimer === timer, let player = self.player else {
                            timer.invalidate(); return
                        }
                        guard player.isPlaying, player.currentTime < self.trimEnd else {
                            self.stopPlayback(); return
                        }
                        self.playbackPosition = player.currentTime
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func discard() {
        guard (state == .preview || state == .idle) && !processing else { return }
        confirmationTask?.cancel(); confirmationTask = nil
        confirmation = nil; confirmationDetail = nil
        stopPlayback()
        if let recording { try? FileManager.default.removeItem(at: recording) }
        if let processed { try? FileManager.default.removeItem(at: processed); self.processed = nil }
        originalWaveform = []; processedWaveform = []; waveform = []
        recording = nil; note = nil; error = nil; choosing = false; state = .idle; hide?()
    }

    func cancelRecording() {
        guard state == .recording else { return }
        state = .stopping; timer?.invalidate()
        Task {
            do { let url = try await recorder.stop(); try? FileManager.default.removeItem(at: url); state = .idle; hide?() }
            catch { state = .idle; self.error = error.localizedDescription }
        }
    }

    func save() {
        guard state == .preview, !processing, let recording, let note, !field.isEmpty, trimEnd > trimStart else { return }
        let field = self.field
        stopPlayback(); state = .saving; error = nil
        Task {
            var exported: URL?
            do {
                var file = try await audioForCurrentSetting()
                if trimStart > 0.01 || trimEnd < duration - 0.01 {
                    let asset = AVURLAsset(url: file)
                    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CaptureError.message("Could not prepare the trimmed recording.") }
                    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                    exported = output
                    exporter.outputURL = output; exporter.outputFileType = .m4a
                    exporter.timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), end: CMTime(seconds: trimEnd, preferredTimescale: 600))
                    await exporter.export()
                    guard exporter.status == .completed else { throw exporter.error ?? CaptureError.message("Could not trim the recording.") }
                    file = output
                }
                try await anki.attach(file, to: note, field: field)
                if let exported { try? FileManager.default.removeItem(at: exported) }
                try? FileManager.default.removeItem(at: recording)
                if let processed { try? FileManager.default.removeItem(at: processed); self.processed = nil }
                originalWaveform = []; processedWaveform = []; waveform = []
                self.recording = nil; self.note = nil; state = .idle
                confirmation = "Added to Anki"
                confirmationDetail = "\(note.title)\n\(note.deck) · \(field)"
                confirmationTask?.cancel()
                confirmationTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled, state == .idle, confirmation != nil else { return }
                    hide?()
                    confirmation = nil; confirmationDetail = nil
                    confirmationTask = nil
                }
            } catch {
                if let exported { try? FileManager.default.removeItem(at: exported) }
                state = .preview; self.error = error.localizedDescription
            }
        }
    }
}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @AppStorage(CaptureSettings.shortcutLabel) private var shortcut = "⌃⌥⌘9"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            switch model.state {
            case .idle:
                idle
            case .starting, .stopping, .saving:
                Spacer()
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.state == .starting ? "Starting recording…" : model.state == .stopping ? "Finishing recording…" : "Adding to Anki…")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            case .recording:
                recording
            case .preview:
                preview
            }
        }
        .padding(24)
        .frame(width: 530, height: 570, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio capture").font(.system(size: 17, weight: .semibold))
                Text("SYSTEM AUDIO  ·  ANKI").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            }
            Spacer()
            if model.state == .recording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("RECORDING").font(.system(size: 10, weight: .bold)).tracking(0.5)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.red.opacity(0.1), in: Capsule())
            }
        }
    }

    private var idle: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: model.confirmation == nil ? "waveform.circle" : "checkmark.circle")
                .font(.system(size: 48, weight: .light)).foregroundStyle(Color.accentColor)
            Text(model.confirmation ?? "Ready to capture")
                .font(.system(size: 20, weight: .semibold))
            if let detail = model.confirmationDetail {
                Text(detail).multilineTextAlignment(.center).lineLimit(3).foregroundStyle(.secondary)
            } else {
                Text("Press \(shortcut) to record system audio.").foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Close") { model.discard() }.buttonStyle(OverlaySecondaryButton())
                Spacer()
                Button("Start recording") { model.start() }
                    .buttonStyle(OverlayPrimaryButton()).keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var recording: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(.red.opacity(0.08)).frame(width: 102, height: 102)
                Circle().fill(.red.opacity(0.12)).frame(width: 76, height: 76)
                Image(systemName: "waveform").font(.system(size: 29, weight: .medium)).foregroundStyle(.red)
            }
            Text(time(model.elapsed))
                .font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
            Text("Recording system audio").foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Cancel") { model.cancelRecording() }.buttonStyle(OverlaySecondaryButton())
                Spacer()
                Button {
                    model.stop()
                } label: {
                    Label("Stop recording", systemImage: "stop.fill")
                }
                .buttonStyle(OverlayPrimaryButton()).keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    audioCard
                    destinationCard
                }
            }
            .scrollIndicators(.automatic)
            Spacer(minLength: 0)
            HStack {
                Button("Discard") { model.discard() }
                    .buttonStyle(OverlaySecondaryButton())
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.processing)
                Spacer()
                Button {
                    model.save()
                } label: {
                    Label("Attach to note", systemImage: "arrow.down.doc")
                }
                .buttonStyle(OverlayPrimaryButton())
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.processing || model.note == nil || model.field.isEmpty || model.choosing || model.trimEnd <= model.trimStart)
            }
        }
    }

    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { model.play() } label: {
                    Image(systemName: model.playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain).disabled(model.processing)
                .accessibilityLabel(model.playing ? "Stop preview" : "Play preview")
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.processing ? "Preparing audio…" : "Preview recording").fontWeight(.semibold)
                    Text("Trim before adding to Anki").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(time(model.duration)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            Divider().opacity(0.5)
            WaveformTrimView(peaks: model.waveform, duration: model.duration, start: $model.trimStart, end: $model.trimEnd, playbackPosition: model.playbackPosition) {
                model.stopPlayback()
            }
            HStack {
                Text("Start  \(preciseTime(model.trimStart))")
                Spacer()
                Text("End  \(preciseTime(model.trimEnd))")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Toggle(isOn: $model.stableVolume) {
                Label("Stable volume", systemImage: "waveform.badge.magnifyingglass")
            }
            .toggleStyle(.checkbox)
            .disabled(model.processing)
            .onChange(of: model.stableVolume) { _, _ in model.stableVolumeChanged() }
            .help("Reduce loud peaks without automatic volume boost.")
        }
        .font(.callout)
        .padding(16)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("DESTINATION", systemImage: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(.secondary)
                Spacer()
                if !model.choosing {
                    Button("Search notes…") { model.choosing = true; model.searchNotes() }
                        .buttonStyle(.link)
                }
            }
            if model.choosing {
                HStack {
                    TextField("Search Anki notes", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.search) { _, _ in model.searchNotes() }
                    Button("Cancel") { model.choosing = false }.buttonStyle(.link)
                }
                if model.searching { ProgressView().controlSize(.small) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.results) { note in
                            Button { model.select(note) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.title).lineLimit(1).fontWeight(.medium)
                                    Text(note.deck).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 100)
            } else {
                Text(model.note?.title ?? "No note selected").font(.system(size: 16, weight: .semibold)).lineLimit(2)
                if let note = model.note {
                    Text(note.deck).font(.callout).foregroundStyle(.secondary)
                    Divider().opacity(0.5)
                    HStack {
                        Text("Save to field").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Save to field", selection: $model.field) {
                            if model.field.isEmpty { Text("Choose a field").tag("") }
                            ForEach(note.fields, id: \.name) { field in Text(field.name).tag(field.name) }
                        }.labelsHidden().frame(maxWidth: 220)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }

    private func time(_ value: Double) -> String {
        let n = Int(max(0, value.isFinite ? value : 0))
        return String(format: "%02d:%02d", n / 60, n % 60)
    }

    private func preciseTime(_ value: Double) -> String {
        let tenths = Int(max(0, value.isFinite ? value : 0) * 10)
        return String(format: "%02d:%02d.%01d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

private struct OverlayPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct OverlaySecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
