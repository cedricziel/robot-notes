"""Unit tests for log_conversation.py's note read/write logic, run with
`python3 -m unittest` from this directory — no pytest or extra deps needed.
HTTP is stubbed at the `_request` boundary so no network or server is
required.
"""

from __future__ import annotations

import os
import time
import unittest
from unittest import mock

import log_conversation as lc


class SanitizeActorTests(unittest.TestCase):
    def test_plain_actor_unchanged(self) -> None:
        self.assertEqual(lc.sanitize_actor("cedric"), "cedric")

    def test_slash_flattened_to_single_segment(self) -> None:
        self.assertEqual(lc.sanitize_actor("ops/team"), "ops_team")
        self.assertNotIn("/", lc.sanitize_actor("a/b/c"))

    def test_dot_segments_fall_back_to_default(self) -> None:
        self.assertEqual(lc.sanitize_actor("."), lc.DEFAULT_ACTOR)
        self.assertEqual(lc.sanitize_actor(".."), lc.DEFAULT_ACTOR)
        self.assertEqual(lc.sanitize_actor(""), lc.DEFAULT_ACTOR)
        self.assertEqual(lc.sanitize_actor("   "), lc.DEFAULT_ACTOR)


class ConversationsPathTests(unittest.TestCase):
    def test_scoped_by_actor(self) -> None:
        self.assertEqual(lc.conversations_path("cedric"), "conversations/cedric")
        self.assertEqual(lc.conversations_path("claude-code"), "conversations/claude-code")

    def test_scoped_by_sanitized_actor(self) -> None:
        self.assertEqual(lc.conversations_path("ops/team"), "conversations/ops_team")


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


class FindNoteByTitleTests(unittest.TestCase):
    def test_returns_match_on_first_page(self) -> None:
        with mock.patch.object(
            lc, "_request", return_value={"items": [{"id": "a", "title": "sess-1"}], "next_cursor": None}
        ):
            note = lc.find_note_by_title("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertEqual(note, {"id": "a", "title": "sess-1"})

    def test_follows_next_cursor_to_find_match_on_later_page(self) -> None:
        pages = [
            {"items": [{"id": "a", "title": "other"}], "next_cursor": "cursor-1"},
            {"items": [{"id": "b", "title": "sess-1"}], "next_cursor": None},
        ]
        with mock.patch.object(lc, "_request", side_effect=pages) as request:
            note = lc.find_note_by_title("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertEqual(note, {"id": "b", "title": "sess-1"})
        self.assertEqual(request.call_count, 2)
        second_call_path = request.call_args_list[1].args[4]
        self.assertIn("after=cursor-1", second_call_path)

    def test_returns_none_when_exhausted_without_match(self) -> None:
        with mock.patch.object(lc, "_request", return_value={"items": [], "next_cursor": None}):
            note = lc.find_note_by_title("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertIsNone(note)


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


class SessionLockTests(unittest.TestCase):
    def tearDown(self) -> None:
        lc.release_session_lock(lc._session_lock_path("lock-test-session"))
        lc.release_session_lock(lc._session_lock_path("lock-test-stale"))

    def test_mutual_exclusion_times_out_while_held(self) -> None:
        lock_path = lc.acquire_session_lock("lock-test-session")
        self.addCleanup(lc.release_session_lock, lock_path)
        with self.assertRaises(TimeoutError):
            lc.acquire_session_lock("lock-test-session", timeout=0.2)

    def test_release_then_reacquire_succeeds(self) -> None:
        lock_path = lc.acquire_session_lock("lock-test-session")
        lc.release_session_lock(lock_path)
        second = lc.acquire_session_lock("lock-test-session", timeout=0.2)
        lc.release_session_lock(second)

    def test_stale_lock_is_reclaimed(self) -> None:
        lock_path = lc.acquire_session_lock("lock-test-stale")
        old = time.time() - 120
        os.utime(lock_path, (old, old))
        reclaimed = lc.acquire_session_lock("lock-test-stale", timeout=0.2, stale_seconds=60)
        self.assertEqual(reclaimed, lock_path)
        lc.release_session_lock(reclaimed)


class RunTests(unittest.TestCase):
    def test_noop_without_config(self) -> None:
        with mock.patch.dict("os.environ", {}, clear=True), mock.patch.object(lc, "append_line") as append:
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "run-test-1"})
        append.assert_not_called()

    def test_appends_when_configured(self) -> None:
        env = {"ROBOT_NOTES_BASE_URL": "http://x/", "ROBOT_NOTES_API_KEY": "key"}
        with mock.patch.dict("os.environ", env, clear=True), mock.patch.object(lc, "append_line") as append:
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "run-test-2"})
        append.assert_called_once_with(
            "http://x", "key", "claude-code", "run-test-2", "conversations/claude-code", "**assistant**: hi"
        )

    def test_appends_under_configured_actor(self) -> None:
        env = {"ROBOT_NOTES_BASE_URL": "http://x", "ROBOT_NOTES_API_KEY": "key", "ROBOT_NOTES_ACTOR": "cedric"}
        with mock.patch.dict("os.environ", env, clear=True), mock.patch.object(lc, "append_line") as append:
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "run-test-3"})
        append.assert_called_once_with(
            "http://x", "key", "cedric", "run-test-3", "conversations/cedric", "**assistant**: hi"
        )

    def test_never_raises_on_network_failure(self) -> None:
        env = {"ROBOT_NOTES_BASE_URL": "http://x", "ROBOT_NOTES_API_KEY": "key"}
        with mock.patch.dict("os.environ", env, clear=True), mock.patch.object(
            lc, "append_line", side_effect=RuntimeError("boom")
        ):
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "run-test-4"})  # no raise

    def test_releases_lock_even_on_failure(self) -> None:
        env = {"ROBOT_NOTES_BASE_URL": "http://x", "ROBOT_NOTES_API_KEY": "key"}
        with mock.patch.dict("os.environ", env, clear=True), mock.patch.object(
            lc, "append_line", side_effect=RuntimeError("boom")
        ):
            lc.run({"hook_event_name": "Stop", "last_assistant_message": "hi", "session_id": "run-test-5"})
        self.assertFalse(os.path.exists(lc._session_lock_path("run-test-5")))

    def test_serializes_concurrent_events_for_the_same_session(self) -> None:
        env = {"ROBOT_NOTES_BASE_URL": "http://x", "ROBOT_NOTES_API_KEY": "key"}
        session_id = "run-test-overlap"
        order = []

        def slow_append(*_args, **_kwargs):
            order.append("start")
            time.sleep(0.1)
            order.append("end")

        with mock.patch.dict("os.environ", env, clear=True), mock.patch.object(
            lc, "append_line", side_effect=slow_append
        ):
            import threading

            first = threading.Thread(
                target=lc.run, args=({"hook_event_name": "UserPromptSubmit", "prompt": "hi", "session_id": session_id},)
            )
            second = threading.Thread(
                target=lc.run,
                args=({"hook_event_name": "Stop", "last_assistant_message": "hey", "session_id": session_id},),
            )
            first.start()
            time.sleep(0.02)
            second.start()
            first.join()
            second.join()

        # each call's "start" is immediately followed by its own "end" — never
        # interleaved — proving the lock serialized the two overlapping events
        self.assertEqual(order, ["start", "end", "start", "end"])
        self.assertFalse(os.path.exists(lc._session_lock_path(session_id)))


if __name__ == "__main__":
    unittest.main()
