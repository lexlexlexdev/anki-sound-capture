"""Synchronize Audio Capture appends with Anki's open note editors."""
import importlib
import os
import time
import weakref

import aqt
from aqt import gui_hooks

_editors = weakref.WeakSet()
_operations = {}


def _track_editor(editor):
    _editors.add(editor)


def _note_id(editor):
    nid = getattr(editor, "nid", None)
    if nid is not None:
        return int(nid)
    note = getattr(editor, "note", None)
    return int(note.id) if note is not None and note.id else None


def _append_audio(self, token, noteId, field, filename):
    now = time.monotonic()
    for key, value in list(_operations.items()):
        if now - value["created"] > 300 and value["status"] != "pending":
            del _operations[key]
    if token in _operations:
        return _operations[token]["status"]
    if os.path.basename(filename) != filename or not filename:
        raise ValueError("Invalid media filename")
    if not os.path.isfile(os.path.join(self.media().dir(), filename)):
        raise ValueError("Audio file is missing from Anki media")

    active = [editor for editor in list(_editors) if _note_id(editor) == int(noteId)]
    if len(active) > 1:
        raise ValueError("This note is open in multiple editors. Close all but one and try again.")
    operation = {"status": "pending", "created": now}
    _operations[token] = operation
    editor = active[0] if active else None

    def apply():
        try:
            note = self.getNote(noteId)
            if field not in note:
                raise ValueError("The destination field no longer exists")
            note[field] += " [sound:" + filename + "]"
            self.collection().update_note(note, skip_undo_entry=True)
            if editor is not None and _note_id(editor) == int(noteId):
                editor.set_note(note)
            operation["status"] = "done"
        except Exception as exc:
            operation["status"] = "error"
            operation["error"] = str(exc)
        finally:
            if editor is not None:
                try:
                    editor.widget.setEnabled(True)
                except RuntimeError:
                    pass

    try:
        if editor is not None:
            editor.widget.setEnabled(False)
            editor.call_after_note_saved(apply)
        else:
            apply()
    except Exception as exc:
        operation["status"] = "error"
        operation["error"] = str(exc)
        if editor is not None:
            try:
                editor.widget.setEnabled(True)
            except RuntimeError:
                pass
    return operation["status"]


def _append_status(self, token):
    operation = _operations.get(token)
    if operation is None:
        raise ValueError("Unknown audio attachment operation")
    return {key: value for key, value in operation.items() if key != "created"}


connect = importlib.import_module("2055492159")
connect.AnkiConnect.captureAppendAudio = connect.util.api()(_append_audio)
connect.AnkiConnect.captureAppendStatus = connect.util.api()(_append_status)
gui_hooks.editor_did_init.append(_track_editor)
