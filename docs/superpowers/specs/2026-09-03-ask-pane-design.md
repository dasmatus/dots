# dots-ask: an AI side pane for the Quickshell tree

Goal (2026-09-03): replace Claude Desktop with a pane inside the shell,
backed by a Rust daemon that speaks to several AI backends through one
event schema. This document records the protocol the `claude` CLI actually
speaks, freezes the wire schema every later phase codes against, and states
the permission rules the daemon enforces.

## What this builds on

- `rust/ask-daemon` ships the binary `dots-ask` as a systemd user service.
  It cannot live inside Quickshell: `nix/home/quickshell/default.nix` puts
  the QML tree on `X-Restart-Triggers`, so every rebuild restarts the shell
  and would kill an in-flight turn.
- Transport is newline-delimited JSON on
  `$XDG_RUNTIME_DIR/dots-ask.sock`, one JSON object per line, the same
  framing rule `rust/settings-global/src/rpc.rs` states in its module
  header. The QML side reads it with `Quickshell.Io`'s `Socket` plus
  `SplitParser`. Quickshell has no generic D-Bus client, so the beamenu
  transport in `docs/superpowers/specs/2026-08-23-beamenu-actions-daemon-design.md`
  is not available here.
- The pane is gated on the existing `dots.ai.{claude,codex,ollama}` options
  (`nix/modules/dots.nix:60-87`). A backend appears only when its toggle is
  on. No new settings key.

## 1. Observed claude stream-json protocol

Version observed: **claude 2.1.228**, from
`/nix/store/lki5n7ad8gxq409kq3dvkpy60q9rkjqi-claude-code-2.1.228`.
`claude --version` prints `2.1.228 (Claude Code)`.

This interface is undocumented. It is not in `claude --help`, it carries no
compatibility promise, and one of the two flags the daemon depends on is
hidden. The fixture at `rust/ask-daemon/tests/fixtures/claude-stream.jsonl`
exists so a replay test fails loudly after a `claude` upgrade instead of the
pane going quiet.

### How the fixture was recorded

A driver process spawned the CLI with a pipe on stdin and stdout, kept
stdin open for the whole session, and appended every stdout line verbatim:

```
claude -p \
  --input-format stream-json --output-format stream-json \
  --include-partial-messages --permission-mode manual \
  --session-id <uuid> --add-dir <scratch dir> --verbose \
  --permission-prompt-tool stdio
```

Two flags need explaining.

`--permission-prompt-tool stdio` does not appear in `claude --help` and is
required. The first spike ran without it. The CLI never sent a permission
request; it printed
`{"type":"system","subtype":"permission_denied","tool_name":"Write",...}`
and handed the model an error `tool_result` reading "Claude requested
permissions to write to ..., but you haven't granted it yet". A daemon that
omits this flag gets a session where every gated tool silently fails.

`--permission-mode manual` normalizes to `default` inside the bundle
(`function Z$(e){return e==="manual"?"default":e}`). The fixture proves it
rather than merely agreeing with it: all three `system/init` lines report
`"permissionMode":"default"` although the CLI was launched with `manual`,
and `Write` was gated rather than pre-approved.

The recorded session runs three user turns against a scratch directory: the
first `Write` is denied, the second is allowed, the third is cancelled by an
`interrupt` while its permission request is still open. That covers all
three outcomes the pane has to handle in one file.

One limit of the fixture is worth stating up front, because it changes how
much weight the next sections carry. The driver recorded the CLI's stdout
only. Its own stdin frames were never captured, so every client-to-CLI
payload printed below is reconstructed from the driver source rather than
transcribed from a capture. The fixture corroborates them indirectly: the
deny `message` the driver sent comes back verbatim in the `tool_result` at
fixture line 38, and `b.txt`, which only exists because the allow reply was
accepted, appears at fixture line 81. A later phase that wants a byte-exact
record of the client direction has to record both pipes.

### Handshake

The client speaks first. It sends an `initialize` control request, and the
CLI answers with the session's capabilities:

```json
{"type":"control_request","request_id":"req_0_init",
 "request":{"subtype":"initialize","hooks":{}}}
```

```json
{"type":"control_response","response":{"subtype":"success",
 "request_id":"req_0_init",
 "response":{"commands":[...],"agents":[...],"output_style":"normal",
             "available_output_styles":["normal"],"models":[],
             "account":{},"pid":1234}}}
```

The bundle adds `pending_permission_requests` and
`pending_user_dialog_requests` to that response when requests were already
queued before the client attached. Neither appeared in the fixture, because
the driver attached before the first turn.

### The control envelope

Three top-level types carry control traffic, and they are not symmetric.

| Frame | Where `request_id` lives | Direction |
|---|---|---|
| `control_request` | top level, next to `type` | both ways |
| `control_response` | nested, `response.request_id` | both ways |
| `control_cancel_request` | top level | CLI to client |

Correlation is by `request_id` alone. Client-minted ids are free-form
strings (`req_0_init` was accepted). CLI-minted ids are UUIDs. A response
must echo the id it answers inside the `response` object, not at the top
level, and the top level carries only `type`.

Subtypes the CLI accepts from the client, read off the bundle's accept set:
`interrupt`, `set_permission_mode`, `set_model`, `set_max_thinking_tokens`,
`set_color`, `mcp_toggle`, `message_rated`. Only `interrupt` and
`initialize` were exercised. Subtypes the CLI sends to the client:
`can_use_tool`, `request_user_dialog`, `elicitation`. Only `can_use_tool`
was exercised.

### can_use_tool

The fixture holds three of these, one per turn, at lines 37, 80 and 126.
This is the one the session allowed, fixture line 80:

```json
{"type":"control_request","request_id":"29951f7f-70f1-4de6-be15-3d6939d2a806",
 "request":{"subtype":"can_use_tool","tool_name":"Write",
   "display_name":"Write",
   "input":{"file_path":"/tmp/.../b.txt","content":"beta\n"},
   "description":"b.txt",
   "permission_suggestions":[{"type":"setMode","mode":"acceptEdits",
                              "destination":"session"}],
   "tool_use_id":"toolu_01TQ6VDPu86gfwQs5NKnh6fa"}}
```

Fields seen in the fixture: `tool_name`, `display_name`, `input`,
`description`, `permission_suggestions`, `tool_use_id`. The bundle reads
five more off the same object that this session never produced:
`blocked_path`, `decision_reason`, `title`, `agent_id`, `matched_ask_rule`.
Treat all of them as optional.

The allow reply that answered it, accepted on the first attempt:

```json
{"type":"control_response","response":{"subtype":"success",
 "request_id":"29951f7f-70f1-4de6-be15-3d6939d2a806",
 "response":{"behavior":"allow",
             "updatedInput":{"file_path":"/tmp/.../b.txt","content":"beta\n"}}}}
```

`updatedInput` replaces the tool arguments. The bundle resolves it as
`("updatedInput" in e ? e.updatedInput : void 0) ?? original`, so omitting
the field keeps the original input. Passing it back unchanged, as the driver
did, is safe.

The deny reply, also accepted on the first attempt, answered a different
request: the first turn's `a.txt` write at fixture line 37.

```json
{"type":"control_response","response":{"subtype":"success",
 "request_id":"a8f8ddef-85af-4455-99e8-5e4990fc17d6",
 "response":{"behavior":"deny",
   "message":"denied by the spike driver","interrupt":false}}}
```

Denial is still a `success` control response. `behavior` carries the
verdict. The CLI turns it into a normal error `tool_result` whose content is
the `message` verbatim, and tags it (fixture line 38):

```json
{"type":"user","message":{"role":"user","content":[
   {"type":"tool_result","content":"denied by the spike driver",
    "is_error":true,"tool_use_id":"toolu_0147PnvrgYvQkbYPA9HjHzod"}]},
 "tool_use_result":"Error: denied by the spike driver",
 "tool_result_meta":[{"id":"toolu_0147PnvrgYvQkbYPA9HjHzod",
                      "non_execution_kind":"permission-rule"}]}
```

### The tool_result shapes a decoder has to accept

Three of the fixture's four `user` lines carry a `tool_result`, one per
outcome, and no two of them share a field set. A decoder that keys off
`is_error` alone gets the allowed case wrong. The fourth `user` line is not
a tool result at all; it appears in the cancellation section below.

Allowed, fixture line 81. There is **no `is_error` key at all**, and
`tool_use_result` is an object, not a string. `tool_result_meta` is absent.

```json
{"type":"user","message":{"role":"user","content":[
   {"tool_use_id":"toolu_01TQ6VDPu86gfwQs5NKnh6fa","type":"tool_result",
    "content":"File created successfully at: /tmp/.../b.txt ..."}]},
 "tool_use_result":{"type":"create","filePath":"/tmp/.../b.txt",
   "content":"beta\n","structuredPatch":[],"originalFile":null,
   "userModified":false}}
```

Denied, fixture line 38. `is_error` is `true`, `tool_use_result` is a
string, and `tool_result_meta[0].non_execution_kind` reads
`"permission-rule"`.

Cancelled, fixture line 129. `is_error` is `true`, `tool_use_result` is the
string `"User rejected tool use"`, the `content` is the CLI's own canned
rejection text rather than anything the client wrote, and
`non_execution_kind` reads `"user-rejected"`.

Two rules follow, and both belong in `src/backend/claude_code.rs`.

**A missing `is_error` means success.** Default it to `false`. Only the two
non-execution paths set it, and only ever to `true`.

**`tool_use_result` is polymorphic.** Decode it as an untyped JSON value,
never as a string. It is a string on the two non-execution paths and a
tool-specific object on the success path, where `Write` returns
`{type, filePath, content, structuredPatch, originalFile, userModified}`.
That object is where a real diff would come from if `structuredPatch` were
non-empty, which it is not for a file that did not exist before.

### Cancelling an open permission request

Sending `{"subtype":"interrupt"}` while a `can_use_tool` is unanswered makes
the CLI withdraw it:

```json
{"type":"control_cancel_request","request_id":"9dc45437-01a3-4d31-b99e-9957760c4e01"}
{"type":"control_response","response":{"subtype":"success",
 "request_id":"req_1_interrupt","response":{"still_queued":[]}}}
```

The client must drop the withdrawn prompt and must not answer it. The CLI
then emits two `user` lines back to back, not one. Line 129 is the canned
rejection `tool_result`. Line 130 is a plain text notice with no
`tool_use_id`, no `tool_result` block and no `tool_use_result` key at all:

```json
{"type":"user","message":{"role":"user","content":[
   {"type":"text","text":"[Request interrupted by user for tool use]"}]},
 "parent_tool_use_id":null,"session_id":"31c9311e-...",
 "uuid":"fc3e5951-...","timestamp":"2026-09-03T05:17:59.462Z"}
```

The turn then ends with `subtype: "error_during_execution"` and
`terminal_reason: "aborted_tools"`.

### Every type in the fixture

131 lines and 18 distinct shapes. The table adds `system/permission_denied`
from the run without the hidden flag, which is why one count reads zero.
Examples are trimmed where a field is long.

| Type / subtype | Count | What it is |
|---|---|---|
| `system/init` | 3 | one per user turn, carries `cwd`, `session_id`, `tools`, `model`, `permissionMode`, `mcp_servers`, `apiKeySource`, `claude_code_version` |
| `system/hook_started` | 4 | startup only, one per `SessionStart` hook |
| `system/hook_response` | 4 | the hook's stdout, stderr and exit code |
| `system/status` | 7 | `"status":"requesting"` before each API call |
| `system/thinking_tokens` | 11 | running estimate, `estimated_tokens` and `estimated_tokens_delta` |
| `system/permission_denied` | 0 here | seen only in the run without `--permission-prompt-tool` |
| `control_response` | 2 | the `initialize` reply and the `interrupt` reply |
| `control_request/can_use_tool` | 3 | permission prompts |
| `control_cancel_request` | 1 | withdrawal after `interrupt` |
| `stream_event/message_start` | 7 | opens an assistant message; `ttft_ms` rides at the top level, beside `session_id` and `uuid`, not inside `event` |
| `stream_event/content_block_start` | 10 | `text`, `thinking` or `tool_use` block opens |
| `stream_event/content_block_delta` | 37 | `text_delta`, `thinking_delta`, `signature_delta`, `input_json_delta` |
| `stream_event/content_block_stop` | 10 | block closes |
| `stream_event/message_delta` | 7 | `stop_reason` plus cumulative `usage` |
| `stream_event/message_stop` | 7 | message closes |
| `assistant` | 10 | the settled form of one content block |
| `user` | 4 | two shapes. Lines 38, 81 and 129 carry a `tool_result` block; line 130 carries a plain `text` block, the interrupt notice |
| `rate_limit_event` | 1 | `status`, `rateLimitType`, `resetsAt`, overage state |
| `result` | 3 | end of a user turn |

Representative lines:

```json
{"type":"system","subtype":"init","cwd":"/tmp/.../spike",
 "session_id":"31c9311e-...","tools":["Task","Bash",...],
 "model":"claude-opus-5","permissionMode":"default","apiKeySource":"none",
 "claude_code_version":"2.1.228","output_style":"default"}

{"type":"stream_event","event":{"type":"message_start","message":{
   "model":"claude-opus-5","id":"msg_011Cefw...","role":"assistant",
   "content":[],"stop_reason":null,"usage":{...}}},
 "session_id":"31c9311e-...","parent_tool_use_id":null,
 "uuid":"95689f51-...","ttft_ms":1454}

{"type":"stream_event","event":{"type":"content_block_delta","index":0,
 "delta":{"type":"text_delta","text":"The"}},
 "session_id":"31c9311e-...","parent_tool_use_id":null,"uuid":"4cba19bf-..."}

{"type":"stream_event","event":{"type":"content_block_start","index":1,
 "content_block":{"type":"tool_use","id":"toolu_0147...","name":"Write",
                  "input":{},"caller":{"type":"direct"}}}}

{"type":"assistant","message":{"model":"claude-opus-5","id":"msg_011Cefw...",
 "role":"assistant","content":[{"type":"tool_use","id":"toolu_0147...",
 "name":"Write","input":{"file_path":"/tmp/.../a.txt","content":"alpha\n"}}]}}

{"type":"rate_limit_event","rate_limit_info":{"status":"allowed",
 "resetsAt":1788428400,"rateLimitType":"five_hour",
 "overageStatus":"rejected","isUsingOverage":false}}

{"type":"result","subtype":"success","is_error":false,"num_turns":2,
 "stop_reason":"end_turn","duration_ms":15673,"duration_api_ms":15505,
 "ttft_ms":7256,"total_cost_usd":0.186745,"terminal_reason":"completed",
 "result":"...","usage":{...},"session_id":"31c9311e-..."}

{"type":"result","subtype":"error_during_execution","is_error":true,
 "num_turns":3,"stop_reason":"tool_use","duration_ms":2508,
 "duration_api_ms":27716,"total_cost_usd":0.279339,
 "terminal_reason":"aborted_tools","usage":{...},
 "errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"],
 "session_id":"31c9311e-..."}
```

The two `result` shapes differ by more than `subtype`. The interrupted one
has no `ttft_ms` and no `result` text, and it adds `errors`. Treat
`ttft_ms`, `result` and `errors` as optional on every `result` line.

Three behaviours the parser has to know about, all confirmed against the
fixture rather than assumed.

**One content block per `assistant` line.** Ten `assistant` lines carry
exactly one block each, across seven messages. Three `message.id` values
appear twice, once per block the message held: two of those pairs are
thinking plus text, the third is thinking plus a tool call. The rule is one
line per block regardless of what the blocks are, and the line is not a
cumulative snapshot of the message.

**Harness thinking text is empty.** All 12 `thinking_delta` events carry
`"thinking":""`, total length zero, and the settled `assistant` thinking
block carries an empty string next to a long `signature`. The only real
signal is `estimated_tokens`. The pane can show that a model is thinking and
roughly how much, and nothing more.

**`result` is the turn boundary, not the session boundary.** Each of the
three user turns produced its own `result` line, and the process stayed
alive on the same `session_id`. The daemon closes a turn on `result` and
keeps the child running.

## 2. Normalized event schema

Protocol version 1. One JSON object per line in both directions, UTF-8, no
trailing whitespace, no multi-line objects. The daemon rejects a client line
it cannot parse with an `error` event rather than closing the connection.

### Client to daemon

Every frame carries `op`. Unknown ops draw an `error` event and are ignored.

```json
{"op":"hello","protocol":1,"resume_seq":4210}
```
`resume_seq` is the highest `seq` the client already rendered, or `null` on
a cold start. The daemon replays every persisted event above it in order,
then sends `ready`. This is what makes a Quickshell restart cheap, and it is
the **only** automatic replay the daemon performs.

```json
{"op":"list","limit":50,"before":null}
```
Ask for conversation metadata. `before` is a `updated_ms` cursor for paging.
Answered with a `conversations` event.

```json
{"op":"open","conversation":"6f1a...","from_seq":null}
```
Subscribe to one conversation. `open` never re-sends anything the client
already holds: the client passes the highest `seq` it has for that
conversation and the daemon sends strictly greater ones. `from_seq: null`
means the client holds nothing and wants the whole thread. A client that
reconnects with `hello` and then opens a conversation therefore receives
each event once, which is what makes the gap-free claim below true rather
than aspirational.

```json
{"op":"new","conversation":"6f1a...","backend":"claude-code",
 "model":"opus","cwd":"/home/matus/Dokumente/codeberg/personal/dots",
 "title":null}
```
The client mints the conversation id so it can address the thread before the
daemon has answered. `backend` must be one of the ids the last `backends`
event listed. `cwd` is the working directory the harness gets through
`--add-dir` and the directory a provider-mode MCP server starts in.
Answered with a `conversations` event that includes the new thread, or with
an `error` carrying `kind: "protocol"` when `backend` names an id the
daemon does not have. The backend process does not start until the first
`send`, so a spawn failure arrives then, as `kind: "backend_spawn"`.

```json
{"op":"send","conversation":"6f1a...","blocks":[
  {"kind":"text","text":"explain this crate"},
  {"kind":"image","mime":"image/png","path":"/run/user/1000/dots-ask/cap-3.png"},
  {"kind":"file","mime":"text/x-rust","path":"/home/matus/.../rpc.rs"}]}
```
Attachments travel as paths, never inline base64. The daemon reads them and
deletes anything it created under its own runtime directory when the
conversation closes.

```json
{"op":"interrupt","conversation":"6f1a..."}
```
Stop the running turn. In harness mode this becomes the `interrupt` control
request; any open permission prompt is withdrawn by the CLI.

```json
{"op":"permission","conversation":"6f1a...","request":"29951f7f-...",
 "decision":"allow","scope":"once","updated_input":null,"message":null}
```
`decision` is `allow` or `deny`. `scope` is `once`, `session` or `forever`;
`forever` is the only one `policy.rs` writes to disk. `updated_input`
overrides the tool arguments when the user edited them, and `message` is the
reason text sent back on a denial.

```json
{"op":"delete","conversation":"6f1a..."}
```
Remove the thread and its stored events. Answered with a fresh
`conversations` event.

### Daemon to client

Every event carries `event`, `seq` and `conversation`. The events split into
two groups, and that split is what makes the gap-free claim below true.

**Persisted conversation events**: `turn_start`, `text_delta`,
`thinking_delta`, `code_block`, `tool_call`, `tool_result`,
`permission_request`, `diff`, `plan`, `usage`, `turn_end`, `error`. Each
takes the next value of one monotonic `u64` that spans the whole daemon,
assigned at emit time and written to the store next to the event. That
counter has no holes, so replay from `resume_seq` is exact and gap-free.

**Ephemeral per-connection replies**: `ready`, `conversations`, `backends`.
They answer one client's question, they are never stored, and they carry
`seq: null` and `conversation: null`. A resuming client therefore never
replays another client's handshake, and the persisted `seq` space stays
dense.

`turn` names the turn an event belongs to. It is present on `turn_start`,
`text_delta`, `thinking_delta`, `code_block`, `tool_call`, `plan`, `usage`
and `turn_end`. It is absent on `tool_result`, `permission_request` and
`diff`, which correlate through `call` instead, and on `error`, which can
arrive with no turn running.

```json
{"seq":null,"conversation":null,"event":"ready","protocol":1,"seq_head":4211}

{"seq":4212,"conversation":"6f1a...","event":"turn_start",
 "turn":"c3d0...","backend":"claude-code","model":"claude-opus-5",
 "started_ms":1788425059000}

{"seq":4213,"conversation":"6f1a...","event":"text_delta",
 "turn":"c3d0...","block":0,"text":"The"}

{"seq":4214,"conversation":"6f1a...","event":"thinking_delta",
 "turn":"c3d0...","block":0,"text":"","tokens":50}

{"seq":4230,"conversation":"6f1a...","event":"code_block",
 "turn":"c3d0...","block":1,"language":"rust",
 "source":"fn main() {}\n","html":"<pre class=\"code\">...</pre>"}

{"seq":4231,"conversation":"6f1a...","event":"tool_call",
 "turn":"c3d0...","call":"toolu_0147...","name":"Write","display_name":"Write",
 "summary":"a.txt","input":{"file_path":"/tmp/a.txt","content":"alpha\n"},
 "origin":"harness"}

{"seq":4232,"conversation":"6f1a...","event":"tool_result",
 "call":"toolu_0147...","ok":false,"content":"denied by the spike driver",
 "truncated":false}

{"seq":4233,"conversation":"6f1a...","event":"permission_request",
 "request":"a8f8ddef-...","call":"toolu_0147...","name":"Write",
 "display_name":"Write","description":"a.txt",
 "input":{"file_path":"/tmp/a.txt","content":"alpha\n"},
 "suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],
 "withdrawn":false}

{"seq":4234,"conversation":"6f1a...","event":"diff",
 "call":"toolu_01TQ6...","path":"/tmp/b.txt","old_text":"","new_text":"beta\n",
 "added":1,"removed":0,"html":"<table class=\"diff\">...</table>"}

{"seq":4235,"conversation":"6f1a...","event":"plan",
 "turn":"c3d0...","title":"Rewrite the parser","markdown":"1. ...",
 "state":"proposed"}

{"seq":4236,"conversation":"6f1a...","event":"usage","turn":"c3d0...",
 "input_tokens":6,"output_tokens":811,"cache_read_tokens":83100,
 "cache_write_tokens":12489,"thinking_tokens":576,"cost_usd":0.186745,
 "rate_limit":{"type":"five_hour","status":"allowed","resets_at":1788428400}}

{"seq":4237,"conversation":"6f1a...","event":"turn_end","turn":"c3d0...",
 "stop":"end_turn","text":"Created a.txt.","duration_ms":15673}

{"seq":4238,"conversation":"6f1a...","event":"error","kind":"protocol",
 "message":"unparseable control_request from claude 2.1.229","fatal":false}

{"seq":null,"conversation":null,"event":"conversations","items":[
  {"id":"6f1a...","title":"explain this crate","backend":"claude-code",
   "model":"claude-opus-5","cwd":"/home/matus/...","updated_ms":1788425090000,
   "turns":3}]}

{"seq":null,"conversation":null,"event":"backends","items":[
  {"id":"claude-code","label":"Claude Code","state":"ready",
   "models":["opus","sonnet","haiku"],"detail":null},
  {"id":"ollama","label":"Ollama","state":"unreachable",
   "models":[],"detail":"connect 127.0.0.1:11434: refused"}]}
```

Field notes.

`stop` on `turn_end` is one of `end_turn`, `tool_use`, `interrupted`,
`max_tokens`, `error`. `interrupted` is what an `op:"interrupt"` produces,
including the `aborted_tools` case above.

`kind` on `error` is one of `backend_spawn`, `protocol`, `auth`,
`rate_limit`, `cancelled`, `store`. `fatal` true means the conversation is
dead and the client should offer a new one.

`state` on a backend entry is `ready`, `unconfigured` or `unreachable`.
`unconfigured` covers a toggle that is on but has no credential;
`unreachable` covers a service that refused a connection.

`html` on `code_block` and `diff` is pre-rendered by `render.rs` so the pane
does no highlighting work on the UI thread. Quickshell cannot host
QtWebEngine, so this is a small rich-text subset that a QML `Text` element
renders, not a web page. Anything richer than that subset, meaning a real
HTML artifact, is out of scope here and has no event in this schema. Phase 5
owns it and will add both the event and the module that serves it.

Both `code_block` and `diff` are in the schema from the start even though
nothing emits them until phase 3. Adding a variant later would force phase 1
files back under review after phases 2 and 3 already coded against them.

`permission_request` carries `withdrawn`, and the daemon re-emits the event
with `withdrawn: true` when the backend cancels it. The pane must dismiss
the prompt on that and must not send a decision.

The daemon does not batch deltas.
`nix/home/quickshell/qml/services/AskBus.qml` coalesces them on a 16ms
timer, which keeps batching policy on the side that knows the frame rate.

### Field types

Example values do not say what is optional, and `src/proto.rs` has to. Rust
types below; `Option<T>` is `null` on the wire, and a field not listed is
required and non-null.

| Frame and field | Type |
|---|---|
| any client frame `op` | `String`, tagged enum discriminant |
| `hello.protocol` | `u32` |
| `hello.resume_seq` | `Option<u64>` |
| `list.limit` | `u32`, default 50 |
| `list.before` | `Option<u64>` |
| `open.from_seq` | `Option<u64>` |
| `new.conversation` | `Uuid` |
| `new.backend` | `String` |
| `new.model` | `Option<String>`, null means the backend's default |
| `new.cwd` | `PathBuf` |
| `new.title` | `Option<String>` |
| `send.blocks[].kind` | `String`, one of `text`, `image`, `file` |
| `send.blocks[].text` | `Option<String>`, required when `kind` is `text` |
| `send.blocks[].path` | `Option<PathBuf>`, required otherwise |
| `send.blocks[].mime` | `Option<String>` |
| `permission.request` | `String`, the backend's own request id |
| `permission.decision` | `String`, `allow` or `deny` |
| `permission.scope` | `String`, `once`, `session` or `forever` |
| `permission.updated_input` | `Option<serde_json::Value>` |
| `permission.message` | `Option<String>` |
| any daemon event `seq` | `Option<u64>`, null on the three ephemeral events |
| any daemon event `conversation` | `Option<Uuid>`, null on the same three |
| any daemon event `turn` | `Option<Uuid>`, absent per the rule above |
| `turn_start.model` | `Option<String>`, null until the backend names one |
| `turn_start.backend` | `String` |
| `turn_start.started_ms` | `u64` |
| `text_delta.block` | `u32` |
| `text_delta.text` | `String` |
| `thinking_delta.text` | `String`, empty is normal, never null |
| `thinking_delta.tokens` | `Option<u32>`, null on any backend with no estimate |
| `code_block.language` | `Option<String>`, null when the fence had no tag |
| `code_block.source` | `String` |
| `code_block.html` | `Option<String>`, null until phase 3 populates it |
| `tool_call.call` | `String` |
| `tool_call.name` | `String` |
| `tool_call.display_name` | `Option<String>` |
| `tool_call.summary` | `Option<String>`, null when the backend sends no description |
| `tool_call.input` | `serde_json::Value` |
| `tool_call.origin` | `String`, `harness` or `mcp` |
| `tool_result.ok` | `bool`, false only when the backend said so; a missing harness `is_error` maps to true |
| `tool_result.content` | `String` |
| `tool_result.truncated` | `bool` |
| `permission_request.request` | `String` |
| `permission_request.description` | `Option<String>` |
| `permission_request.suggestions` | `Vec<Value>`, empty rather than null |
| `permission_request.withdrawn` | `bool` |
| `diff.path` | `PathBuf` |
| `diff.old_text`, `diff.new_text` | `String` |
| `diff.added`, `diff.removed` | `u32` |
| `diff.html` | `Option<String>`, null until phase 3 populates it |
| `plan.title` | `Option<String>`, null when the backend sends only a body |
| `plan.markdown` | `String` |
| `plan.state` | `String`, `proposed`, `accepted` or `rejected` |
| `usage.input_tokens`, `usage.output_tokens` | `u64` |
| `usage.cache_read_tokens`, `usage.cache_write_tokens` | `Option<u64>`, null on every backend but the two Anthropic ones |
| `usage.thinking_tokens` | `Option<u64>` |
| `usage.cost_usd` | `Option<f64>`, null on ollama and openai-compatible |
| `usage.rate_limit` | `Option<RateLimit>`, harness only |
| `turn_end.stop` | `String`, the five values listed above |
| `turn_end.text` | `Option<String>`, null on an interrupted turn, which sends no summary |
| `turn_end.duration_ms` | `u64` |
| `error.kind`, `error.message` | `String` |
| `error.fatal` | `bool` |
| `conversations.items[].title` | `Option<String>`, null until the first turn names it |
| `conversations.items[].turns` | `u32` |
| `backends.items[].models` | `Vec<String>`, empty rather than null |
| `backends.items[].detail` | `Option<String>`, null when `state` is `ready` |
| `ready.protocol` | `u32` |
| `ready.seq_head` | `u64`, the highest persisted seq at connect time |

## 3. Backend mapping

Four backends adapt onto the schema above. `codex` is a stub: the binary is
not installed on this machine, nothing was observed, and
`src/backend/codex.rs` reports `unconfigured` until someone can test it. It
gets no row.

The event set is split across three tables so the cells stay readable.

### Turn and text

| Backend | `turn_start` | `text_delta` | `thinking_delta` | `code_block` | `turn_end` |
|---|---|---|---|---|---|
| claude-code | `system/init` for the turn | `content_block_delta`/`text_delta` | `thinking_delta`, text always empty, `estimated_tokens` only | `render.rs` over the settled text at `content_block_stop` | `result`, mapped from `subtype` and `stop_reason` |
| anthropic | synthesized when the daemon posts `/v1/messages` | SSE `content_block_delta`/`text_delta`, same shape | SSE `thinking_delta` with real text, only when the request enables extended thinking | same render path | `message_delta.stop_reason` plus `message_stop` |
| openai-compatible | synthesized at `POST /v1/chat/completions` | `choices[0].delta.content` | `choices[0].delta.reasoning_content`, only on servers that send it | same render path | `choices[0].finish_reason` |
| ollama | synthesized at `POST /api/chat` | `message.content` per chunk | `message.thinking`, only on models that emit it | same render path | `done:true` plus `done_reason` |

### Tools and approvals

| Backend | `tool_call` | `tool_result` | `permission_request` | `diff` | `plan` |
|---|---|---|---|---|---|
| claude-code | `content_block_start`/`tool_use` for the name, settled `assistant` line for the arguments | `user` line carrying a `tool_result` block; `is_error` inverts to `ok` and a missing `is_error` means `ok: true` | `control_request`/`can_use_tool`, answered by `control_response` | reshaped by the daemon from `Write`/`Edit`/`MultiEdit` arguments; the CLI sends no diff | `ExitPlanMode` tool input |
| anthropic | SSE `tool_use` block, arguments assembled from `input_json_delta` | emitted by the daemon after it runs the MCP tool | daemon-side, `policy.rs` only, nothing on the wire to the provider | not emitted | not emitted |
| openai-compatible | `delta.tool_calls[]`, arguments assembled per `index` across chunks | same, daemon-run MCP result | daemon-side only | not emitted | not emitted |
| ollama | `message.tool_calls`, arrives whole rather than streamed | same, daemon-run MCP result | daemon-side only | not emitted | not emitted |

### Accounting and daemon-scoped events

| Backend | `usage` | `error` | `conversations` | `backends` | `ready` |
|---|---|---|---|---|---|
| claude-code | `message_delta.usage` live, `result.usage` and `total_cost_usd` final, `rate_limit_event` folded in | `result.is_error` with `errors[]`, plus child stderr and non-zero exit | from `store.rs`, backend-independent | listed when `dots.ai.claude` is on and `claude` resolves on PATH | daemon-wide, once per client connection |
| anthropic | `message_delta.usage`; `cost_usd` computed by the daemon from a static price table, `null` when the model is unknown | HTTP status plus `error.type` from the body | same | listed when `dots.ai.claude` is on and a key is in the keyring | same |
| openai-compatible | `usage` on the final chunk, only when the request sets `stream_options.include_usage`; `cost_usd` always `null` | HTTP status plus `error.message` | same | listed when a base URL and key are configured | same |
| ollama | `prompt_eval_count` and `eval_count` from the final chunk; no cache split, `cost_usd` always `null` | `{"error":"..."}` body, or a refused connection on 11434 | same | listed when `dots.ai.ollama` is on and 11434 answers | same |

### What does not map

Some of the schema is honestly unfillable for some backends, and the pane
has to render around that rather than wait for data that never comes.

**Raw providers emit no plan and no diff.** Both come from harness tools
(`ExitPlanMode`, `Write`, `Edit`). In provider mode there are no file tools
at all, by design, so there is nothing to diff and no plan to accept. The
pane hides the diff view and the plan card when the active backend declares
it cannot produce them.

**Model changes do not apply to a running thread.** For the harness, v1
closes the child and respawns with `--resume <session-id>` and a new
`--model`, which is also the path a backend switch takes. The bundle does
list `set_model` among the control subtypes the CLI accepts, so an in-place
switch may be possible, but the spike never sent one and it stays unverified.

**Ollama has no cost and no cache accounting.** It reports raw
`prompt_eval_count` and `eval_count` in the final chunk and nothing else, so
`cost_usd`, `cache_read_tokens` and `cache_write_tokens` are `null` on every
ollama turn. A usage panel that assumes a number is present will show zeros
for a local model. The openai-compatible backend is nearly as bare: it
reports token counts only when the client asks for them, and never a price.

**Thinking differs on all four.** The harness sends the block structure with
an empty string and a token estimate. The Anthropic API sends real thinking
text, and only when the request turns extended thinking on. An
openai-compatible server sends `reasoning_content` if it implements that
extension, which most do not. Ollama sends `message.thinking` on the handful
of models that separate it. So `thinking_delta.text` is allowed to be empty
forever, and the pane must treat a thinking block with no text as normal,
not as a bug.

## 4. Rust module map

One file, one job. This matches the phase split in the plan, so a phase
touches a contiguous set.

| File | Owns |
|---|---|
| `src/main.rs` | argv, socket path from `$XDG_RUNTIME_DIR`, logging setup, systemd readiness, shutdown |
| `src/lib.rs` | crate root, the error type, re-exports for the test crates |
| `src/proto.rs` | the whole schema in section 2, both directions, serde types, `seq` allocation |
| `src/server.rs` | the unix listener, one NDJSON read and write loop per client, resume replay, fan-out to several connected clients |
| `src/session.rs` | one conversation: turn lifecycle, the pending-permission table, interrupt, backend restart |
| `src/store.rs` | JSONL persistence under `$XDG_DATA_HOME/dots-ask/`, append, resume by `seq`, list, delete |
| `src/backend/mod.rs` | the `Backend` trait, the registry, and which backends `dots.ai` enables |
| `src/backend/claude_code.rs` | harness argv, the `initialize` handshake, stream-json decode, the `control_request` and `control_response` envelope |
| `src/backend/anthropic.rs` | `/v1/messages` with SSE |
| `src/backend/openai.rs` | `/v1/chat/completions` with SSE, for any OpenAI-compatible server |
| `src/backend/ollama.rs` | `/api/chat` NDJSON on 11434 |
| `src/backend/codex.rs` | stub, reports `unconfigured` |
| `src/mcp.rs` | the `rmcp` client side, server discovery, tool listing, invocation |
| `src/policy.rs` | deny by default, the allow-always store, path scoping |
| `src/secrets.rs` | `secret-tool lookup`, lazy, capped at 10s |
| `src/render.rs` | pulldown-cmark plus syntect on `default-fancy`, producing `code_block.html` and `diff.html` |

Tests live in `rust/ask-daemon/tests/`, never inline, per `CLAUDE.md`:
`proto.rs` for schema round-trip, `server.rs` for `seq` replay and multiple
clients, `store.rs` for append and resume, and a replay test that drives
`tests/fixtures/claude-stream.jsonl` through the harness decoder and asserts
the three permission outcomes.

## 5. Security model

The rule is deny by default. Nothing runs without a decision that a person
made, or a rule that a person wrote earlier.

**Harness mode.** Every tool goes through `control_request` /
`can_use_tool`. The daemon passes `--permission-mode manual`, which resolves
to `default`, and it must pass `--permission-prompt-tool stdio`; without
that flag the CLI auto-denies and the pane never sees a prompt, which the
spike confirmed. The daemon never passes `--dangerously-skip-permissions` or
`--permission-mode bypassPermissions`. It drops a request the CLI withdrew
with `control_cancel_request` instead of answering it late.

**Answer every server-to-client control request, not only `can_use_tool`.**
An unanswered control request stalls the turn with no visible cause, and the
CLI can send three of them: `can_use_tool`, `request_user_dialog` and
`elicitation`. Only the first was exercised in the spike, so the other two
have no verified payload shape. That is a reason to reject them explicitly,
not a reason to ignore them. `src/backend/claude_code.rs` answers any
control request whose subtype it does not implement with a
`control_response` carrying a `deny` behavior and a message naming the
subtype, and raises an `error` event with `kind: "protocol"` so the pane
shows that something went unhandled. A daemon that silently drops an
`elicitation` from an MCP server hangs the turn forever.

One widening is worth naming rather than hiding. The harness still applies
the user's own `~/.claude/settings.json` allow rules, so a tool matching
those rules is approved inside the CLI and never reaches the pane at all.
`~/.claude/settings.json` currently allows broad `Bash(git *)` and
`Bash(python3 *)` patterns. Anyone who expects the pane to be a second gate
in front of those is wrong, and the pane says so in its backend detail line.

**Provider mode.** v1 ships no built-in shell tool and no built-in file
write tool. The only tools a raw provider can call are MCP tools from
servers that are already configured for `claude` or `codex`
(`nix/home/claude.nix:228`, `nix/home/codex.nix`,
`nix/home/computer-use-linux.nix`, `nix/home/edupage-mcp.nix`). `mcp.rs`
discovers that set at startup, and a tool name outside it gets a synthesized
error result rather than an execution. Each call still passes through
`policy.rs` before it runs, so the pane shows the same approval prompt it
shows in harness mode.

**Where decisions persist.** `once` and `session` decisions live in memory
in `session.rs` and die with the conversation or the daemon. `forever`
decisions go to `$XDG_STATE_HOME/dots-ask/policy.json`, keyed by backend,
tool name, an argument pattern, and the conversation's `cwd`, so an approval
granted in one checkout does not carry into another. They never go into the
conversation JSONL, which is a transcript, not a permission store. A
`forever` entry is plain JSON that a person can read and delete by hand.

**Everything else.** The socket sits in `$XDG_RUNTIME_DIR` at mode 0600 and
is owned by the user, which is the whole access-control story for the wire
protocol. `secrets.rs` reads keys through `secret-tool` lazily, with the 10s
timeout `nix/home/edupage-mcp.nix:160` established, and never writes a key
into the store, an event or a log line. Model output never reaches a real
HTML renderer in v1, because nothing in this schema carries HTML the pane
would trust: `render.rs` produces the small rich-text subset a QML `Text`
element draws, and Quickshell cannot host QtWebEngine anyway. Phase 5 adds
artifacts, and it inherits the whole question of where untrusted markup gets
rendered along with them.
