import SwiftUI
import AppKit
import Carbon
import CoreGraphics

enum CaptureSettings {
    static let keyCode = "shortcutKeyCode"
    static let modifiers = "shortcutModifiers"
    static let shortcutLabel = "shortcutLabel"
    static let defaultDeck = "defaultDeck"
    static let defaultFields = "defaultFieldsByNoteType"
    static let stableVolume = "defaultStableVolume"

    static func registerDefaults() {
        if !UserDefaults.standard.bool(forKey: "safeVolumeDefaultMigrated") {
            UserDefaults.standard.set(false, forKey: stableVolume)
            UserDefaults.standard.set(true, forKey: "safeVolumeDefaultMigrated")
        }
        UserDefaults.standard.register(defaults: [keyCode: Int(kVK_ANSI_9), modifiers: Int(controlKey | optionKey | cmdKey), shortcutLabel: "⌃⌥⌘9", defaultDeck: "", stableVolume: false])
    }
}

struct SettingsView: View {
    @AppStorage(CaptureSettings.shortcutLabel) private var shortcut = "⌃⌥⌘9"
    @AppStorage(CaptureSettings.defaultDeck) private var defaultDeck = ""
    @State private var noteType = ""
    @State private var noteTypes: [String] = []
    @State private var fields: [String] = []
    @AppStorage(CaptureSettings.stableVolume) private var stableVolume = false
    @State private var decks: [String] = []
    @State private var loadingFields = false
    @State private var error: String?
    @State private var selectedTab = SettingsTab.general
    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var defaultsByType: [String: String] = [:]
    let setShortcut: (UInt32, UInt32, String) -> String?
    private let anki = AnkiClient()

    private var selectedField: Binding<String> {
        Binding(
            get: { defaultsByType[noteType] ?? "" },
            set: { field in
                guard !noteType.isEmpty else { return }
                defaultsByType[noteType] = field.isEmpty ? nil : field
                UserDefaults.standard.set(defaultsByType, forKey: CaptureSettings.defaultFields)
            }
        )
    }

    private enum SettingsTab: String, CaseIterable {
        case general = "General"
        case permissions = "macOS Permissions"
        var icon: String { self == .general ? "slider.horizontal.3" : "hand.raised" }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedTab.rawValue).font(.system(size: 22, weight: .semibold))
                        Text(selectedTab == .general ? "Recording and Anki preferences" : "Access needed to record audio")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if selectedTab == .general { generalSettings }
                        else { permissionSettings }
                        if let error, selectedTab == .general {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 680, height: 580)
        .background(.regularMaterial)
        .task { await loadAnkiSettings() }
        .task(id: noteType) { await loadFields(for: noteType) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAccess = CGPreflightScreenCaptureAccess()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Text("Audio Capture").font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.bottom, 24)
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 30)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.primary.opacity(0.035))
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: "Recording", icon: "waveform") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hotkey").fontWeight(.medium)
                        Text("Start or stop a recording").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(label: shortcut) { code, modifiers, label in
                        error = setShortcut(code, modifiers, label)
                    }.frame(width: 170, height: 28)
                }
                Divider().opacity(0.5)
                Toggle(isOn: $stableVolume) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stable volume by default").fontWeight(.medium)
                        Text("Reduce loud peaks without automatic volume boost.").font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch)
            }
            settingsCard(title: "Anki destination", icon: "square.stack.3d.up") {
                Text("The last added note in this deck is selected automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Default deck", selection: $defaultDeck) {
                    Text("All decks").tag("")
                    if !defaultDeck.isEmpty && !decks.contains(defaultDeck) { Text(defaultDeck).tag(defaultDeck) }
                    ForEach(decks, id: \.self) { Text($0).tag($0) }
                }
                Picker("Note type", selection: $noteType) {
                    if noteTypes.isEmpty { Text("No note types available").tag("") }
                    ForEach(noteTypes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Default field", selection: selectedField) {
                    Text("Automatic").tag("")
                    if !selectedField.wrappedValue.isEmpty && !fields.contains(selectedField.wrappedValue) {
                        Text("\(selectedField.wrappedValue) (unavailable)").tag(selectedField.wrappedValue)
                    }
                    ForEach(fields, id: \.self) { Text($0).tag($0) }
                }.disabled(noteType.isEmpty || loadingFields)
                Text("Set a field for each note type. Automatic prefers an Audio field, then the first field.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh from Anki") { Task { await loadAnkiSettings() } }
                    .controlSize(.small)
            }
        }
    }

    private var permissionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: "Screen & system audio recording", icon: "display") {
                HStack(spacing: 8) {
                    Image(systemName: screenAccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(screenAccess ? .green : .orange)
                    Text(screenAccess ? "Screen recording access granted" : "Screen recording access not granted")
                        .fontWeight(.medium)
                }
                Text("macOS requires screen recording access for this app’s system audio capture. The app records audio, not screen video.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if !screenAccess {
                        Button("Request access") {
                            _ = CGRequestScreenCaptureAccess()
                            screenAccess = CGPreflightScreenCaptureAccess()
                        }
                    }
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Refresh") { screenAccess = CGPreflightScreenCaptureAccess() }
                }
                Text("If you change access in System Settings, macOS may ask you to restart the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingsCard(title: "Other access", icon: "checkmark.shield") {
                Text("Microphone and Accessibility permissions are not required.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            content().font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)))
    }

    private func loadAnkiSettings() async {
        do {
            let loadedDecks = try await anki.decks()
            let loadedTypes = try await anki.noteTypes()
            decks = loadedDecks
            noteTypes = loadedTypes
            defaultsByType = UserDefaults.standard.dictionary(forKey: CaptureSettings.defaultFields) as? [String: String] ?? [:]
            if !loadedTypes.contains(noteType) { noteType = loadedTypes.first ?? "" }
            else { await loadFields(for: noteType) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func loadFields(for type: String) async {
        guard !type.isEmpty else { fields = []; return }
        loadingFields = true
        do {
            let result = try await anki.fieldNames(for: type)
            guard noteType == type else { return }
            fields = result
            loadingFields = false
        } catch {
            guard noteType == type else { return }
            fields = []
            loadingFields = false
            self.error = error.localizedDescription
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var label: String
    var onChange: (UInt32, UInt32, String) -> Void
    func makeNSView(context: Context) -> ShortcutField {
        let field = ShortcutField()
        field.onChange = onChange
        return field
    }
    func updateNSView(_ field: ShortcutField, context: Context) {
        field.shortcut = label
        field.onChange = onChange
        if field.window?.firstResponder !== field { field.stringValue = label + "  ·  Click to change" }
    }
}

final class ShortcutField: NSTextField {
    var shortcut = ""
    var onChange: ((UInt32, UInt32, String) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false; isSelectable = false; isBordered = true
        alignment = .center; font = .systemFont(ofSize: 12)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = "Press a shortcut…"
    }
    override func resignFirstResponder() -> Bool {
        stringValue = shortcut + "  ·  Click to change"
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape) { window?.makeFirstResponder(nil); return }
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option), let key = event.charactersIgnoringModifiers?.uppercased(), key.count == 1, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            stringValue = "Use ⌘, ⌥, or ⌃ + a key"
            return
        }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        onChange?(UInt32(event.keyCode), modifiers, label + key)
        window?.makeFirstResponder(nil)
    }
}
