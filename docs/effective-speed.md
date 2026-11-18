# Effective Speed

Effective Speed is a second, separate measurement alongside the existing model-speed metric.

The current Token Speed number measures model output speed only. It intentionally excludes time spent running terminal commands, browser automation, image generation, local scripts, and other tool work. That is the right metric for comparing model streaming speed.

Effective Speed answers a different question: how fast did Codex feel for the user end-to-end?

## Definitions

### Model Speed

Model Speed remains the primary trusted metric.

```text
model_speed_tps = output_tokens / model_response_duration_seconds
```

Use this for Fast vs Standard model-performance comparisons.

### Effective Speed

Effective Speed includes the whole Codex turn duration, including model calls, local tools, terminal commands, scripts, browser waits, and post-tool synthesis.

```text
effective_speed_tps = sum(model_output_tokens_for_turn) / task_complete_duration_seconds
```

The numerator is still token-based and exact when token usage exists. The denominator is the user's end-to-end wait for the turn.

### Effective Multiple

```text
effective_fast_multiple = fast_effective_speed_tps / standard_effective_speed_tps
```

This should be shown separately from the model-speed multiple because it measures workflow experience, not raw model streaming speed.

## Raw Sources

The importer should read raw Codex session JSONL files from:

```text
$CODEX_HOME/sessions/**/*.jsonl
$CODEX_HOME/archived_sessions/**/*.jsonl
```

Useful event types:

- `turn_context`: model, reasoning effort, turn id, trace id, cwd, current date, mode context when available.
- `event_msg` with `type=user_message`: user-visible start marker.
- `event_msg` with `type=token_count`: exact per-model-call token usage via `last_token_usage`.
- `response_item` with `type=function_call`: tool call name and arguments.
- `response_item` with `type=function_call_output`: tool completion marker and output metadata.
- `event_msg` with `type=task_complete`: final turn id, `duration_ms`, `time_to_first_token_ms`, and completion timestamp.

Important: tool-using turns may contain multiple `token_count` events. The importer must sum every `last_token_usage` inside a turn, not just use the final event.

## Proposed Tables

### `effective_turns`

One row per raw Codex turn.

```sql
create table if not exists effective_turns (
  source_path text not null,
  source_mtime integer not null,
  source_offset integer,
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
```

### `effective_turn_tool_calls`

Optional detail table for report exports and validation.

```sql
create table if not exists effective_turn_tool_calls (
  source_path text not null,
  turn_id text not null,
  ordinal integer not null,
  call_id text,
  tool_name text,
  started_at text,
  completed_at text,
  duration_ms real,
  output_token_count integer,
  primary key (source_path, turn_id, ordinal)
);
```

## Confidence Rules

Use confidence explicitly. Do not silently mix exact and estimated rows.

- `exact`: turn has `task_complete.duration_ms` and at least one exact token source.
- `exact_session_tokens`: token source is summed `token_count.last_token_usage` events from raw JSONL.
- `exact_app_response_join`: token source is joined app-response usage by `turn_id`; use only if all model calls for the turn can be matched.
- `duration_only`: duration exists but tokens are missing; include in counts and latency charts, exclude from t/s averages.
- `estimated`: output text was tokenized or approximated locally; do not include in default t/s metrics.

Default UI and exports should use `exact` rows only for Effective Speed.

## Importer Rules

1. Scan session files incrementally by path and mtime.
2. Start a row at `turn_context`.
3. Sum all `token_count.info.last_token_usage` events until `task_complete`.
4. Count tool calls and classify tool families.
5. Compute `effective_tokens_per_second` only if `duration_ms > 0` and exact output tokens exist.
6. Write `duration_only` rows when duration exists but exact tokens are missing.
7. Never overwrite Model Speed with Effective Speed.
8. Mark image-generation turns with `image_call_count > 0`; they can be visible in Effective Speed but excluded from default model-speed charts.
9. Terminal/script time is included in Effective Speed by design.
10. Subagents and automations should be retained in raw effective tables but filtered out of the default personal UI unless the user enables an expanded scope.

## UI Placement

Keep the main widget clean.

Recommended app structure:

- Top summary: existing `Model speed` as the primary number.
- Fast vs Standard card: show the model-speed multiple.
- Add a compact secondary row: `End-to-end 18.4 t/s` with `Fast 0.92x` when both modes exist.
- Report window: add a segmented control or tab group with `Model Speed` and `End-to-end`.
- End-to-end tab: show Effective Speed by mode, model, reasoning level, and tool-heavy vs no-tool turns.

Avoid showing Effective Speed as a replacement for Token Speed. Label it as `End-to-end` or `Effective speed` everywhere.

## Validation Plan

Use controlled Codex turns and verify raw session evidence before trusting the importer.

Required fixtures:

1. No-tool turn: a plain response with no function calls.
2. Terminal turn: run `sleep 4` and confirm Effective Speed drops while Model Speed stays normal.
3. Long script turn: run a longer local command and confirm the denominator includes script runtime.
4. Multi-tool turn: multiple terminal calls; confirm all token-count events are summed.
5. Image generation turn: confirm it is marked as image/tool-heavy and does not contaminate Model Speed.
6. Subagent turn: confirm raw capture works but default personal UI can filter it out.
7. Missing-token turn: confirm it is stored as `duration_only` and excluded from t/s averages.

For each fixture, compare:

- Raw JSONL `task_complete.duration_ms`.
- Summed `token_count.last_token_usage.output_tokens`.
- Imported `effective_tokens_per_second`.
- Existing model-speed table, when a matching app response exists.

## Current Evidence

A controlled subagent test with a 4-second terminal sleep produced raw JSONL evidence with:

- `turn_context` containing model and reasoning effort.
- Two `token_count` events, one before and one after the tool call.
- `function_call` and `function_call_output` around the terminal command.
- `task_complete.duration_ms` for the whole turn.

This validates the intended capture path and confirms that tool time can be measured separately from model-response duration.
