import XCTest
@testable import AnkiAudioCapture

final class NoteTitleTests: XCTestCase {
    func testTitlePreservesTextAndRemovesSoundReferences() {
        let note = AnkiNote(id: 1, modelName: "Test", fields: [
            (name: "Word", value: "수요일 오후 예약은 다 <u><b>찼습니다.</b></u> [sound:clip.m4a]")
        ], deck: "기본1")
        XCTAssertEqual(note.title, "수요일 오후 예약은 다 찼습니다.")
    }

    func testTitleUsesNextFieldWhenFirstHasOnlyAudio() {
        let note = AnkiNote(id: 2, modelName: "Test", fields: [
            (name: "Audio", value: "[sound:clip.m4a]"),
            (name: "Sentence", value: "안녕하세요")
        ], deck: "기본1")
        XCTAssertEqual(note.title, "안녕하세요")
    }
}
