"""Unit tests for log_conversation.py's note read/write logic, run with
`python3 -m unittest` from this directory — no pytest or extra deps needed.
HTTP is stubbed at the `_request` boundary (and, where a fallback branch
needs to distinguish an HTTP status, at the `urllib.error.HTTPError` it
raises) so no network or server is required.
"""

from __future__ import annotations

import os
import tempfile
import threading
import time
import unittest
import urllib.error
from unittest import mock

import log_conversation as lc


def _http_error(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError("http://x", code, "error", None, None)


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
    def test_uses_the_title_filter_when_supported(self) -> None:
        with mock.patch.object(
            lc, "_request", return_value={"items": [{"id": "a", "title": "sess-1"}], "next_cursor": None}
        ) as request:
            note = lc.find_note_by_title("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertEqual(note, {"id": "a", "title": "sess-1"})
        request.assert_called_once()
        called_path = request.call_args.args[4]
        self.assertIn("title=sess-1", called_path)

    def test_title_filter_miss_does_not_fall_back_to_scan(self) -> None:
        with mock.patch.object(lc, "_request", return_value={"items": [], "next_cursor": None}) as request:
            note = lc.find_note_by_title("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertIsNone(note)
        request.assert_called_once()

    def test_falls_back_to_scan_on_400(self) -> None:
        with mock.patch.object(
            lc,
            "_request",
            side_effect=[_http_error(400), {"items": [{"id": "b", "title": "sess-1"}], "next_cursor": None}],
        ) as request:
            note = lc.find_note_by_title("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertEqual(note, {"id": "b", "title": "sess-1"})
        self.assertEqual(request.call_count, 2)

    def test_other_http_errors_are_not_swallowed(self) -> None:
        with mock.patch.object(lc, "_request", side_effect=_http_error(500)):
            with self.assertRaises(urllib.error.HTTPError):
                lc.find_note_by_title("http://x", "key", "actor", "sess-1", "conversations/actor")


class FindNoteByTitleScanTests(unittest.TestCase):
    def test_returns_match_on_first_page(self) -> None:
        with mock.patch.object(
            lc, "_request", return_value={"items": [{"id": "a", "title": "sess-1"}], "next_cursor": None}
        ):
            note = lc._find_note_by_title_scan("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertEqual(note, {"id": "a", "title": "sess-1"})

    def test_follows_next_cursor_to_find_match_on_later_page(self) -> None:
        pages = [
            {"items": [{"id": "a", "title": "other"}], "next_cursor": "cursor-1"},
            {"items": [{"id": "b", "title": "sess-1"}], "next_cursor": None},
        ]
        with mock.patch.object(lc, "_request", side_effect=pages) as request:
            note = lc._find_note_by_title_scan("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertEqual(note, {"id": "b", "title": "sess-1"})
        self.assertEqual(request.call_count, 2)
        second_call_path = request.call_args_list[1].args[4]
        self.assertIn("after=cursor-1", second_call_path)

    def test_returns_none_when_exhausted_without_match(self) -> None:
        with mock.patch.object(lc, "_request", return_value={"items": [], "next_cursor": None}):
            note = lc._find_note_by_title_scan("http://x", "key", "actor", "sess-1", "conversations/actor")
        self.assertIsNone(note)


class JoinWithSeparatorTests(unittest.TestCase):
    def test_empty_current_becomes_addition(self) -> None:
        self.assertEqual(lc._join_with_separator("", "first line"), "first line")

    def test_inserts_a_single_newline_when_missing(self) -> None:
        self.assertEqual(lc._join_with_separator("line one", "line two"), "line one\nline two")

    def test_does_not_double_a_trailing_newline(self) -> None:
        self.assertEqual(lc._join_with_separator("line one\n", "line two"), "line one\nline two")

    def test_preserves_existing_blank_lines_rather_than_collapsing_them(self) -> None:
        # Matches the server's NoteWriteService.append: it only checks whether
        # content already ends with "\n", it never strips extra trailing ones.
        self.assertEqual(lc._join_with_separator("line one\n\n", "line two"), "line one\n\nline two")


class AppendLineTests(unittest.TestCase):
    def test_creates_note_when_missing(self) -> None:
        with mock.patch.object(lc, "find_note_by_title", return_value=None), mock.patch.object(
            lc, "create_note"
        ) as create:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: hi")
        create.assert_called_once_with("http://x", "key", "actor", "sess-1", "**user**: hi", "Claude/Sessions")

    def test_appends_via_the_server_append_endpoint(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "append_note"
        ) as append_note, mock.patch.object(lc, "_request") as request:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**assistant**: hey")
        append_note.assert_called_once_with("http://x", "key", "actor", "abc", "**assistant**: hey")
        request.assert_not_called()  # no GET/PUT read-modify-write when the endpoint succeeds

    def test_falls_back_to_read_modify_write_on_404_route(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "append_note", side_effect=_http_error(404)
        ), mock.patch.object(
            lc, "_request", return_value={"content": "**user**: hi", "version": 1}
        ), mock.patch.object(lc, "update_note") as update:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**assistant**: hey")
        update.assert_called_once_with("http://x", "key", "actor", "abc", 1, "**user**: hi\n**assistant**: hey")

    def test_falls_back_to_read_modify_write_on_405_route(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "append_note", side_effect=_http_error(405)
        ), mock.patch.object(
            lc, "_request", return_value={"content": "", "version": 1}
        ), mock.patch.object(lc, "update_note") as update:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: first")
        update.assert_called_once_with("http://x", "key", "actor", "abc", 1, "**user**: first")

    def test_other_append_errors_are_not_swallowed_into_a_fallback(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "append_note", side_effect=_http_error(500)
        ), mock.patch.object(lc, "_request") as request:
            with self.assertRaises(urllib.error.HTTPError):
                lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: hi")
        request.assert_not_called()

    def test_empty_existing_content_not_blank_prefixed_in_fallback(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "append_note", side_effect=_http_error(404)
        ), mock.patch.object(
            lc, "_request", return_value={"content": "", "version": 1}
        ), mock.patch.object(lc, "update_note") as update:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: first")
        update.assert_called_once_with("http://x", "key", "actor", "abc", 1, "**user**: first")

    def test_fallback_retries_on_version_conflict(self) -> None:
        note = {"id": "abc", "version": 1}
        reads = [
            {"content": "old", "version": 1},
            {"content": "old\nsomeone else wrote", "version": 2},
        ]
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "append_note", side_effect=_http_error(404)
        ), mock.patch.object(lc, "_request", side_effect=reads), mock.patch.object(
            lc, "update_note", side_effect=[lc.VersionConflict(), {"version": 3}]
        ) as update:
            lc.append_line("http://x", "key", "actor", "sess-1", "Claude/Sessions", "**user**: retry me")
        self.assertEqual(update.call_count, 2)
        second_call_content = update.call_args_list[1].args[5]
        self.assertIn("someone else wrote", second_call_content)
        self.assertIn("retry me", second_call_content)

    def test_fallback_gives_up_after_max_retries(self) -> None:
        note = {"id": "abc", "version": 1}
        with mock.patch.object(lc, "find_note_by_title", return_value=note), mock.patch.object(
            lc, "append_note", side_effect=_http_error(404)
        ), mock.patch.object(
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
        first_entered = threading.Event()
        contention_observed = threading.Event()
        release_first = threading.Event()
        order = []
        errors = []
        real_open = os.open

        def observe_open(*args, **kwargs):
            try:
                return real_open(*args, **kwargs)
            except FileExistsError:
                contention_observed.set()
                raise

        def append(*args):
            line = args[-1]
            order.append(("start", line))
            if line == "**user**: hi":
                first_entered.set()
                if not release_first.wait(timeout=2):
                    errors.append("first append timed out")
            order.append(("end", line))

        def run_event(payload):
            try:
                lc.run(payload)
            except BaseException as exc:
                errors.append(exc)

        first = threading.Thread(
            target=run_event,
            args=({"hook_event_name": "UserPromptSubmit", "prompt": "hi", "session_id": session_id},),
            daemon=True,
        )
        second = threading.Thread(
            target=run_event,
            args=({"hook_event_name": "Stop", "last_assistant_message": "hey", "session_id": session_id},),
            daemon=True,
        )
        with tempfile.TemporaryDirectory() as lock_dir, mock.patch.dict("os.environ", env, clear=True), mock.patch.object(
            lc, "LOCK_DIR", lock_dir
        ), mock.patch.object(lc, "append_line", side_effect=append), mock.patch.object(lc.os, "open", side_effect=observe_open):
            first.start()
            try:
                self.assertTrue(first_entered.wait(timeout=2), "first append did not start")
                second.start()
                self.assertTrue(contention_observed.wait(timeout=2), "second event did not contend for the lock")
                self.assertEqual(order, [("start", "**user**: hi")])
            finally:
                release_first.set()
                first.join(timeout=2)
                if second.ident is not None:
                    second.join(timeout=2)
            self.assertFalse(first.is_alive(), "first worker did not finish")
            self.assertFalse(second.is_alive(), "second worker did not finish")
            self.assertFalse(os.path.exists(lc._session_lock_path(session_id)))

        self.assertEqual(errors, [])
        self.assertEqual(order, [
            ("start", "**user**: hi"), ("end", "**user**: hi"),
            ("start", "**assistant**: hey"), ("end", "**assistant**: hey"),
        ])



if __name__ == "__main__":
    unittest.main()
