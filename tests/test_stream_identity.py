"""Regressions for exact envelope trace identity without a completed turn span."""
import json
from unittest.mock import patch
from test_pipeline import (ctd, open_temp_db, mark_interactive_thread,
                           insert_otlp_request, insert_response_stream)

def fixture(conn, trace_id='trace-live'):
    mark_interactive_thread(conn, 'thread-live')
    ctd.set_state(conn, 'trusted_cutover_at', '1970-01-01T00:00:00+00:00')
    log = insert_otlp_request(conn, '/v1/logs', '2026-10-01T12:00:01+00:00')
    attributes = {
        'event.name': 'codex.sse_event', 'event.kind': 'response.completed',
        'event.timestamp': '2026-10-01T12:00:00Z', 'conversation.id': 'thread-live',
        'model': 'gpt-6.1-sol', 'model_reasoning_effort': 'max',
        'service_tier': 'priority', 'input_token_count': 1000,
        'output_token_count': 200, 'reasoning_token_count': 20,
    }
    def attr(key, value):
        return {'key': key, 'value': {'intValue': str(value)} if isinstance(value, int) else {'stringValue': value}}
    record = {'attributes': [attr(k,v) for k,v in attributes.items()]}
    if trace_id is not None: record['traceId'] = trace_id
    ctd.parse_otlp(conn, log, '/v1/logs', json.dumps({'resourceLogs': [{'scopeLogs': [{'logRecords': [record]}]}]}))
    trace = insert_otlp_request(conn, '/v1/traces', '2026-10-01T12:00:02+00:00')
    insert_response_stream(conn, trace, 'thread-live', 'trace-live', 'span-live')
    conn.execute("DELETE FROM otel_trace_spans WHERE span_name='session_task.turn'")
    return log, trace

def speed(conn):
    ctd.rebuild_trusted_turn_cache(conn)
    return conn.execute('SELECT duration_ms, output_tokens_per_second, speed_eligible FROM trusted_turn_cache').fetchall()

def test_parentless_exact_trace():
    path,conn=open_temp_db()
    try:
        fixture(conn)
        assert speed(conn)==[(5000.0,40.0,1)]
        # Another thread's coincident stream cannot contaminate the exact trace.
        other=insert_otlp_request(conn,'/v1/traces','2026-10-01T12:00:02+00:00')
        insert_response_stream(conn,other,'other-thread','other-trace','other-span',10)
        assert speed(conn)==[(5000.0,40.0,1)]
    finally: conn.close();path.unlink(missing_ok=True)

def test_parentless_missing_or_wrong_trace():
    for trace in (None, 'different-trace', '00000000000000000000000000000000'):
        path,conn=open_temp_db()
        try:
            fixture(conn,trace)
            assert speed(conn)==[(None,None,0)]
        finally: conn.close();path.unlink(missing_ok=True)

def test_parentless_ambiguous_stream():
    path,conn=open_temp_db()
    try:
        fixture(conn)
        other=insert_otlp_request(conn,'/v1/traces','2026-10-01T12:00:02+00:00')
        insert_response_stream(conn,other,'thread-live','trace-live','second-span',10)
        conn.execute("DELETE FROM otel_trace_spans WHERE span_name='session_task.turn'")
        assert speed(conn)==[(None,None,0)]
    finally: conn.close();path.unlink(missing_ok=True)

def test_one_stream_cannot_time_two_completions():
    path,conn=open_temp_db()
    try:
        log,trace=fixture(conn)
        conn.execute('INSERT INTO otel_log_events SELECT request_id,ordinal+1,event_name,event_kind,conversation_id,model,duration_ms,success,input_tokens,cached_tokens,output_tokens,reasoning_tokens,tool_tokens,attrs_json FROM otel_log_events WHERE request_id=?',(log,))
        assert speed(conn)==[(None,None,0),(None,None,0)]
    finally: conn.close();path.unlink(missing_ok=True)

def test_trace_with_conflicting_parent_identity():
    path,conn=open_temp_db()
    try:
        log,trace=fixture(conn)
        # A known contradictory identity must override a misleading trace envelope.
        insert_response_stream(conn,trace+1,'other-thread','trace-live','parented-stream')
        assert speed(conn)==[(None,None,0)]
    finally: conn.close();path.unlink(missing_ok=True)

def test_span_duration_and_minimums():
    for duration,eligible in ((0,0),(4000,0),(5000,1)):
        path,conn=open_temp_db()
        try:
            fixture(conn)
            conn.execute('UPDATE otel_trace_spans SET start_unix_nano=cast(cast(end_unix_nano AS integer)-? AS text)',(duration*1000000,))
            row=speed(conn)[0]
            assert row[2]==eligible
            assert row[0] == (duration if duration else None)
            if duration: assert row[1]==200000.0/duration
        finally: conn.close();path.unlink(missing_ok=True)

def test_lightweight_storage_keeps_exact_trace_identity():
    if not hasattr(ctd, 'storage'):
        return  # The Mac checkout does not use the Linux lightweight module.
    path,conn=open_temp_db()
    try:
        with patch.object(ctd.storage, 'ENABLED', True):
            fixture(conn)
            stored=json.loads(conn.execute('SELECT attrs_json FROM otel_log_events').fetchone()[0])
            assert stored['_otel.trace_id']=='trace-live'
            assert speed(conn)==[(5000.0,40.0,1)]
        assert ctd.storage.compact_attrs({'_otel.trace_id':'trace-live','user.email':'private@example.com'})=={'_otel.trace_id':'trace-live'}
    finally: conn.close();path.unlink(missing_ok=True)

if __name__=='__main__':
    for name,func in list(globals().items()):
        if name.startswith('test_') and callable(func):
            func();print('PASS',name)
