#!/usr/bin/env python3
import importlib.util
import json
import sqlite3
import tempfile
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / "codex_telemetry_daemon.py"
spec = importlib.util.spec_from_file_location("codex_telemetry_daemon", DAEMON)
ctd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctd)


def open_temp_db():
    tmp = tempfile.NamedTemporaryFile(prefix="codex-telemetry-test-", suffix=".sqlite", delete=False)
    tmp.close()
    return Path(tmp.name), ctd.connect(tmp.name)


def insert_request(conn, log_id, thread="thread-a", turn="turn-a", tier="priority", effort="xhigh", model="gpt-5.5"):
    conn.execute(
        "insert into app_response_requests values(?,?,?,?,?,?,?,?,?,?,?)",
        ("source", log_id, 1000 + log_id, thread, turn, model, tier, effort, "cache", None, "{}"),
    )


def insert_completed(conn, log_id, response_id, thread="thread-a", turn="turn-a", served="default", created=1000, completed=1002, output=20, reasoning=4, total=120, model="gpt-5.5", raw_json="{}"):
    conn.execute(
        "insert into app_response_events values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("source", log_id, 1000 + log_id, thread, turn, "response.completed", response_id, model, served, created, completed, 90, 10, output, reasoning, total, raw_json),
    )


def mark_interactive_thread(conn, thread="thread-a"):
    conn.execute(
        "insert into codex_thread_metadata(thread_id,captured_at,title,first_user_message) values(?,?,?,?)",
        (thread, ctd.now_iso(), "Interactive", "User message"),
    )


def test_response_id_is_primary_identity():
    path, conn = open_temp_db()
    try:
        mark_interactive_thread(conn)
        insert_request(conn, 1)
        insert_completed(conn, 2, "resp-a", output=20, completed=1002)
        insert_completed(conn, 3, "resp-b", output=30, completed=1003)
        ctd.refresh_turn_observations(conn)
        conn.commit()
        rows = conn.execute("select response_id, mode, reasoning_effort, output_tokens_per_second, non_reasoning_tokens_per_second from codex_turns order by response_id").fetchall()
        assert len(rows) == 2, rows
        assert [r[0] for r in rows] == ["resp-a", "resp-b"], rows
        assert all(r[1] == "fast" for r in rows), rows
        assert all(r[2] == "xhigh" for r in rows), rows
        assert rows[0][3] == 10.0, rows
        assert rows[0][4] == 8.0, rows
        ctd.set_state(conn, "trusted_cutover_at", "1970-01-01T00:00:00+00:00")
        trusted_count = conn.execute("select count(*) from trusted_codex_turns").fetchone()[0]
        assert trusted_count == 2, trusted_count
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def test_duplicate_response_collapses_to_latest_completion():
    path, conn = open_temp_db()
    try:
        mark_interactive_thread(conn)
        insert_request(conn, 1, tier="default", effort="medium")
        insert_completed(conn, 2, "resp-a", output=20, completed=1002)
        insert_completed(conn, 4, "resp-a", output=50, completed=1005)
        ctd.refresh_turn_observations(conn)
        conn.commit()
        rows = conn.execute("select response_id, mode, reasoning_effort, output_tokens, output_tokens_per_second from codex_turns").fetchall()
        assert len(rows) == 1, rows
        assert rows[0][0] == "resp-a", rows
        assert rows[0][1] == "default", rows
        assert rows[0][2] == "medium", rows
        assert rows[0][3] == 50, rows
        assert rows[0][4] == 10.0, rows
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def test_speed_view_excludes_short_quantized_responses():
    path, conn = open_temp_db()
    try:
        mark_interactive_thread(conn)
        insert_request(conn, 1, tier="priority", effort="xhigh")
        insert_completed(conn, 2, "resp-short", output=200, created=1000, completed=1003)
        insert_completed(conn, 3, "resp-long", output=200, created=1000, completed=1006)
        ctd.refresh_turn_observations(conn)
        ctd.set_state(conn, "trusted_cutover_at", "1970-01-01T00:00:00+00:00")
        conn.commit()
        usage_count = conn.execute("select count(*) from trusted_codex_turns").fetchone()[0]
        speed_rows = conn.execute("select response_id from trusted_codex_speed_turns order by response_id").fetchall()
        assert usage_count == 2, usage_count
        assert speed_rows == [("resp-long",)], speed_rows
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def test_speed_view_excludes_image_generation_responses():
    path, conn = open_temp_db()
    try:
        mark_interactive_thread(conn)
        insert_request(conn, 1, tier="default", effort="xhigh")
        image_raw = '{"response":{"tool_usage":{"image_gen":{"total_tokens":5000,"output_tokens_details":{"image_tokens":4200}}}}}'
        web_raw = '{"response":{"tool_usage":{"web_search":{"total_tokens":0,"input_tokens":0,"output_tokens":0,"num_requests":1}}}}'
        insert_completed(conn, 2, "resp-image", output=400, created=1000, completed=1100, raw_json=image_raw)
        insert_completed(conn, 3, "resp-web", output=400, created=1000, completed=1100, raw_json=web_raw)
        insert_completed(conn, 4, "resp-text", output=400, created=1000, completed=1100)
        ctd.refresh_turn_observations(conn)
        ctd.set_state(conn, "trusted_cutover_at", "1970-01-01T00:00:00+00:00")
        conn.commit()
        usage_rows = conn.execute("select response_id from trusted_codex_turns order by response_id").fetchall()
        speed_rows = conn.execute("select response_id from trusted_codex_speed_turns order by response_id").fetchall()
        assert usage_rows == [("resp-image",), ("resp-text",), ("resp-web",)], usage_rows
        assert speed_rows == [("resp-text",)], speed_rows
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def test_trusted_view_excludes_background_thread_classes():
    path, conn = open_temp_db()
    try:
        mark_interactive_thread(conn, "interactive")
        insert_request(conn, 1, thread="interactive", turn="turn-a")
        insert_completed(conn, 2, "resp-interactive", thread="interactive", turn="turn-a", output=200, created=1000, completed=1006)
        insert_request(conn, 3, thread="automation", turn="turn-b")
        insert_completed(conn, 4, "resp-automation", thread="automation", turn="turn-b", output=200, created=1000, completed=1006)
        insert_request(conn, 5, thread="subagent", turn="turn-c")
        insert_completed(conn, 6, "resp-subagent", thread="subagent", turn="turn-c", output=200, created=1000, completed=1006)
        insert_completed(conn, 7, "resp-missing-thread", thread="", turn="", output=200, created=1000, completed=1006)
        now = ctd.now_iso()
        conn.execute(
            "insert into codex_thread_metadata(thread_id,captured_at,first_user_message,parent_thread_id) values(?,?,?,?)",
            ("automation", now, "Automation: Queue Keeper", None),
        )
        conn.execute(
            "insert into codex_thread_metadata(thread_id,captured_at,first_user_message,parent_thread_id) values(?,?,?,?)",
            ("subagent", now, "child", "parent-thread"),
        )
        ctd.refresh_turn_observations(conn)
        ctd.set_state(conn, "trusted_cutover_at", "1970-01-01T00:00:00+00:00")
        conn.commit()
        rows = conn.execute("select response_id from trusted_codex_turns order by response_id").fetchall()
        assert rows == [("resp-interactive",)], rows
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def test_otel_trace_turn_rate_and_reasoning():
    path, conn = open_temp_db()
    try:
        conn.execute(
            "insert into otel_trace_spans values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (1, 0, "session_task.turn", "trace", "span", None, "thread-cli", "turn-cli", "gpt-5.5", "high", 100, 25, 40, 12, 140, "1000000000000", "1004000000000", "{}"),
        )
        ctd.refresh_turn_observations(conn)
        ctd.set_state(conn, "trusted_cutover_at", "1970-01-01T00:00:00+00:00")
        conn.commit()
        rows = conn.execute("select surface, model, reasoning_effort, output_tokens, reasoning_tokens, output_tokens_per_second, non_reasoning_tokens_per_second from codex_turns").fetchall()
        assert rows == [("otel", "gpt-5.5", "high", 40, 12, 10.0, 7.0)], rows
        trusted_rows = conn.execute("select source_id from trusted_codex_turns").fetchall()
        assert trusted_rows == [], trusted_rows
        speed_rows = conn.execute("select response_id from trusted_codex_speed_turns").fetchall()
        assert speed_rows == [], speed_rows
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def test_tracked_cli_otel_is_trusted_usage_but_not_speed():
    path, conn = open_temp_db()
    try:
        conn.execute(
            "insert into cli_invocations values(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            ("inv-a", "1970-01-01T00:00:00+00:00", None, "/tmp", '["codex"]', "exec", None, "high", "fast", "true", "thread-cli", "{}", 0),
        )
        conn.execute(
            "insert into otel_trace_spans values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (1, 0, "session_task.turn", "trace", "span", None, "thread-cli", "turn-cli", "gpt-5.5", "high", 100, 25, 400, 120, 500, "1000000000000", "1100000000000", "{}"),
        )
        ctd.refresh_turn_observations(conn)
        ctd.set_state(conn, "trusted_cutover_at", "1970-01-01T00:00:00+00:00")
        conn.commit()
        trusted_rows = conn.execute("select surface, mode, total_tokens from trusted_codex_turns").fetchall()
        speed_rows = conn.execute("select source_id from trusted_codex_speed_turns").fetchall()
        assert trusted_rows == [("cli_tracked", "fast", 500)], trusted_rows
        assert speed_rows == [], speed_rows
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def insert_otlp_request(conn, path, received_at):
    cur = conn.execute(
        """
        insert into otlp_requests(
          received_at,method,path,content_type,content_encoding,body_len,body_sha256,
          body_text,body_b64,json_valid,top_level_keys,remote_addr
        ) values(?,?,?,?,?,?,?,?,?,?,?,?)
        """,
        (received_at, "POST", path, "application/json", None, 2, "sha", "{}", None, 1, "[]", "127.0.0.1"),
    )
    return cur.lastrowid


def insert_response_stream(conn, request_id, thread, trace, span, duration_seconds=5):
    end_nano = int(datetime.fromisoformat("2026-10-01T12:00:00+00:00").timestamp()) * 1_000_000_000
    start_nano = end_nano - duration_seconds * 1_000_000_000
    conn.execute(
        "insert into otel_trace_spans values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (request_id, 0, "session_task.turn", trace, "parent-" + span, None, thread, "turn-" + span, "gpt-6.1-sol", "high", 1000, 800, 200, 20, 1200, str(start_nano - 1_000_000_000), str(end_nano + 1_000_000_000), "{}"),
    )
    conn.execute(
        "insert into otel_trace_spans values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (request_id, 1, "responses_websocket.stream_request", trace, span, "parent-" + span, "4", None, None, None, None, None, None, None, None, str(start_nano), str(end_nano), "{}"),
    )


def test_modern_otel_response_stream_is_trusted_for_interactive_thread():
    path, conn = open_temp_db()
    try:
        mark_interactive_thread(conn, "thread-modern")
        ctd.set_state(conn, "trusted_cutover_at", "1970-01-01T00:00:00+00:00")
        log_request = insert_otlp_request(conn, "/v1/logs", "2026-10-01T12:00:01+00:00")
        trace_request = insert_otlp_request(conn, "/v1/traces", "2026-10-01T12:00:02+00:00")
        attrs = {
            "event.name": "codex.sse_event",
            "event.kind": "response.completed",
            "event.timestamp": "2026-10-01T12:00:00Z",
            "conversation.id": "thread-modern",
            "model": "gpt-6.1-sol",
            "model_reasoning_effort": "high",
            "service_tier": "priority",
            "ttft_ms": "700",
            "user.email": "must-not-enter-cache@example.com",
        }
        conn.execute(
            "insert into otel_log_events values(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (log_request, 0, "codex.sse_event", "response.completed", "thread-modern", "gpt-6.1-sol", None, None, 1000, 800, 200, 20, 1220, json.dumps(attrs)),
        )
        insert_response_stream(conn, trace_request, "thread-modern", "trace-modern", "span-modern")
        ctd.rebuild_trusted_turn_cache(conn)
        row = conn.execute(
            """
            select source, surface, model, mode, output_tokens, output_tokens_per_second,
                   speed_eligible, lane, raw_json
            from trusted_turn_cache
            """
        ).fetchone()
        assert row[:8] == (
            "otel_response_stream",
            "otel_authenticated_thread",
            "gpt-6.1-sol",
            "fast",
            200,
            40.0,
            1,
            "Fast",
        ), row
        assert "must-not-enter-cache" not in row[8], row[8]
        assert json.loads(row[8])["matching_streams"] == 1

        # Concurrent threads with the same model and completion time must never
        # lend their response duration to this thread.
        other_request = insert_otlp_request(conn, "/v1/traces", "2026-10-01T12:00:02+00:00")
        insert_response_stream(conn, other_request, "other-thread", "other-trace", "other-span", 10)
        ctd.rebuild_trusted_turn_cache(conn)
        assert conn.execute("select output_tokens_per_second from trusted_turn_cache").fetchone()[0] == 40.0

        # If an identity/timestamp yields two candidates, keep usage but refuse
        # to report a speed instead of guessing a matching stream.
        ambiguous_request = insert_otlp_request(conn, "/v1/traces", "2026-10-01T12:00:02+00:00")
        insert_response_stream(conn, ambiguous_request, "thread-modern", "ambiguous-trace", "ambiguous-span", 8)
        ctd.rebuild_trusted_turn_cache(conn)
        assert conn.execute("select output_tokens_per_second,speed_eligible from trusted_turn_cache").fetchone() == (None, 0)
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def test_modern_otel_response_stream_requires_trusted_thread_metadata():
    path, conn = open_temp_db()
    try:
        ctd.set_state(conn, "trusted_cutover_at", "1970-01-01T00:00:00+00:00")
        log_request = insert_otlp_request(conn, "/v1/logs", "2026-10-01T12:00:01+00:00")
        trace_request = insert_otlp_request(conn, "/v1/traces", "2026-10-01T12:00:02+00:00")
        attrs = {
            "event.name": "codex.sse_event",
            "event.kind": "response.completed",
            "event.timestamp": "2026-10-01T12:00:00Z",
            "conversation.id": "untrusted-thread",
            "model": "gpt-6.1-sol",
        }
        conn.execute(
            "insert into otel_log_events values(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (log_request, 0, "codex.sse_event", "response.completed", "untrusted-thread", "gpt-6.1-sol", None, None, 1000, 800, 200, 20, 1220, json.dumps(attrs)),
        )
        insert_response_stream(conn, trace_request, "untrusted-thread", "untrusted-trace", "untrusted-span")
        ctd.rebuild_trusted_turn_cache(conn)
        assert conn.execute("select count(*) from trusted_turn_cache").fetchone()[0] == 0
        mark_interactive_thread(conn, "untrusted-thread")
        conn.execute("update codex_thread_metadata set parent_thread_id=? where thread_id=?", ("parent", "untrusted-thread"))
        ctd.rebuild_trusted_turn_cache(conn)
        assert conn.execute("select count(*) from trusted_turn_cache").fetchone()[0] == 0
    finally:
        conn.close()
        path.unlink(missing_ok=True)


def test_mode_inference_for_fast_and_standard():
    assert ctd.infer_mode("priority", "default") == "fast"
    assert ctd.infer_mode("default", "fast") == "fast"
    assert ctd.infer_mode("auto", None) == "auto"
    assert ctd.infer_mode(None, "default") == "default"


def run():
    tests = [
        test_response_id_is_primary_identity,
        test_duplicate_response_collapses_to_latest_completion,
        test_speed_view_excludes_short_quantized_responses,
        test_speed_view_excludes_image_generation_responses,
        test_trusted_view_excludes_background_thread_classes,
        test_otel_trace_turn_rate_and_reasoning,
        test_tracked_cli_otel_is_trusted_usage_but_not_speed,
        test_modern_otel_response_stream_is_trusted_for_interactive_thread,
        test_modern_otel_response_stream_requires_trusted_thread_metadata,
        test_mode_inference_for_fast_and_standard,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print("PASS all pipeline regression tests")


if __name__ == "__main__":
    run()
