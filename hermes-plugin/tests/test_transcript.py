from robot_notes.transcript import (
    MAX_TRANSCRIPT_BYTES,
    build_transcript,
    is_compaction_summary_message,
)


def test_empty_session_produces_placeholder_note():
    body = build_transcript([], session_id="s1", actor="hermes-bot")

    assert "(empty session)" in body
    assert "Session: s1" in body
    assert "Actor: hermes-bot" in body
    assert "Turns: 0" in body


def test_drops_tool_and_system_roles():
    messages = [
        {"role": "system", "content": "you are a helpful assistant"},
        {"role": "user", "content": "hi"},
        {"role": "tool", "content": "tool result payload"},
        {"role": "assistant", "content": "hello"},
    ]

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")

    assert "you are a helpful assistant" not in body
    assert "tool result payload" not in body
    assert "**user**: hi" in body
    assert "**assistant**: hello" in body


def test_drops_assistant_messages_that_are_only_tool_calls():
    messages = [
        {"role": "user", "content": "search for the weather"},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [{"id": "call_1", "function": {"name": "search", "arguments": "{}"}}],
        },
        {"role": "assistant", "content": "it is sunny"},
    ]

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")

    assert "call_1" not in body
    assert "tool_calls" not in body
    assert "**assistant**: it is sunny" in body
    assert body.count("**assistant**:") == 1


def test_skips_compaction_summary_messages_by_metadata_flag():
    messages = [
        {"role": "user", "content": "earlier turns", "_compressed_summary": True},
        {"role": "user", "content": "the real question"},
        {"role": "assistant", "content": "the real answer"},
    ]

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")

    assert "earlier turns" not in body
    assert "the real question" in body


def test_skips_compaction_summary_messages_by_content_prefix():
    summary_text = (
        "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the "
        "summary below. This is a handoff from a previous context window..."
    )
    messages = [
        {"role": "user", "content": summary_text},
        {"role": "user", "content": "what's next"},
    ]

    assert is_compaction_summary_message(messages[0]) is True
    assert is_compaction_summary_message(messages[1]) is False

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")
    assert "Earlier turns were compacted" not in body
    assert "what's next" in body


def test_legacy_compaction_summary_prefix_is_detected():
    message = {"role": "assistant", "content": "[CONTEXT SUMMARY]: everything so far"}
    assert is_compaction_summary_message(message) is True


def test_strips_memory_context_block_from_user_turns():
    messages = [
        {
            "role": "user",
            "content": (
                "<memory-context>\n"
                "[System note: recalled memory context]\n\n"
                "the user prefers dark mode\n"
                "</memory-context>"
                "what's the weather today"
            ),
        }
    ]

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")

    assert "recalled memory context" not in body
    assert "prefers dark mode" not in body
    assert "what's the weather today" in body


def test_list_content_keeps_only_text_parts():
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "look at this"},
                {"type": "image", "source": {"data": "base64blob"}},
            ],
        },
        {
            "role": "assistant",
            "content": [
                {"type": "tool_use", "id": "call_1", "name": "search", "input": {"q": "weather"}},
                {"type": "text", "text": "here is the answer"},
            ],
        },
    ]

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")

    assert "look at this" in body
    assert "here is the answer" in body
    assert "base64blob" not in body
    assert "tool_use" not in body
    assert "call_1" not in body


def test_title_is_derived_from_first_user_message_and_bounded():
    long_first_line = "x" * 200
    messages = [{"role": "user", "content": long_first_line}]

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")

    title_line = body.splitlines()[0]
    assert title_line.startswith("# ")
    assert len(title_line) - 2 <= 80
    assert title_line.endswith("…")


def test_header_includes_session_actor_date_and_turn_count():
    messages = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}]

    body = build_transcript(messages, session_id="session-42", actor="hermes-bot")

    assert "Session: session-42" in body
    assert "Actor: hermes-bot" in body
    assert "Turns: 2" in body
    import re

    assert re.search(r"Date: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", body)


def test_bounds_total_size_with_head_and_tail_elision_marker():
    messages = []
    for i in range(2000):
        messages.append({"role": "user", "content": f"user turn {i} " + "word " * 20})
        messages.append({"role": "assistant", "content": f"assistant turn {i} " + "word " * 20})

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")

    assert len(body.encode("utf-8")) <= MAX_TRANSCRIPT_BYTES + 1024  # header + marker overhead
    assert "elided" in body
    # keeps the very first and very last turns (head and tail of the conversation)
    assert "user turn 0 " in body
    assert "assistant turn 1999 " in body
    # something in the middle got dropped
    assert "user turn 1000 " not in body


def test_single_oversized_message_is_truncated_not_dropped():
    huge_text = "y" * (MAX_TRANSCRIPT_BYTES * 2)
    messages = [{"role": "user", "content": huge_text}]

    body = build_transcript(messages, session_id="s1", actor="hermes-bot")

    assert len(body.encode("utf-8")) <= MAX_TRANSCRIPT_BYTES + 1024
    assert "**user**:" in body
