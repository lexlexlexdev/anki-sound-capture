import Foundation

struct AnkiNote: Identifiable {
    let id: Int64
    let modelName: String
    let fields: [(name: String, value: String)]
    let deck: String
    var title: String {
        for field in fields {
            let plain = field.value
                .replacingOccurrences(of: "\\[sound:[^\\]]+\\]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;|&#160;", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { return plain }
        }
        return "Untitled note"
    }
}

struct AnkiClient {
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL = URL(string: "http://127.0.0.1:8765")!, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    private func request(_ action: String, _ params: [String: Any] = [:]) async throws -> Any {
        let body: [String: Any] = ["action": action, "version": 6, "params": params]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        do { (data, _) = try await session.data(for: request) }
        catch { throw AnkiError.message("Cannot reach AnkiConnect. Open Anki and install or enable AnkiConnect.") }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AnkiError.message("Invalid response from AnkiConnect.") }
        if let error = response["error"] as? String { throw AnkiError.message(error) }
        guard let result = response["result"] else { throw AnkiError.message("Missing result from AnkiConnect.") }
        return result
    }

    func decks() async throws -> [String] {
        guard let names = try await request("deckNames") as? [String] else {
            throw AnkiError.message("Invalid deck list from AnkiConnect.")
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func noteTypes() async throws -> [String] {
        guard let names = try await request("modelNames") as? [String] else {
            throw AnkiError.message("Invalid note type list from AnkiConnect.")
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func fieldNames(for model: String) async throws -> [String] {
        guard let fields = try await request("modelFieldNames", ["modelName": model]) as? [String] else {
            throw AnkiError.message("Invalid field list from AnkiConnect.")
        }
        return fields
    }

    func search(_ query: String, limit: Int = 30) async throws -> [AnkiNote] {
        guard let ids = try await request("findNotes", ["query": query]) as? [Int64] else { throw AnkiError.message("Invalid note list from AnkiConnect.") }
        let selected = Array(ids.sorted(by: >).prefix(limit))
        guard !selected.isEmpty else { return [] }
        return try await notes(selected)
    }

    func notes(_ ids: [Int64]) async throws -> [AnkiNote] {
        guard let result = try await request("notesInfo", ["notes": ids]) as? [[String: Any]] else { throw AnkiError.message("Invalid note details from AnkiConnect.") }
        let cardIDs = result.flatMap { $0["cards"] as? [Int64] ?? [] }
        let cards = cardIDs.isEmpty ? [] : (try await request("cardsInfo", ["cards": cardIDs]) as? [[String: Any]] ?? [])
        var decks: [Int64: String] = [:]
        for card in cards {
            if let id = card["cardId"] as? Int64, let deck = card["deckName"] as? String { decks[id] = deck }
        }
        return result.compactMap { note in
            guard let id = note["noteId"] as? Int64, let modelName = note["modelName"] as? String, let raw = note["fields"] as? [String: [String: Any]] else { return nil }
            let fields = raw.map { (name: $0.key, value: $0.value["value"] as? String ?? "", order: $0.value["order"] as? Int ?? 0) }.sorted { $0.order < $1.order }.map { (name: $0.name, value: $0.value) }
            let card = (note["cards"] as? [Int64])?.first
            return AnkiNote(id: id, modelName: modelName, fields: fields, deck: card.flatMap { decks[$0] } ?? "Unknown deck")
        }
    }

    func attach(_ url: URL, to note: AnkiNote, field: String) async throws {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw AnkiError.message("The recording is empty.") }
        guard let available = try await request("apiReflect", ["scopes": ["actions"], "actions": ["captureAppendAudio", "captureAppendStatus"]]) as? [String: Any],
              let actions = available["actions"] as? [String],
              actions.contains("captureAppendAudio"), actions.contains("captureAppendStatus") else {
            throw AnkiError.message("The Anki Audio Capture companion add-on is not active. Restart Anki, then try again.")
        }
        let filename = "capture-\(UUID().uuidString.lowercased()).m4a"
        guard let storedName = try await request("storeMediaFile", ["filename": filename, "data": data.base64EncodedString()]) as? String, !storedName.isEmpty else {
            throw AnkiError.message("Anki did not confirm saving the audio file.")
        }
        let reference = " [sound:\(storedName)]"
        let token = UUID().uuidString
        do {
            _ = try await request("captureAppendAudio", ["token": token, "noteId": note.id, "field": field, "filename": storedName])
            let deadline = Date().addingTimeInterval(20)
            var completed = false
            while Date() < deadline {
                guard let status = try await request("captureAppendStatus", ["token": token]) as? [String: Any], let state = status["status"] as? String else {
                    throw AnkiError.message("Invalid response from the Anki companion add-on.")
                }
                if state == "done" { completed = true; break }
                if state == "error" { throw AnkiError.message(status["error"] as? String ?? "Anki could not update the note.") }
                guard state == "pending" else { throw AnkiError.message("Unexpected attachment status: \(state)") }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            guard completed else { throw AnkiError.message("Anki did not finish updating the open editor in time.") }
            guard let saved = try await notes([note.id]).first?.fields.first(where: { $0.name == field }),
                  saved.value.contains(reference) else {
                throw AnkiError.message("The audio reference was not found in the saved field.")
            }
        } catch {
            throw AnkiError.message("Could not confirm the attachment. Anki may have saved it; check the note before retrying. \(error.localizedDescription)")
        }
    }
}

enum AnkiError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
