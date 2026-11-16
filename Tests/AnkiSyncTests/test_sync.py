import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path


class Hooks:
    editor_did_init = []


class Note(dict):
    id = 7


class Editor:
    def __init__(self, note, collection):
        self.nid = note.id
        self.note = note
        self.collection = collection
        self.widget = self
        self.enabled = True
        self.callback = None
        self.refreshed = None

    def setEnabled(self, value):
        self.enabled = value

    def call_after_note_saved(self, callback):
        self.callback = callback

    def finish_saving(self):
        self.collection.value["Back"] = "unsaved editor text"
        self.callback()

    def set_note(self, note):
        self.refreshed = dict(note)


class Collection:
    def __init__(self):
        self.value = Note(Back="old text")

    def update_note(self, note, skip_undo_entry):
        self.value = note


class AddonTests(unittest.TestCase):
    def test_waits_for_open_editor_before_appending_and_refreshes_it(self):
        original_aqt = sys.modules.get("aqt")
        original_connect = sys.modules.get("2055492159")
        aqt = types.ModuleType("aqt")
        aqt.gui_hooks = Hooks()
        connect = types.ModuleType("2055492159")
        connect.AnkiConnect = type("AnkiConnect", (), {})
        connect.util = types.SimpleNamespace(api=lambda: lambda function: function)
        sys.modules["aqt"] = aqt
        sys.modules["2055492159"] = connect
        try:
            path = Path(__file__).resolve().parents[2] / "anki-addon" / "__init__.py"
            spec = importlib.util.spec_from_file_location("capture_sync_test", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            with tempfile.TemporaryDirectory() as directory:
                Path(directory, "sound.m4a").write_bytes(b"audio")
                collection = Collection()
                api = types.SimpleNamespace(
                    media=lambda: types.SimpleNamespace(dir=lambda: directory),
                    getNote=lambda nid: Note(collection.value),
                    collection=lambda: collection,
                )
                editor = Editor(collection.value, collection)
                module._track_editor(editor)
                self.assertEqual(module._append_audio(api, "token", 7, "Back", "sound.m4a"), "pending")
                self.assertFalse(editor.enabled)
                self.assertEqual(collection.value["Back"], "old text")
                editor.finish_saving()
                expected = "unsaved editor text [sound:sound.m4a]"
                self.assertEqual(collection.value["Back"], expected)
                self.assertEqual(editor.refreshed["Back"], expected)
                self.assertTrue(editor.enabled)
                self.assertEqual(module._append_status(api, "token")["status"], "done")
        finally:
            if original_aqt is None:
                sys.modules.pop("aqt", None)
            else:
                sys.modules["aqt"] = original_aqt
            if original_connect is None:
                sys.modules.pop("2055492159", None)
            else:
                sys.modules["2055492159"] = original_connect


if __name__ == "__main__":
    unittest.main()
