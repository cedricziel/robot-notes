"""Unit tests for log_conversation.py's note read/write logic, run with
`python3 -m unittest` from this directory — no pytest or extra deps needed.
HTTP is stubbed at the `_request` boundary so no network or server is
required.
"""

from __future__ import annotations

import unittest
from unittest import mock

import log_conversation as lc


class ConversationsPathTests(unittest.TestCase):
    def test_scoped_by_actor(self) -> None:
        self.assertEqual(lc.conversations_path("cedric"), "conversations/cedric")
        self.assertEqual(lc.conversations_path("claude-code"), "conversations/claude-code")


class FormatLineTests(unittest.TestCase):
    def test_user_prompt_submit(self) -> None:
        line = lc.format_line({"hook_event_name": "UserPromptSubmit", "prompt": "hello"})
        self.assertEqual(line, "**user**: hello")

    def test_stop(self) -> None:
        line = lc.format_line({"hook_event_name": "Stop", "last_assistant_message": "hi there"})
        self.assertEqual(line, "**assistant**: hi there")

    def test_blank_text_skipped(self) -> None:
        self.assertIsNone(lc.format_line({"hook_event_name": "UserPromptSubmit", "prompt": "   "}))
        self.assertIsNone(lc.format_line({"hook_event_name": "Stop", "last_assistant_message": ""}))

    def test_unknown_event_skipped(self) -> None:
        self.assertIsNone(lc.format_line({"hook_event_name": "SessionStart"}))


class AppendLineTests(unittest.TestCase):
    def test_creates_note_when_missing(self) -> None:
        with mock.patch.object(lc, "find_note_by_title", return_value=None), mock.patch.object(
            lc, "create_note"
        ) as create:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: hi")
        create.assert_called_once_with("http://x", "key", "actor", "sess-1", "**user**: hi", "Claude/Sessions")

    def test_appends_to_existing_note(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "_request", return_value={"content": "**user**: hi", "version": 1}
        ), mock.patch.object(lc, "update_note") as update:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**assistant**: hey")
        update.assert_called_once_with("http://x", "key", "actor", "abc", 1, "**user**: hi\n\n**assistant**: hey")

    def test_empty_existing_content_not_blank_prefixed(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "_request", return_value={"content": "", "version": 1}
        ), mock.patch.object(lc, "update_note") as update:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: first")
        update.assert_called_once_with("http://x", "key", "actor", "abc", 1, "**user**: first")

    def test_retries_on_version_conflict(self) -> None:
        note = {"id": "abc", "version": 1}
        reads = [
            {"content": "old", "version": 1},
            {"content": "old\n\nsomeone else wrote", "version": 2},
        ]
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "_request", side_effect=reads
        ), mock.patch.object(
            lc, "update_note", side_effect=[lc.VersionConflict(), {"version": 3}]
        ) as update:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: retry me")
        self.assertEqual(update.call_count, 2)
        second_call_content = update.call_args_list[1].args[5]
        self.assertIn("someone else wrote", second_call_content)
        self.assertIn("retry me", second_call_content)

    def test_gives_up_after_max_retries(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "_request", return_value={"content": "old", "version": 1}
        ), mock.patch.object(lc, "update_note", side_effect=lc.VersionConflict()) as update:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: never lands")
        self.assertEqual(update.call_count, lc.MAX_RETRIES)


class RunTests(unittest.TestCase):
    def test_noop_without_config(self) -> None:
        with mock.patch.dict("os.environ", {}, clear=True), mock.patch.object(lc, "append_line") as append:
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "s1"})
        append.assert_not_called()

    def test_appends_when_configured(self) -> None:
        env = {"ROBOT_NOTES_BASE_URL": "http://x/", "ROBOT_NOTES_API_KEY": "key"}
        with mock.patch.dict("os.environ", env, clear=True), mock.patch.object(lc, "append_line") as append:
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "s1"})
        append.assert_called_once_with(
            "http://x", "key", "claude-code", "s1", "conversations/claude-code", "**assistant**: hi"
        )

    def test_appends_under_configured_actor(self) -> None:
        env = {"ROBOT_NOTES_BASE_URL": "http://x", "ROBOT_NOTES_API_KEY": "key", "ROBOT_NOTES_ACTOR": "cedric"}
        with mock.patch.dict("os.environ", env, clear=True), mock.patch.object(lc, "append_line") as append:
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "s1"})
        append.assert_called_once_with(
            "http://x", "key", "cedric", "s1", "conversations/cedric", "**assistant**: hi"
        )

    def test_never_raises_on_network_failure(self) -> None:
        env = {"ROBOT_NOTES_BASE_URL": "http://x", "ROBOT_NOTES_API_KEY": "key"}
        with mock.patch.dict("os.environ", env, clear=True), mock.patch.object(
            lc, "append_line", side_effect=RuntimeError("boom")
        ):
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "s1"})  # no raise


if __name__ == "__main__":
    unittest.main()
