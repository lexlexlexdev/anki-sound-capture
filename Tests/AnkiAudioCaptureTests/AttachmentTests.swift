import XCTest
@testable import AnkiAudioCapture

private final class AnkiTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let data = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(buffer, count: count)
                }
                return bytes
            } ?? Data()
            let input = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let action = input["action"] as! String
            let result: Any
            switch action {
            case "apiReflect": result = ["actions": ["captureAppendAudio", "captureAppendStatus"]]
            case "storeMediaFile": result = "stored.m4a"
            case "notesInfo":
                result = [["noteId": 1, "modelName": "Basic", "fields": ["Back": ["value": "existing", "order": 0]], "cards": []]]
            case "captureAppendAudio": result = "done"
            case "captureAppendStatus": result = ["status": "done"]
            default: throw NSError(domain: "Unexpected action: \(action)", code: 1)
            }
            let response = try JSONSerialization.data(withJSONObject: ["result": result, "error": NSNull()])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class AttachmentTests: XCTestCase {
    func testDoesNotClaimSuccessWhenAnkiDoesNotPersistUpdate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnkiTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = AnkiClient(endpoint: URL(string: "http://localhost:8765")!, session: session)
        let note = AnkiNote(id: 1, modelName: "Basic", fields: [(name: "Back", value: "existing")], deck: "Default")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await client.attach(file, to: note, field: "Back")
            XCTFail("An unpersisted attachment must not be reported as saved")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("check the note before retrying"))
        }
    }
}
