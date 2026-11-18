#!/usr/bin/env python3
import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import sqlite3
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "CodexSpeedMonitor"
CODEX_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
DEFAULT_DB = Path(os.environ.get("CODEX_TELEMETRY_DB", str(APP_SUPPORT / "codex_telemetry.sqlite"))).expanduser()
DEFAULT_LOG_DB = CODEX_HOME / "logs_2.sqlite"
DEFAULT_STATE_DB = CODEX_HOME / "state_5.sqlite"
CONFIG_PATH = CODEX_HOME / "config.toml"
GLOBAL_STATE_PATH = CODEX_HOME / ".codex-global-state.json"
STARTED_AT = datetime.now(timezone.utc)
CODEX_TURNS_VIEW_VERSION = "response-id-primary-v9"

SCHEMA = """
pragma journal_mode = wal;
pragma busy_timeout = 5000;
create table if not exists capture_state (
  key text primary key,
  value text not null,
  updated_at text not null
);
create table if not exists daemon_events (
  id integer primary key autoincrement,
  ts text not null,
  level text not null,
  event text not null,
  detail_json text
);
create table if not exists daemon_heartbeats (
  id integer primary key autoincrement,
  ts text not null,
  pid integer not null,
  uptime_seconds real not null,
  app_log_cursor integer,
  otlp_requests integer,
  app_response_events integer,
  turn_observations integer,
  best_turns integer
);
create table if not exists raw_app_logs (
  source_db text not null,
  log_id integer not null,
  ts integer not null,
  ts_nanos integer not null,
  imported_at text not null,
  level text,
  target text,
  thread_id text,
  process_uuid text,
  body text,
  primary key (source_db, log_id)
);
create index if not exists idx_raw_app_logs_thread on raw_app_logs(thread_id, ts);
create table if not exists app_response_requests (
  source_db text not null,
  log_id integer not null,
  ts integer not null,
  thread_id text,
  turn_id text,
  model text,
  service_tier text,
  reasoning_effort text,
  prompt_cache_key text,
  previous_response_id text,
  raw_json text not null,
  primary key (source_db, log_id)
);
create index if not exists idx_app_response_requests_thread_turn_log on app_response_requests(thread_id, turn_id, log_id);
create index if not exists idx_app_response_requests_thread_log on app_response_requests(thread_id, log_id);
create table if not exists app_response_events (
  source_db text not null,
  log_id integer not null,
  ts integer not null,
  thread_id text,
  turn_id text,
  event_type text,
  response_id text,
  model text,
  service_tier text,
  created_at integer,
  completed_at integer,
  input_tokens integer,
  cached_input_tokens integer,
  output_tokens integer,
  reasoning_tokens integer,
  total_tokens integer,
  raw_json text not null,
  primary key (source_db, log_id)
);
create index if not exists idx_app_response_events_completed on app_response_events(event_type, log_id);
create table if not exists otlp_requests (
  id integer primary key autoincrement,
  received_at text not null,
  method text not null,
  path text not null,
  content_type text,
  content_encoding text,
  body_len integer not null,
  body_sha256 text not null,
  body_text text,
  body_b64 text,
  json_valid integer not null default 0,
  top_level_keys text,
  remote_addr text
);
create index if not exists idx_otlp_requests_path_time on otlp_requests(path, received_at);
create table if not exists otel_log_events (
  request_id integer not null,
  ordinal integer not null,
  event_name text,
  event_kind text,
  conversation_id text,
  model text,
  duration_ms real,
  success text,
  input_tokens integer,
  cached_tokens integer,
  output_tokens integer,
  reasoning_tokens integer,
  tool_tokens integer,
  attrs_json text not null,
  primary key (request_id, ordinal)
);
create table if not exists otel_trace_spans (
  request_id integer not null,
  ordinal integer not null,
  span_name text,
  trace_id text,
  span_id text,
  parent_span_id text,
  thread_id text,
  turn_id text,
  model text,
  reasoning_effort text,
  input_tokens integer,
  cached_input_tokens integer,
  output_tokens integer,
  reasoning_output_tokens integer,
  total_tokens integer,
  start_unix_nano text,
  end_unix_nano text,
  attrs_json text not null,
  primary key (request_id, ordinal)
);
create index if not exists idx_otel_trace_spans_turn on otel_trace_spans(span_name, total_tokens, thread_id, turn_id);
create table if not exists otel_metric_points (
  request_id integer not null,
  ordinal integer not null,
  metric_name text not null,
  point_kind text,
  attrs_json text not null,
  count real,
  sum real,
  as_int integer,
  as_double real,
  primary key (request_id, ordinal)
);
create table if not exists cli_invocations (
  invocation_id text primary key,
  started_at text not null,
  ended_at text,
  cwd text not null,
  argv_json text not null,
  command text,
  model_override text,
  reasoning_effort_override text,
  service_tier_override text,
  fast_mode_override text,
  thread_id text,
  usage_json text,
  exit_code integer
);
create index if not exists idx_cli_invocations_thread_started on cli_invocations(thread_id, started_at);
create table if not exists config_snapshots (
  id integer primary key autoincrement,
  captured_at text not null,
  model text,
  reasoning_effort text,
  service_tier text,
  global_default_service_tier text,
  has_user_changed_service_tier integer,
  raw_config_sha256 text,
  raw_global_state_sha256 text
);
create table if not exists codex_thread_metadata (
  thread_id text primary key,
  captured_at text not null,
  title text,
  source text,
  thread_source text,
  model text,
  reasoning_effort text,
  cwd text,
  first_user_message text,
  agent_role text,
  agent_nickname text,
  parent_thread_id text,
  updated_at_ms integer
);
create table if not exists turn_observations (
  source text not null,
  source_id text not null,
  observed_at text not null,
  surface text not null,
  thread_id text,
  turn_id text,
  response_id text,
  model text,
  reasoning_effort text,
  service_tier_requested text,
  service_tier_served text,
  mode text,
  input_tokens integer,
  cached_input_tokens integer,
  output_tokens integer,
  reasoning_tokens integer,
  total_tokens integer,
  started_at text,
  completed_at text,
  ttft_ms real,
  duration_ms real,
  output_tokens_per_second real,
  non_reasoning_tokens_per_second real,
  confidence text not null,
  raw_json text,
  primary key (source, source_id)
);
create index if not exists idx_turn_observations_time on turn_observations(completed_at);
create index if not exists idx_turn_observations_thread on turn_observations(thread_id, turn_id);
create table if not exists trusted_turn_cache (
  source text not null,
  source_id text not null,
  observed_at text not null,
  surface text not null,
  thread_id text,
  turn_id text,
  response_id text,
  model text,
  reasoning_effort text,
  service_tier_requested text,
  service_tier_served text,
  mode text,
  input_tokens integer,
  cached_input_tokens integer,
  output_tokens integer,
  reasoning_tokens integer,
  total_tokens integer,
  started_at text,
  completed_at text,
  ttft_ms real,
  duration_ms real,
  output_tokens_per_second real,
  non_reasoning_tokens_per_second real,
  confidence text not null,
  raw_json text,
  speed_eligible integer not null,
  lane text not null,
  day_bucket text,
  hour_bucket text,
  five_min_bucket text,
  cache_updated_at text not null,
  primary key (source, source_id)
);
create index if not exists idx_trusted_turn_cache_completed on trusted_turn_cache(completed_at);
create index if not exists idx_trusted_turn_cache_speed_completed on trusted_turn_cache(speed_eligible, completed_at);
create index if not exists idx_trusted_turn_cache_day_lane on trusted_turn_cache(day_bucket, lane);
create index if not exists idx_trusted_turn_cache_hour_lane on trusted_turn_cache(hour_bucket, lane);
create index if not exists idx_trusted_turn_cache_mode on trusted_turn_cache(mode, completed_at);
create index if not exists idx_trusted_turn_cache_model on trusted_turn_cache(model, mode, reasoning_effort);
create table if not exists effective_turns (
  source_path text not null,
  source_mtime integer not null,
  turn_id text not null,
  trace_id text,
  observed_at text not null,
  started_at text,
  completed_at text,
  duration_ms real,
  time_to_first_token_ms real,
  model text,
  reasoning_effort text,
  service_tier_requested text,
  service_tier_served text,
  mode text,
  cwd text,
  user_message text,
  output_tokens integer,
  reasoning_tokens integer,
  input_tokens integer,
  cached_input_tokens integer,
  total_tokens integer,
  token_event_count integer not null default 0,
  tool_call_count integer not null default 0,
  terminal_call_count integer not null default 0,
  browser_call_count integer not null default 0,
  image_call_count integer not null default 0,
  tool_wait_ms real,
  effective_tokens_per_second real,
  token_source text not null,
  confidence text not null,
  raw_summary_json text,
  primary key (source_path, turn_id)
);
create index if not exists idx_effective_turns_completed on effective_turns(completed_at);
create index if not exists idx_effective_turns_mode on effective_turns(mode, completed_at);
create index if not exists idx_effective_turns_model on effective_turns(model, mode, reasoning_effort);
create view if not exists codex_turns as
with ranked as (
  select o.*,
    row_number() over (
      partition by
        case
          when o.response_id is not null and o.response_id != '' then 'response:' || o.response_id
          when o.thread_id is not null and o.thread_id != '' and o.turn_id is not null and o.turn_id != '' then 'turn:' || o.thread_id || ':' || o.turn_id
          else 'observation:' || o.source || ':' || o.source_id
        end
      order by
        case when o.service_tier_served is not null or o.service_tier_requested is not null then 0 else 1 end,
        case o.source when 'app_response' then 0 when 'otel_trace' then 1 else 2 end,
        o.completed_at desc
    ) as rn
  from turn_observations o
)
select * from ranked where rn = 1;
create view if not exists trusted_codex_turns as
select c.*
from codex_turns c
join capture_state s on s.key='trusted_cutover_at'
left join codex_thread_metadata m on m.thread_id=c.thread_id
where c.completed_at is not null and c.completed_at >= s.value
  and c.thread_id is not null and c.thread_id != ''
  and (c.source = 'app_response' or c.surface = 'cli_tracked')
  and (c.surface = 'cli_tracked' or m.thread_id is not null)
  and not (
    coalesce(m.first_user_message,'') like 'Automation:%'
    or lower(coalesce(m.thread_source,'')) in ('automation', 'heartbeat')
    or coalesce(m.parent_thread_id,'') != ''
    or coalesce(m.agent_role,'') != ''
    or coalesce(m.agent_nickname,'') != ''
  );
create view if not exists trusted_codex_speed_turns as
select *
from trusted_codex_turns
where source = 'app_response'
  and output_tokens_per_second is not null
  and output_tokens_per_second >= 0
  and duration_ms is not null
  and duration_ms >= 5000
  and output_tokens is not null
  and output_tokens >= 100
  and not exists (
    select 1
    from json_each(case when json_valid(raw_json) then raw_json else '{"response":{"tool_usage":{}}}' end, '$.response.tool_usage') tool
    where coalesce(json_extract(tool.value, '$.total_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.input_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.output_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.input_tokens_details.image_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.input_tokens_details.text_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.output_tokens_details.image_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.output_tokens_details.text_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.num_requests'), 0) > 0
  );
"""

CODEX_TURNS_VIEW_SQL = """
create view codex_turns as
with ranked as (
  select o.*,
    row_number() over (
      partition by
        case
          when o.response_id is not null and o.response_id != '' then 'response:' || o.response_id
          when o.thread_id is not null and o.thread_id != '' and o.turn_id is not null and o.turn_id != '' then 'turn:' || o.thread_id || ':' || o.turn_id
          else 'observation:' || o.source || ':' || o.source_id
        end
      order by
        case when o.service_tier_served is not null or o.service_tier_requested is not null then 0 else 1 end,
        case o.source when 'app_response' then 0 when 'otel_trace' then 1 else 2 end,
        o.completed_at desc
    ) as rn
  from turn_observations o
)
select * from ranked where rn = 1
"""

TRUSTED_CODEX_TURNS_VIEW_SQL = """
create view trusted_codex_turns as
select c.*
from codex_turns c
join capture_state s on s.key='trusted_cutover_at'
left join codex_thread_metadata m on m.thread_id=c.thread_id
where c.completed_at is not null and c.completed_at >= s.value
  and c.thread_id is not null and c.thread_id != ''
  and (c.source = 'app_response' or c.surface = 'cli_tracked')
  and (c.surface = 'cli_tracked' or m.thread_id is not null)
  and not (
    coalesce(m.first_user_message,'') like 'Automation:%'
    or lower(coalesce(m.thread_source,'')) in ('automation', 'heartbeat')
    or coalesce(m.parent_thread_id,'') != ''
    or coalesce(m.agent_role,'') != ''
    or coalesce(m.agent_nickname,'') != ''
  )
"""

TRUSTED_CODEX_SPEED_TURNS_VIEW_SQL = """
create view trusted_codex_speed_turns as
select *
from trusted_codex_turns
where source = 'app_response'
  and output_tokens_per_second is not null
  and output_tokens_per_second >= 0
  and duration_ms is not null
  and duration_ms >= 5000
  and output_tokens is not null
  and output_tokens >= 100
  and not exists (
    select 1
    from json_each(case when json_valid(raw_json) then raw_json else '{"response":{"tool_usage":{}}}' end, '$.response.tool_usage') tool
    where coalesce(json_extract(tool.value, '$.total_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.input_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.output_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.input_tokens_details.image_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.input_tokens_details.text_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.output_tokens_details.image_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.output_tokens_details.text_tokens'), 0) > 0
       or coalesce(json_extract(tool.value, '$.num_requests'), 0) > 0
  )
"""

SPAN_FIELD_RE = re.compile(r"([a-zA-Z0-9_.-]+)=([^\s}:]+)")
WS_REQUEST_RE = re.compile(r"websocket request: (\{.*\})")
WS_EVENT_RE = re.compile(r"websocket event: (\{.*\})")


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def iso_from_unix_seconds(value):
    try:
        if value is None:
            return None
        return datetime.fromtimestamp(float(value), timezone.utc).isoformat(timespec="microseconds")
    except Exception:
        return None


def iso_from_unix_nano(value):
    try:
        if value is None:
            return None
        return datetime.fromtimestamp(int(value) / 1_000_000_000, timezone.utc).isoformat(timespec="microseconds")
    except Exception:
        return None


def ms_from_nano_delta(start, end):
    try:
        if start is None or end is None:
            return None
        return max(0.0, (int(end) - int(start)) / 1_000_000)
    except Exception:
        return None


def rate(tokens, duration_ms):
    try:
        if tokens is None or duration_ms is None or duration_ms <= 0:
            return None
        return float(tokens) / (float(duration_ms) / 1000.0)
    except Exception:
        return None


def value(v):
    if not isinstance(v, dict):
        return v
    for key in ("stringValue", "intValue", "doubleValue", "boolValue"):
        if key in v:
            return v[key]
    if "arrayValue" in v:
        return [value(x) for x in v["arrayValue"].get("values", [])]
    if "kvlistValue" in v:
        return {x.get("key"): value(x.get("value")) for x in v["kvlistValue"].get("values", [])}
    return v


def attrs(items):
    return {a.get("key"): value(a.get("value")) for a in items or []}


def int_or_none(x):
    try:
        if x is None:
            return None
        return int(x)
    except Exception:
        return None


def float_or_none(x):
    try:
        if x is None:
            return None
        return float(x)
    except Exception:
        return None


def connect(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=10)
    conn.executescript(SCHEMA)
    ensure_schema_migrations(conn)
    if conn.execute("select 1 from capture_state where key='trusted_cutover_at'").fetchone() is None:
        conn.execute(
            "insert into capture_state(key,value,updated_at) values(?,?,?)",
            ("trusted_cutover_at", now_iso(), now_iso()),
        )
    return conn


def ensure_schema_migrations(conn):
    row = conn.execute("select value from capture_state where key='schema:codex_turns_view'").fetchone()
    if row and row[0] == CODEX_TURNS_VIEW_VERSION:
        conn.execute(TRUSTED_CODEX_TURNS_VIEW_SQL.replace("create view trusted_codex_turns", "create view if not exists trusted_codex_turns"))
        conn.execute(TRUSTED_CODEX_SPEED_TURNS_VIEW_SQL.replace("create view trusted_codex_speed_turns", "create view if not exists trusted_codex_speed_turns"))
        return
    conn.execute("drop view if exists trusted_codex_speed_turns")
    conn.execute("drop view if exists trusted_codex_turns")
    conn.execute("drop view if exists codex_turns")
    conn.execute(CODEX_TURNS_VIEW_SQL)
    conn.execute(TRUSTED_CODEX_TURNS_VIEW_SQL)
    conn.execute(TRUSTED_CODEX_SPEED_TURNS_VIEW_SQL)
    conn.execute(
        "insert or replace into capture_state(key,value,updated_at) values(?,?,?)",
        ("schema:codex_turns_view", CODEX_TURNS_VIEW_VERSION, now_iso()),
    )


def get_state(conn, key, default=None):
    row = conn.execute("select value from capture_state where key=?", (key,)).fetchone()
    return row[0] if row else default


def set_state(conn, key, val):
    conn.execute("insert or replace into capture_state(key,value,updated_at) values(?,?,?)", (key, str(val), now_iso()))


def record_event(conn, level, event, detail=None):
    conn.execute(
        "insert into daemon_events(ts,level,event,detail_json) values(?,?,?,?)",
        (now_iso(), level, event, json.dumps(detail or {}, separators=(",", ":"))),
    )


def parse_span_fields(body):
    out = {}
    for k, v in SPAN_FIELD_RE.findall((body or "")[:2200]):
        if k in ("thread.id", "turn.id", "model", "codex.turn.reasoning_effort", "otel.name"):
            out[k] = v.strip('"')
    return out


def maybe_json(rx, body):
    m = rx.search(body or "")
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except Exception:
        return None


def infer_mode(requested, served, config_service=None, fast_mode=None):
    for v in (served, requested, config_service):
        if v and str(v).lower() in ("fast", "priority"):
            return "fast"
    for v in (requested, served, config_service):
        if v and str(v).lower() == "auto":
            return "auto"
    for v in (served, requested, config_service):
        if v:
            return str(v)
    if fast_mode and str(fast_mode).lower() in ("true", "1", "yes"):
        return "fast"
    return "default"


def ingest_app_logs(out_conn, source_db):
    source_path = Path(source_db)
    if not source_path.exists():
        return 0
    source_key = f"logs_cursor:{source_path}"
    uri = f"file:{source_path}?mode=ro&cache=shared"
    in_conn = sqlite3.connect(uri, uri=True, timeout=10)
    in_conn.row_factory = sqlite3.Row
    state_value = get_state(out_conn, source_key)
    if state_value is None:
        current_max = in_conn.execute("select coalesce(max(id), 0) from logs").fetchone()[0]
        set_state(out_conn, source_key, current_max)
        out_conn.commit()
        in_conn.close()
        return 0
    last_id = int(state_value)
    rows = in_conn.execute(
        """
        select id, ts, ts_nanos, level, target, thread_id, process_uuid, feedback_log_body
        from logs where id > ? order by id limit 5000
        """,
        (last_id,),
    ).fetchall()
    imported = 0
    max_id = last_id
    for row in rows:
        max_id = max(max_id, row["id"])
        body = row["feedback_log_body"] or ""
        req = maybe_json(WS_REQUEST_RE, body)
        ev = maybe_json(WS_EVENT_RE, body)
        is_completed_event = bool(ev and ev.get("type") == "response.completed")
        is_service_tier_hint = "service_tier requested=" in body
        if not (req or is_completed_event or is_service_tier_hint):
            continue
        out_conn.execute(
            "insert or ignore into raw_app_logs values(?,?,?,?,?,?,?,?,?,?)",
            (str(source_path), row["id"], row["ts"], row["ts_nanos"], now_iso(), row["level"], row["target"], row["thread_id"], row["process_uuid"], body),
        )
        span = parse_span_fields(body)
        if req:
            reasoning = req.get("reasoning") or {}
            out_conn.execute(
                "insert or replace into app_response_requests values(?,?,?,?,?,?,?,?,?,?,?)",
                (str(source_path), row["id"], row["ts"], row["thread_id"], span.get("turn.id"), req.get("model"), req.get("service_tier"), reasoning.get("effort"), req.get("prompt_cache_key"), req.get("previous_response_id"), json.dumps(req, separators=(",", ":"))),
            )
        if is_completed_event:
            resp = ev.get("response") or ev
            usage = resp.get("usage") or {}
            in_details = usage.get("input_tokens_details") or {}
            out_details = usage.get("output_tokens_details") or {}
            out_conn.execute(
                "insert or replace into app_response_events values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    str(source_path), row["id"], row["ts"], row["thread_id"], span.get("turn.id"), ev.get("type"), resp.get("id"), resp.get("model"), resp.get("service_tier"),
                    int_or_none(resp.get("created_at")), int_or_none(resp.get("completed_at")), int_or_none(usage.get("input_tokens")), int_or_none(in_details.get("cached_tokens")), int_or_none(usage.get("output_tokens")), int_or_none(out_details.get("reasoning_tokens")), int_or_none(usage.get("total_tokens")), json.dumps(ev, separators=(",", ":")),
                ),
            )
        imported += 1
    set_state(out_conn, source_key, max_id)
    out_conn.commit()
    in_conn.close()
    return imported


def parse_otlp(conn, request_id, path, body_text):
    try:
        data = json.loads(body_text)
    except Exception:
        return
    log_i = trace_i = metric_i = 0
    if path == "/v1/logs":
        for rl in data.get("resourceLogs", []):
            for sl in rl.get("scopeLogs", []):
                for rec in sl.get("logRecords", []):
                    a = attrs(rec.get("attributes"))
                    # Preserve envelope identity before bounded storage drops raw OTLP.
                    # Attribute thread.id on stream spans is an OS thread, not a conversation.
                    if rec.get("traceId") and set(rec["traceId"]) != {"0"}:
                        a["_otel.trace_id"] = rec["traceId"]
                    conn.execute(
                        "insert or replace into otel_log_events values(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (
                            request_id, log_i, a.get("event.name"), a.get("event.kind"), a.get("conversation.id"), a.get("model"), float_or_none(a.get("duration_ms")), str(a.get("success")) if a.get("success") is not None else None,
                            int_or_none(a.get("input_token_count")), int_or_none(a.get("cached_token_count")), int_or_none(a.get("output_token_count")), int_or_none(a.get("reasoning_token_count")), int_or_none(a.get("tool_token_count")), json.dumps(a, separators=(",", ":")),
                        ),
                    )
                    log_i += 1
    elif path == "/v1/traces":
        for rs in data.get("resourceSpans", []):
            for ss in rs.get("scopeSpans", []):
                for sp in ss.get("spans", []):
                    a = attrs(sp.get("attributes"))
                    conn.execute(
                        "insert or replace into otel_trace_spans values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (
                            request_id, trace_i, sp.get("name"), sp.get("traceId"), sp.get("spanId"), sp.get("parentSpanId"), a.get("thread.id"), a.get("turn.id"), a.get("model"), a.get("codex.turn.reasoning_effort"),
                            int_or_none(a.get("codex.turn.token_usage.input_tokens")), int_or_none(a.get("codex.turn.token_usage.cached_input_tokens")), int_or_none(a.get("codex.turn.token_usage.output_tokens")), int_or_none(a.get("codex.turn.token_usage.reasoning_output_tokens")), int_or_none(a.get("codex.turn.token_usage.total_tokens")), sp.get("startTimeUnixNano"), sp.get("endTimeUnixNano"), json.dumps(a, separators=(",", ":")),
                        ),
                    )
                    trace_i += 1
    elif path == "/v1/metrics":
        for rm in data.get("resourceMetrics", []):
            for sm in rm.get("scopeMetrics", []):
                for metric in sm.get("metrics", []):
                    root = metric.get("sum") or metric.get("histogram") or metric.get("gauge") or {}
                    point_kind = "sum" if "sum" in metric else "histogram" if "histogram" in metric else "gauge" if "gauge" in metric else None
                    for point in root.get("dataPoints", []):
                        a = attrs(point.get("attributes"))
                        conn.execute(
                            "insert or replace into otel_metric_points values(?,?,?,?,?,?,?,?,?)",
                            (request_id, metric_i, metric.get("name"), point_kind, json.dumps(a, separators=(",", ":")), float_or_none(point.get("count")), float_or_none(point.get("sum")), int_or_none(point.get("asInt")), float_or_none(point.get("asDouble"))),
                        )
                        metric_i += 1


def snapshot_config(conn):
    raw_config = CONFIG_PATH.read_text(errors="ignore") if CONFIG_PATH.exists() else ""
    raw_global = GLOBAL_STATE_PATH.read_text(errors="ignore") if GLOBAL_STATE_PATH.exists() else ""
    model = re.search(r'^model\s*=\s*"([^"]+)"', raw_config, re.M)
    effort = re.search(r'^model_reasoning_effort\s*=\s*"([^"]+)"', raw_config, re.M)
    service = re.search(r'^service_tier\s*=\s*"([^"]+)"', raw_config, re.M)
    global_default = changed = None
    try:
        gs = json.loads(raw_global) if raw_global else {}
        global_default = gs.get("default-service-tier")
        changed = 1 if gs.get("has-user-changed-service-tier") else 0
    except Exception:
        pass
    conn.execute(
        "insert into config_snapshots(captured_at,model,reasoning_effort,service_tier,global_default_service_tier,has_user_changed_service_tier,raw_config_sha256,raw_global_state_sha256) values(?,?,?,?,?,?,?,?)",
        (now_iso(), model.group(1) if model else None, effort.group(1) if effort else None, service.group(1) if service else None, global_default, changed, hashlib.sha256(raw_config.encode()).hexdigest() if raw_config else None, hashlib.sha256(raw_global.encode()).hexdigest() if raw_global else None),
    )


def ingest_thread_metadata(out_conn, state_db):
    state_path = Path(state_db)
    if not state_path.exists():
        return 0
    uri = f"file:{state_path}?mode=ro&cache=shared"
    in_conn = sqlite3.connect(uri, uri=True, timeout=10)
    in_conn.row_factory = sqlite3.Row
    try:
        tables = {r[0] for r in in_conn.execute("select name from sqlite_master where type='table'").fetchall()}
        if "threads" not in tables:
            return 0
        thread_cols = {r[1] for r in in_conn.execute("pragma table_info(threads)").fetchall()}
        def col(name, fallback="null"):
            return f"t.{name}" if name in thread_cols else fallback
        edge_expr = "null"
        join_expr = ""
        if "thread_spawn_edges" in tables:
            edge_expr = "e.parent_thread_id"
            join_expr = "left join thread_spawn_edges e on e.child_thread_id=t.id"
        rows = in_conn.execute(
            f"""
            select t.id,
                   {col("title")} as title,
                   {col("source")} as source,
                   {col("thread_source")} as thread_source,
                   {col("model")} as model,
                   {col("reasoning_effort")} as reasoning_effort,
                   {col("cwd")} as cwd,
                   {col("first_user_message")} as first_user_message,
                   {col("agent_role")} as agent_role,
                   {col("agent_nickname")} as agent_nickname,
                   {edge_expr} as parent_thread_id,
                   coalesce({col("updated_at_ms")}, {col("updated_at")}) as updated_at_ms
            from threads t
            {join_expr}
            """
        ).fetchall()
        captured = now_iso()
        for r in rows:
            out_conn.execute(
                """
                insert or replace into codex_thread_metadata(
                  thread_id,captured_at,title,source,thread_source,model,reasoning_effort,cwd,
                  first_user_message,agent_role,agent_nickname,parent_thread_id,updated_at_ms
                ) values(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    r["id"], captured, r["title"], r["source"], r["thread_source"], r["model"],
                    r["reasoning_effort"], r["cwd"], r["first_user_message"], r["agent_role"],
                    r["agent_nickname"], r["parent_thread_id"], r["updated_at_ms"],
                ),
            )
        return len(rows)
    finally:
        in_conn.close()


def nearest_request(conn, e):
    if e["turn_id"]:
        row = conn.execute(
            """
            select service_tier, reasoning_effort, model
            from app_response_requests
            where thread_id is ? and turn_id is ? and log_id <= ?
            order by log_id desc limit 1
            """,
            (e["thread_id"], e["turn_id"], e["log_id"]),
        ).fetchone()
        if row:
            return row
    return conn.execute(
        """
        select service_tier, reasoning_effort, model
        from app_response_requests
        where thread_id is ? and log_id <= ?
        order by log_id desc limit 1
        """,
        (e["thread_id"], e["log_id"]),
    ).fetchone()


def refresh_turn_observations(conn, full=False):
    conn.row_factory = sqlite3.Row
    inserted = 0
    event_sql = """
        select * from app_response_events e
        where e.event_type='response.completed'
    """
    if not full:
        event_sql += """
          and not exists (
            select 1 from turn_observations o
            where o.source='app_response' and o.source_id=cast(e.log_id as text)
          )
        """
    for e in conn.execute(event_sql).fetchall():
        req = nearest_request(conn, e)
        requested = req["service_tier"] if req else None
        effort = req["reasoning_effort"] if req else None
        model = e["model"] or (req["model"] if req else None)
        started = iso_from_unix_seconds(e["created_at"])
        completed = iso_from_unix_seconds(e["completed_at"]) or iso_from_unix_seconds(e["ts"])
        duration_ms = None
        if e["created_at"] is not None and e["completed_at"] is not None:
            duration_ms = max(0.0, (float(e["completed_at"]) - float(e["created_at"])) * 1000.0)
        out = e["output_tokens"]
        reasoning = e["reasoning_tokens"] or 0
        mode = infer_mode(requested, e["service_tier"])
        conn.execute(
            """
            insert or replace into turn_observations values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                "app_response", str(e["log_id"]), now_iso(), "desktop_app", e["thread_id"], e["turn_id"], e["response_id"], model, effort, requested, e["service_tier"], mode,
                e["input_tokens"], e["cached_input_tokens"], out, e["reasoning_tokens"], e["total_tokens"], started, completed, None, duration_ms, rate(out, duration_ms), rate((out or 0) - reasoning, duration_ms), "high" if mode else "medium", e["raw_json"],
            ),
        )
        inserted += 1
    span_sql = """
        select * from otel_trace_spans s
        where s.span_name='session_task.turn' and s.total_tokens is not null
    """
    if not full:
        span_sql += """
          and not exists (
            select 1 from turn_observations o
            where o.source='otel_trace' and o.source_id=(cast(s.request_id as text) || ':' || cast(s.ordinal as text))
          )
        """
    for s in conn.execute(span_sql).fetchall():
        inv = conn.execute("select * from cli_invocations where thread_id=? order by started_at desc limit 1", (s["thread_id"],)).fetchone()
        requested = inv["service_tier_override"] if inv else None
        effort = s["reasoning_effort"] or (inv["reasoning_effort_override"] if inv else None)
        started = iso_from_unix_nano(s["start_unix_nano"])
        completed = iso_from_unix_nano(s["end_unix_nano"])
        duration_ms = ms_from_nano_delta(s["start_unix_nano"], s["end_unix_nano"])
        out = s["output_tokens"]
        reasoning = s["reasoning_output_tokens"] or 0
        mode = infer_mode(requested, None, None, inv["fast_mode_override"] if inv else None)
        surface = "cli_tracked" if inv else "otel"
        conn.execute(
            """
            insert or replace into turn_observations values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                "otel_trace", f"{s['request_id']}:{s['ordinal']}", now_iso(), surface, s["thread_id"], s["turn_id"], None, s["model"], effort, requested, None, mode,
                s["input_tokens"], s["cached_input_tokens"], out, s["reasoning_output_tokens"], s["total_tokens"], started, completed, None, duration_ms, rate(out, duration_ms), rate((out or 0) - reasoning, duration_ms), "high" if inv else "medium", s["attrs_json"],
            ),
        )
        inserted += 1
    conn.row_factory = None
    return inserted


def rebuild_trusted_turn_cache(conn):
    updated_at = now_iso()
    conn.execute("delete from trusted_turn_cache")
    conn.execute(
        """
        insert into trusted_turn_cache(
          source, source_id, observed_at, surface, thread_id, turn_id, response_id,
          model, reasoning_effort, service_tier_requested, service_tier_served, mode,
          input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, total_tokens,
          started_at, completed_at, ttft_ms, duration_ms, output_tokens_per_second,
          non_reasoning_tokens_per_second, confidence, raw_json, speed_eligible, lane,
          day_bucket, hour_bucket, five_min_bucket, cache_updated_at
        )
        select
          c.source, c.source_id, c.observed_at, c.surface, c.thread_id, c.turn_id, c.response_id,
          c.model, c.reasoning_effort, c.service_tier_requested, c.service_tier_served, c.mode,
          c.input_tokens, c.cached_input_tokens, c.output_tokens, c.reasoning_tokens, c.total_tokens,
          c.started_at, c.completed_at, c.ttft_ms, c.duration_ms, c.output_tokens_per_second,
          c.non_reasoning_tokens_per_second, c.confidence, c.raw_json,
          case when c.source = 'app_response'
                 and c.output_tokens_per_second is not null
                 and c.output_tokens_per_second >= 0
                 and c.duration_ms is not null
                 and c.duration_ms >= 5000
                 and c.output_tokens is not null
                 and c.output_tokens >= 100
                 and not exists (
                   select 1
                   from json_each(case when json_valid(c.raw_json) then c.raw_json else '{"response":{"tool_usage":{}}}' end, '$.response.tool_usage') tool
                   where coalesce(json_extract(tool.value, '$.total_tokens'), 0) > 0
                      or coalesce(json_extract(tool.value, '$.input_tokens'), 0) > 0
                      or coalesce(json_extract(tool.value, '$.output_tokens'), 0) > 0
                      or coalesce(json_extract(tool.value, '$.input_tokens_details.image_tokens'), 0) > 0
                      or coalesce(json_extract(tool.value, '$.input_tokens_details.text_tokens'), 0) > 0
                      or coalesce(json_extract(tool.value, '$.output_tokens_details.image_tokens'), 0) > 0
                      or coalesce(json_extract(tool.value, '$.output_tokens_details.text_tokens'), 0) > 0
                      or coalesce(json_extract(tool.value, '$.num_requests'), 0) > 0
                 )
               then 1 else 0 end as speed_eligible,
          case
            when lower(coalesce(c.service_tier_served,'')) in ('fast','priority') then 'Fast'
            when lower(coalesce(c.service_tier_requested,'')) in ('fast','priority') then 'Fast'
            when lower(coalesce(c.mode,'')) like '%fast%' then 'Fast'
            when lower(coalesce(c.mode,'')) in ('default','standard') then 'Standard'
            else 'Other'
          end as lane,
          date(c.completed_at, 'localtime') as day_bucket,
          strftime('%Y-%m-%d %H:00', c.completed_at, 'localtime') as hour_bucket,
          strftime('%Y-%m-%d %H:', c.completed_at, 'localtime') ||
            printf('%02d', (cast(strftime('%M', c.completed_at, 'localtime') as integer) / 5) * 5) as five_min_bucket,
          ?
        from trusted_codex_turns c
        """,
        (updated_at,),
    )
    # This Codex version emits completions through OTLP rather than raw app logs.
    # Match each completion to its own response-stream span, using the parent
    # turn's thread identity and completion timestamp. Aggregate TBT metrics do
    # not identify individual responses and must not be assigned by proximity.
    conn.execute(
        """
        with completions as (
          select
            l.request_id,
            l.ordinal,
            l.conversation_id as thread_id,
            l.model,
            l.input_tokens,
            l.cached_tokens,
            l.output_tokens,
            l.reasoning_tokens,
            coalesce(l.input_tokens,0) + coalesce(l.output_tokens,0) as total_tokens,
            l.attrs_json,
            coalesce(json_extract(l.attrs_json, '$."event.timestamp"'), r.received_at) as completed_at,
            cast(json_extract(l.attrs_json, '$."ttft_ms"') as real) as ttft_ms,
            json_extract(l.attrs_json, '$."service_tier"') as service_tier,
            json_extract(l.attrs_json, '$."model_reasoning_effort"') as reasoning_effort,
            json_extract(l.attrs_json, '$."_otel.trace_id"') as log_trace_id
          from otel_log_events l
          join otlp_requests r on r.id = l.request_id
          join codex_thread_metadata m on m.thread_id = l.conversation_id
          join capture_state cutover on cutover.key = 'trusted_cutover_at'
          where l.event_name = 'codex.sse_event'
            and l.event_kind = 'response.completed'
            and l.conversation_id is not null
            and l.conversation_id != ''
            and coalesce(l.output_tokens,0) > 0
            and not exists (
              select 1 from app_response_events old
              where old.thread_id = l.conversation_id
                and old.output_tokens = l.output_tokens
                and abs((julianday(coalesce(json_extract(l.attrs_json, '$."event.timestamp"'), r.received_at))
                        - julianday(old.ts, 'unixepoch')) * 86400.0) <= 1.0
            )
            and coalesce(json_extract(l.attrs_json, '$."event.timestamp"'), r.received_at) >= cutover.value
            and not (
              coalesce(m.first_user_message,'') like 'Automation:%'
              or lower(coalesce(m.thread_source,'')) in ('automation', 'heartbeat')
              or coalesce(m.parent_thread_id,'') != ''
              or coalesce(m.agent_role,'') != ''
              or coalesce(m.agent_nickname,'') != ''
            )
        ),
        streams as (
          select
            stream.trace_id,
            stream.span_id,
            parent.thread_id,
            parent.turn_id,
            parent.model,
            cast(stream.start_unix_nano as integer) / 1000000000.0 as started_epoch,
            cast(stream.end_unix_nano as integer) / 1000000000.0 as completed_epoch,
            (cast(stream.end_unix_nano as integer) - cast(stream.start_unix_nano as integer)) / 1000000.0 as duration_ms
          from otel_trace_spans stream
          left join otel_trace_spans parent on parent.trace_id = stream.trace_id
            and parent.span_name = 'session_task.turn'
            and cast(stream.start_unix_nano as integer) >= cast(parent.start_unix_nano as integer)
            and cast(stream.end_unix_nano as integer) <= cast(parent.end_unix_nano as integer)
          where stream.span_name = 'responses_websocket.stream_request'
            and cast(stream.end_unix_nano as integer) > cast(stream.start_unix_nano as integer)
        ),
        candidates as (
          select
            c.*,
            s.trace_id,
            s.span_id,
            s.turn_id,
            s.started_epoch,
            s.duration_ms,
            count(s.span_id) over (partition by c.request_id, c.ordinal) as matching_streams,
            count(c.request_id) over (partition by s.trace_id, s.span_id) as matching_completions,
            row_number() over (
              partition by c.request_id, c.ordinal
              order by
                case when s.span_id is null then 1 else 0 end,
                abs(s.completed_epoch - (julianday(c.completed_at) - 2440587.5) * 86400.0)
            ) as rn
          from completions c
          left join streams s
            on (
                 (c.log_trace_id is not null and s.trace_id = c.log_trace_id
                  and (s.thread_id is null or s.thread_id = c.thread_id)
                  and (s.model is null or s.model = c.model))
                 or (c.log_trace_id is null and s.model = c.model and s.thread_id = c.thread_id)
               )
           and abs(s.completed_epoch - (julianday(c.completed_at) - 2440587.5) * 86400.0) <= 0.1
        )
        insert or replace into trusted_turn_cache(
          source, source_id, observed_at, surface, thread_id, turn_id, response_id,
          model, reasoning_effort, service_tier_requested, service_tier_served, mode,
          input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, total_tokens,
          started_at, completed_at, ttft_ms, duration_ms, output_tokens_per_second,
          non_reasoning_tokens_per_second, confidence, raw_json, speed_eligible, lane,
          day_bucket, hour_bucket, five_min_bucket, cache_updated_at
        )
        select
          'otel_response_stream',
          cast(request_id as text) || ':' || cast(ordinal as text),
          completed_at,
          'otel_authenticated_thread',
          thread_id,
          case when matching_streams = 1 and matching_completions = 1 then turn_id else null end,
          null,
          model,
          reasoning_effort,
          service_tier,
          service_tier,
          case
            when lower(coalesce(service_tier,'')) in ('fast','priority') then 'fast'
            when lower(coalesce(service_tier,'')) = 'auto' then 'auto'
            else 'default'
          end,
          input_tokens,
          cached_tokens,
          output_tokens,
          reasoning_tokens,
          total_tokens,
          case when matching_streams = 1 and matching_completions = 1 then strftime('%Y-%m-%dT%H:%M:%fZ', started_epoch, 'unixepoch') else null end,
          completed_at,
          ttft_ms,
          case when matching_streams = 1 and matching_completions = 1 then duration_ms else null end,
          case when matching_streams = 1 and matching_completions = 1 then output_tokens * 1000.0 / duration_ms else null end,
          case
            when matching_streams = 1 and matching_completions = 1
            then max(output_tokens - coalesce(reasoning_tokens,0), 0) * 1000.0 / duration_ms
            else null
          end,
          case when matching_streams = 1 and matching_completions = 1 then 'high' else 'medium' end,
          json_object(
            'event.name', 'codex.sse_event',
            'event.kind', 'response.completed',
            'timing_source', 'responses_websocket.stream_request',
            'trace_id', case when matching_streams = 1 and matching_completions = 1 then trace_id else null end,
            'span_id', case when matching_streams = 1 and matching_completions = 1 then span_id else null end,
            'matching_streams', matching_streams,
            'matching_completions', matching_completions,
            'correlation_source', case when log_trace_id is not null then 'log_trace_id' else 'parent_thread' end
          ),
          case when matching_streams = 1 and matching_completions = 1 and duration_ms >= 5000 and output_tokens >= 100 then 1 else 0 end,
          case
            when lower(coalesce(service_tier,'')) in ('fast','priority') then 'Fast'
            when lower(coalesce(service_tier,'')) in ('default','standard') then 'Standard'
            else 'Other'
          end,
          date(completed_at, 'localtime'),
          strftime('%Y-%m-%d %H:00', completed_at, 'localtime'),
          strftime('%Y-%m-%d %H:', completed_at, 'localtime') ||
            printf('%02d', (cast(strftime('%M', completed_at, 'localtime') as integer) / 5) * 5),
          ?
        from candidates
        where rn = 1
        """,
        (updated_at,),
    )
    set_state(conn, "trusted_turn_cache:rebuilt_at", updated_at)
    set_state(conn, "trusted_turn_cache:rebuilt_epoch", time.time())
    set_state(conn, "trusted_turn_cache:dirty", 0)
    return conn.execute("select count(*) from trusted_turn_cache").fetchone()[0]


def mark_trusted_cache_dirty(conn):
    set_state(conn, "trusted_turn_cache:dirty", 1)


def trusted_cache_should_rebuild(conn, min_interval=45):
    if conn.execute("select count(*) from trusted_turn_cache").fetchone()[0] == 0:
        return True
    if str(get_state(conn, "trusted_turn_cache:dirty", "0")) != "1":
        return False
    try:
        last = float(get_state(conn, "trusted_turn_cache:rebuilt_epoch", "0") or 0)
    except Exception:
        last = 0.0
    return time.time() - last >= min_interval


def parse_jsonl_timestamp(raw):
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except Exception:
        return None


def seconds_between(start_raw, end_raw):
    start = parse_jsonl_timestamp(start_raw)
    end = parse_jsonl_timestamp(end_raw)
    if not start or not end:
        return None
    return max((end - start).total_seconds(), 0)


def session_files(codex_home, limit=160):
    roots = [Path(codex_home) / "sessions", Path(codex_home) / "archived_sessions"]
    files = []
    for root in roots:
        if root.exists():
            files.extend(root.glob("**/*.jsonl"))
    files.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)
    return files[:limit]


def tool_family(name):
    n = (name or "").lower()
    if n in ("exec_command", "write_stdin") or "exec" in n or "terminal" in n:
        return "terminal"
    if "image" in n:
        return "image"
    if "browser" in n or "computer" in n or n in ("click", "type_text", "press_key", "scroll"):
        return "browser"
    return "tool"


def finalize_effective_turn(conn, path, mtime, turn):
    turn_id = turn.get("turn_id")
    if not turn_id:
        return False

    joined = conn.execute(
        """
        select service_tier_requested, service_tier_served, mode, model, reasoning_effort
        from turn_observations
        where turn_id=?
        order by observed_at desc
        limit 1
        """,
        (turn_id,),
    ).fetchone()
    if joined:
        turn["service_tier_requested"] = joined[0] or turn.get("service_tier_requested")
        turn["service_tier_served"] = joined[1] or turn.get("service_tier_served")
        turn["mode"] = joined[2] or turn.get("mode")
        turn["model"] = joined[3] or turn.get("model")
        turn["reasoning_effort"] = joined[4] or turn.get("reasoning_effort")

    token_events = int(turn.get("token_event_count") or 0)
    duration_ms = float(turn.get("duration_ms") or 0)
    output_tokens = int(turn.get("output_tokens") or 0)
    exact = token_events > 0 and duration_ms > 0 and output_tokens > 0
    token_source = "session_token_count" if token_events > 0 else "duration_only"
    confidence = "exact" if exact else "duration_only"
    effective_tps = (output_tokens * 1000.0 / duration_ms) if exact else None
    mode = turn.get("mode") or infer_mode(turn.get("service_tier_requested"), turn.get("service_tier_served"))
    if not mode:
        mode = "unknown"

    summary = {
        "tool_calls": turn.get("tool_call_count", 0),
        "terminal_calls": turn.get("terminal_call_count", 0),
        "browser_calls": turn.get("browser_call_count", 0),
        "image_calls": turn.get("image_call_count", 0),
        "token_events": token_events,
    }
    conn.execute(
        """
        insert or replace into effective_turns(
          source_path, source_mtime, turn_id, trace_id, observed_at, started_at, completed_at,
          duration_ms, time_to_first_token_ms, model, reasoning_effort, service_tier_requested,
          service_tier_served, mode, cwd, user_message, output_tokens, reasoning_tokens,
          input_tokens, cached_input_tokens, total_tokens, token_event_count, tool_call_count,
          terminal_call_count, browser_call_count, image_call_count, tool_wait_ms,
          effective_tokens_per_second, token_source, confidence, raw_summary_json
        ) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """,
        (
            str(path),
            int(mtime),
            turn_id,
            turn.get("trace_id"),
            now_iso(),
            turn.get("started_at"),
            turn.get("completed_at"),
            turn.get("duration_ms"),
            turn.get("time_to_first_token_ms"),
            turn.get("model"),
            turn.get("reasoning_effort"),
            turn.get("service_tier_requested"),
            turn.get("service_tier_served"),
            mode,
            turn.get("cwd"),
            turn.get("user_message"),
            turn.get("output_tokens"),
            turn.get("reasoning_tokens"),
            turn.get("input_tokens"),
            turn.get("cached_input_tokens"),
            turn.get("total_tokens"),
            token_events,
            turn.get("tool_call_count"),
            turn.get("terminal_call_count"),
            turn.get("browser_call_count"),
            turn.get("image_call_count"),
            turn.get("tool_wait_ms"),
            effective_tps,
            token_source,
            confidence,
            json.dumps(summary, separators=(",", ":")),
        ),
    )
    return True


def scan_effective_turns(conn, codex_home=CODEX_HOME, limit=160):
    changed = 0
    for path in session_files(codex_home, limit=limit):
        try:
            mtime = int(path.stat().st_mtime)
        except OSError:
            continue
        state_key = "effective_session_mtime:" + hashlib.sha256(str(path).encode()).hexdigest()
        if str(get_state(conn, state_key, "")) == str(mtime):
            continue

        current = None
        call_started = {}
        completed_paths = 0
        try:
            with path.open("r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    ts = obj.get("timestamp")
                    kind = obj.get("type")
                    payload = obj.get("payload") or {}

                    if kind == "turn_context":
                        current = {
                            "turn_id": payload.get("turn_id"),
                            "trace_id": payload.get("trace_id"),
                            "started_at": ts,
                            "completed_at": None,
                            "duration_ms": None,
                            "time_to_first_token_ms": None,
                            "model": payload.get("model"),
                            "reasoning_effort": payload.get("effort") or ((payload.get("collaboration_mode") or {}).get("settings") or {}).get("reasoning_effort"),
                            "service_tier_requested": ((payload.get("collaboration_mode") or {}).get("settings") or {}).get("service_tier"),
                            "service_tier_served": None,
                            "mode": None,
                            "cwd": payload.get("cwd"),
                            "user_message": None,
                            "output_tokens": 0,
                            "reasoning_tokens": 0,
                            "input_tokens": 0,
                            "cached_input_tokens": 0,
                            "total_tokens": 0,
                            "token_event_count": 0,
                            "tool_call_count": 0,
                            "terminal_call_count": 0,
                            "browser_call_count": 0,
                            "image_call_count": 0,
                            "tool_wait_ms": 0.0,
                        }
                        call_started = {}
                        continue

                    if current is None:
                        continue

                    if kind == "event_msg" and payload.get("type") == "user_message" and not current.get("user_message"):
                        current["user_message"] = payload.get("message")
                    elif kind == "event_msg" and payload.get("type") == "token_count":
                        usage = ((payload.get("info") or {}).get("last_token_usage") or {})
                        current["input_tokens"] += int_or_none(usage.get("input_tokens")) or 0
                        current["cached_input_tokens"] += int_or_none(usage.get("cached_input_tokens")) or 0
                        current["output_tokens"] += int_or_none(usage.get("output_tokens")) or 0
                        current["reasoning_tokens"] += int_or_none(usage.get("reasoning_output_tokens")) or 0
                        current["total_tokens"] += int_or_none(usage.get("total_tokens")) or 0
                        current["token_event_count"] += 1
                    elif kind == "response_item" and payload.get("type") == "function_call":
                        current["tool_call_count"] += 1
                        call_id = payload.get("call_id")
                        if call_id:
                            call_started[call_id] = ts
                        family = tool_family(payload.get("name"))
                        if family == "terminal":
                            current["terminal_call_count"] += 1
                        elif family == "browser":
                            current["browser_call_count"] += 1
                        elif family == "image":
                            current["image_call_count"] += 1
                    elif kind == "response_item" and payload.get("type") == "function_call_output":
                        started = call_started.get(payload.get("call_id"))
                        elapsed = seconds_between(started, ts) if started else None
                        if elapsed is not None:
                            current["tool_wait_ms"] += elapsed * 1000.0
                    elif kind == "event_msg" and payload.get("type") == "task_complete":
                        current["duration_ms"] = float_or_none(payload.get("duration_ms"))
                        current["time_to_first_token_ms"] = float_or_none(payload.get("time_to_first_token_ms"))
                        completed_at = payload.get("completed_at")
                        current["completed_at"] = iso_from_unix_seconds(completed_at) if completed_at else ts
                        if finalize_effective_turn(conn, path, mtime, current):
                            completed_paths += 1
                        current = None
            set_state(conn, state_key, mtime)
            changed += completed_paths
        except Exception as e:
            record_event(conn, "error", "effective_scan_error", {"path": str(path), "error": str(e)})
    return changed


def write_heartbeat(conn, source_key=None):
    cursor = int(get_state(conn, source_key, 0) or 0) if source_key else None
    counts = conn.execute(
        "select (select count(*) from otlp_requests), (select count(*) from app_response_events), (select count(*) from turn_observations), (select count(*) from codex_turns)"
    ).fetchone()
    ts = now_iso()
    uptime = (datetime.now(timezone.utc) - STARTED_AT).total_seconds()
    conn.execute(
        "insert into daemon_heartbeats(ts,pid,uptime_seconds,app_log_cursor,otlp_requests,app_response_events,turn_observations,best_turns) values(?,?,?,?,?,?,?,?)",
        (ts, os.getpid(), uptime, cursor, counts[0], counts[1], counts[2], counts[3]),
    )
    set_state(conn, "daemon:last_heartbeat", ts)
    set_state(conn, "daemon:pid", os.getpid())
    set_state(conn, "daemon:started_at", STARTED_AT.isoformat(timespec="microseconds"))


class CaptureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "CodexSpeedMonitorDaemon/1.0"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path in ("/", "/health"):
            with self.server.lock:
                conn = connect(self.server.db_path)
                row = conn.execute("select value, updated_at from capture_state where key='daemon:last_heartbeat'").fetchone()
                counts = conn.execute("select (select count(*) from otlp_requests), (select count(*) from app_response_events), (select count(*) from trusted_turn_cache)").fetchone()
                conn.close()
            self._json(200, {"ok": True, "time": now_iso(), "heartbeat": row[0] if row else None, "otlp_requests": counts[0], "app_response_events": counts[1], "turns": counts[2]})
        else:
            self._json(404, {"ok": False})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        text = None
        b64 = None
        json_valid = 0
        keys = None
        try:
            text = body.decode("utf-8")
            parsed = json.loads(text)
            json_valid = 1
            if isinstance(parsed, dict):
                keys = json.dumps(sorted(parsed.keys()))
        except Exception:
            b64 = base64.b64encode(body).decode("ascii")
        sha = hashlib.sha256(body).hexdigest()
        with self.server.lock:
            conn = connect(self.server.db_path)
            cur = conn.execute(
                "insert into otlp_requests(received_at,method,path,content_type,content_encoding,body_len,body_sha256,body_text,body_b64,json_valid,top_level_keys,remote_addr) values(?,?,?,?,?,?,?,?,?,?,?,?)",
                (now_iso(), self.command, self.path, self.headers.get("content-type"), self.headers.get("content-encoding"), len(body), sha, text, b64, json_valid, keys, self.client_address[0] if self.client_address else None),
            )
            request_id = cur.lastrowid
            if text and json_valid:
                parse_otlp(conn, request_id, self.path, text)
                mark_trusted_cache_dirty(conn)
                if refresh_turn_observations(conn):
                    mark_trusted_cache_dirty(conn)
            write_heartbeat(conn)
            conn.commit()
            conn.close()
        self._json(200, {"ok": True, "id": request_id, "bytes": len(body)})

    def _json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def poll_loop(db_path, log_db, state_db, interval, heartbeat_interval, verbose, stop_event):
    last_snapshot = 0.0
    last_heartbeat = 0.0
    source_key = f"logs_cursor:{Path(log_db)}"
    while not stop_event.is_set():
        try:
            conn = connect(db_path)
            imported = ingest_app_logs(conn, log_db)
            ingest_thread_metadata(conn, state_db)
            changed = refresh_turn_observations(conn)
            scan_effective_turns(conn)
            if changed:
                mark_trusted_cache_dirty(conn)
            if trusted_cache_should_rebuild(conn):
                rebuild_trusted_turn_cache(conn)
            now = time.time()
            if now - last_snapshot > 300:
                snapshot_config(conn)
                last_snapshot = now
            if now - last_heartbeat > heartbeat_interval:
                write_heartbeat(conn, source_key)
                last_heartbeat = now
            conn.commit()
            conn.close()
            if verbose and imported:
                print(json.dumps({"event": "app_logs_imported", "count": imported, "time": now_iso()}), flush=True)
        except Exception as e:
            try:
                conn = connect(db_path)
                record_event(conn, "error", "poll_error", {"error": str(e)})
                conn.commit()
                conn.close()
            except Exception:
                pass
            print(json.dumps({"event": "poll_error", "error": str(e), "time": now_iso()}), flush=True)
        stop_event.wait(interval)


def main():
    ap = argparse.ArgumentParser(description="Permanent local Codex telemetry capture daemon.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4318)
    ap.add_argument("--db", default=str(DEFAULT_DB))
    ap.add_argument("--log-db", default=str(DEFAULT_LOG_DB))
    ap.add_argument("--state-db", default=str(DEFAULT_STATE_DB))
    ap.add_argument("--interval", type=float, default=15.0)
    ap.add_argument("--heartbeat-interval", type=float, default=30.0)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    db_path = Path(args.db)
    conn = connect(db_path)
    record_event(conn, "info", "daemon_start", {"pid": os.getpid(), "db": str(db_path), "log_db": str(args.log_db), "state_db": str(args.state_db), "port": args.port})
    snapshot_config(conn)
    ingest_thread_metadata(conn, args.state_db)
    refresh_turn_observations(conn)
    scan_effective_turns(conn)
    write_heartbeat(conn, f"logs_cursor:{Path(args.log_db)}")
    conn.commit()
    conn.close()
    stop = threading.Event()
    thread = threading.Thread(target=poll_loop, args=(db_path, args.log_db, args.state_db, args.interval, args.heartbeat_interval, args.verbose, stop), daemon=True)
    thread.start()
    server = CaptureServer((args.host, args.port), Handler)
    server.db_path = db_path
    server.lock = threading.Lock()
    print(json.dumps({"event": "listening", "host": args.host, "port": args.port, "db": str(db_path), "log_db": str(args.log_db), "state_db": str(args.state_db), "time": now_iso()}), flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()
        conn = connect(db_path)
        record_event(conn, "info", "daemon_stop", {"pid": os.getpid()})
        conn.commit()
        conn.close()


if __name__ == "__main__":
    main()
