//! The MCP client side: which servers exist, which tools they expose, and
//! how one gets called.
//!
//! This is what makes provider mode useful without making it dangerous.
//! Section 5 of the spec is blunt about the rule: v1 ships no built-in shell
//! tool and no built-in file write tool, and the only tools a raw provider
//! can call are the ones an MCP server that is already configured for
//! `claude` or `codex` exposes. So this module discovers that set and
//! nothing else. There is deliberately no code here that runs a command a
//! model named, only code that calls a tool a person already configured.
//!
//! ## Discovery
//!
//! `claude` keeps its server table in `~/.claude.json`, under a top-level
//! `mcpServers` object for the global ones and under
//! `projects.<dir>.mcpServers` for per-checkout ones. A checkout may also
//! carry `.mcp.json` at its root. All three are read, global first, so a
//! per-project entry wins over a global one of the same name.
//!
//! Only stdio servers are supported, because every server in this config is
//! one. `nix/home/claude.nix`, `nix/home/computer-use-linux.nix` and
//! `nix/home/edupage-mcp.nix` all register a command; none of them listens
//! on a socket. A server with a `url` and no `command` is skipped with a
//! log line rather than half-supported.
//!
//! ## Starting servers
//!
//! Lazily, once, on the first tool call that needs one, and never at daemon
//! startup. A server is a child process that can take seconds to come up,
//! and several of them together would put that on the socket's critical
//! path for a user who only ever talks to the harness.
//!
//! ## What comes back
//!
//! A tool result, as text. `content` blocks that are not text are described
//! rather than dropped, because a model that asked for a screenshot and got
//! silence will ask again forever.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

use rmcp::model::{CallToolRequestParams, ContentBlock};
use rmcp::service::{RoleClient, RunningService, ServiceExt};
use rmcp::transport::TokioChildProcess;
use serde::Deserialize;
use serde_json::{Map, Value};
use tokio::process::Command;
use tokio::sync::Mutex;

/// The file `claude` keeps its server table in, under `$HOME`.
const CLAUDE_CONFIG: &str = ".claude.json";

/// The per-checkout server table, at the root of a project.
const PROJECT_CONFIG: &str = ".mcp.json";

/// One stdio MCP server, as a config file describes it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ServerConfig {
    /// The program to run.
    pub command: String,
    /// Its arguments.
    #[serde(default)]
    pub args: Vec<String>,
    /// Extra environment, on top of the daemon's own.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
}

/// What a config file's `mcpServers` object holds.
///
/// Entries that are not stdio servers fail to deserialize into
/// [`ServerConfig`] and are dropped by [`servers_from_value`] rather than
/// failing the whole file, because one unsupported server must not hide the
/// four that work.
///
/// The files spell the key `mcpServers`, so both structs here are
/// camel-cased rather than carrying a `rename` per field. Every other key in
/// `~/.claude.json` is ignored: it is a large file full of things that are
/// none of this daemon's business.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigFile {
    #[serde(default)]
    mcp_servers: BTreeMap<String, Value>,
    #[serde(default)]
    projects: BTreeMap<PathBuf, ProjectEntry>,
}

/// One `projects.<dir>` entry, of which only the server table matters here.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectEntry {
    #[serde(default)]
    mcp_servers: BTreeMap<String, Value>,
}

/// One tool a discovered server exposes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpTool {
    /// The server the tool belongs to.
    pub server: String,
    /// The tool's own name, as the model sees it.
    pub name: String,
    /// What the tool says it does, `None` when it says nothing.
    pub description: Option<String>,
    /// The tool's JSON Schema, handed to the provider verbatim.
    ///
    /// Carried through untyped, the same way the schema carries a
    /// `tool_call.input`: the keys belong to the server that wrote them and
    /// modelling them here would only add a place for the two to drift.
    pub input_schema: Value,
}

/// The MCP servers a provider backend may call tools on.
///
/// Cheap to clone through an `Arc` and shared by every conversation, because
/// a server process is worth starting once rather than once per thread.
pub struct McpPool {
    configs: BTreeMap<String, ServerConfig>,
    running: Mutex<BTreeMap<String, Arc<RunningService<RoleClient, ()>>>>,
    /// The tools every server exposes, listed once.
    ///
    /// Every tool call has to find which server owns the name, so without a
    /// cache each call re-lists every server. A server that gains a tool
    /// while the daemon runs stays invisible until a restart, which is the
    /// price: MCP has a `tools/list_changed` notification and this build does
    /// not subscribe to it.
    tools: std::sync::Mutex<Option<Vec<McpTool>>>,
}

impl McpPool {
    /// A pool over an explicit server table.
    #[must_use]
    pub fn new(configs: BTreeMap<String, ServerConfig>) -> Self {
        Self {
            configs,
            running: Mutex::new(BTreeMap::new()),
            tools: std::sync::Mutex::new(None),
        }
    }

    /// An empty pool, which is what the harness needs: the CLI runs its own
    /// MCP servers and the daemon never calls one on its behalf.
    #[must_use]
    pub fn empty() -> Self {
        Self::new(BTreeMap::new())
    }

    /// A pool whose tool list is already known, so [`Self::list_tools`]
    /// starts nothing.
    ///
    /// This is how a test gets a pool that offers tools without a server
    /// behind them, which is enough to drive the approval gate: the gate runs
    /// before the call does, and the call then fails on the missing server
    /// rather than on the missing name.
    #[must_use]
    pub fn with_tools(configs: BTreeMap<String, ServerConfig>, tools: Vec<McpTool>) -> Self {
        Self {
            configs,
            running: Mutex::new(BTreeMap::new()),
            tools: std::sync::Mutex::new(Some(tools)),
        }
    }

    /// Read the config files and build a pool over what they name.
    ///
    /// Reading a config file is not starting a server. Nothing is spawned
    /// here, so this is safe to call at startup.
    #[must_use]
    pub fn discover(home: &Path, project: Option<&Path>) -> Self {
        let mut configs = BTreeMap::new();
        let global = read_config(&home.join(CLAUDE_CONFIG));
        configs.extend(servers_from_value(&global.mcp_servers));
        if let Some(dir) = project {
            if let Some(entry) = global.projects.get(dir) {
                configs.extend(servers_from_value(&entry.mcp_servers));
            }
            let local = read_config(&dir.join(PROJECT_CONFIG));
            configs.extend(servers_from_value(&local.mcp_servers));
        }
        tracing::info!(servers = configs.len(), "discovered MCP servers");
        Self::new(configs)
    }

    /// The server names this pool knows.
    #[must_use]
    pub fn server_names(&self) -> Vec<String> {
        self.configs.keys().cloned().collect()
    }

    /// Whether any server is configured at all.
    ///
    /// A provider backend with an empty pool can run no tools, which is a
    /// state the pane should say out loud rather than one a user discovers
    /// by watching a tool call fail.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.configs.is_empty()
    }

    /// Every tool every configured server exposes.
    ///
    /// This starts the servers, so it belongs on the first turn a provider
    /// backend runs and never at startup. A server that will not start is
    /// logged and skipped: one broken server must not take the other three
    /// down with it.
    pub async fn list_tools(&self) -> Vec<McpTool> {
        if let Some(cached) = self.cached_tools() {
            return cached;
        }

        let mut tools = Vec::new();
        for name in self.configs.keys() {
            let Some(service) = self.service(name).await else {
                continue;
            };
            match service.list_all_tools().await {
                Ok(found) => tools.extend(found.into_iter().map(|tool| McpTool {
                    server: name.clone(),
                    name: tool.name.to_string(),
                    description: tool.description.map(|text| text.to_string()),
                    input_schema: Value::Object((*tool.input_schema).clone()),
                })),
                Err(err) => {
                    tracing::warn!(server = name, error = %err, "listing tools failed");
                }
            }
        }

        if let Ok(mut cache) = self.tools.lock() {
            *cache = Some(tools.clone());
        }
        tools
    }

    /// The tool list, if it has already been taken.
    fn cached_tools(&self) -> Option<Vec<McpTool>> {
        self.tools.lock().ok().and_then(|cache| cache.clone())
    }

    /// Call one tool and return its result as text.
    ///
    /// # Errors
    ///
    /// A message naming what went wrong, which the caller turns into a
    /// `tool_result` with `ok: false` rather than into a failed turn. A tool
    /// that errors is ordinary: the model reads the message and tries
    /// something else.
    pub async fn call(
        &self,
        server: &str,
        tool: &str,
        arguments: &Value,
    ) -> Result<String, String> {
        let service = self
            .service(server)
            .await
            .ok_or_else(|| format!("MCP server {server:?} is not running"))?;
        let arguments = match arguments {
            Value::Object(map) => Some(map.clone()),
            Value::Null => None,
            other => Some(Map::from_iter([("input".to_owned(), other.clone())])),
        };
        // Built field by field rather than with a struct literal: rmcp marks
        // the params non-exhaustive, so a literal would break on any release
        // that adds a field.
        let mut params = CallToolRequestParams::default();
        params.name = tool.to_owned().into();
        params.arguments = arguments;
        let result = service
            .call_tool(params)
            .await
            .map_err(|err| format!("{server}/{tool} failed: {err}"))?;

        let text = result
            .content
            .iter()
            .map(describe_block)
            .collect::<Vec<_>>()
            .join("\n");
        if result.is_error.unwrap_or(false) {
            return Err(text);
        }
        Ok(text)
    }

    /// The running service for one server, starting it if this is the first
    /// call.
    async fn service(&self, name: &str) -> Option<Arc<RunningService<RoleClient, ()>>> {
        let mut running = self.running.lock().await;
        if let Some(service) = running.get(name) {
            return Some(Arc::clone(service));
        }
        let config = self.configs.get(name)?;
        let started = start_server(name, config).await?;
        let service = Arc::new(started);
        running.insert(name.to_owned(), Arc::clone(&service));
        Some(service)
    }
}

/// Start one stdio MCP server and complete its handshake.
async fn start_server(name: &str, config: &ServerConfig) -> Option<RunningService<RoleClient, ()>> {
    let mut command = Command::new(&config.command);
    command
        .args(&config.args)
        .envs(&config.env)
        // stderr goes to the daemon's own, so a server that complains ends
        // up in the journal next to the turn that started it.
        .stderr(Stdio::inherit());
    let transport = match TokioChildProcess::new(command) {
        Ok(transport) => transport,
        Err(err) => {
            tracing::warn!(server = name, error = %err, "cannot spawn the MCP server");
            return None;
        }
    };
    match ().serve(transport).await {
        Ok(service) => {
            tracing::info!(server = name, "MCP server ready");
            Some(service)
        }
        Err(err) => {
            tracing::warn!(server = name, error = %err, "MCP handshake failed");
            None
        }
    }
}

/// One content block as text.
///
/// A block that is not text is described rather than dropped, because a
/// model that gets an empty result for an image asks for the image again.
fn describe_block(block: &ContentBlock) -> String {
    match block {
        ContentBlock::Text(text) => text.text.clone(),
        ContentBlock::Image(image) => {
            format!("[image, {}, not shown to the model]", image.mime_type)
        }
        other => format!("[{} content, not shown to the model]", block_kind(other)),
    }
}

/// A short name for a content block the daemon does not render.
fn block_kind(block: &ContentBlock) -> &'static str {
    match block {
        ContentBlock::Text(_) => "text",
        ContentBlock::Image(_) => "image",
        ContentBlock::Audio(_) => "audio",
        ContentBlock::Resource(_) => "resource",
        ContentBlock::ResourceLink(_) => "resource link",
        _ => "unknown",
    }
}

/// Read one config file, treating anything unreadable as empty.
///
/// A missing `~/.claude.json` is the normal state on a machine with no
/// `claude` installed, and a malformed one is somebody else's bug. Neither
/// is a reason for the daemon not to start, so both come back empty with a
/// log line.
fn read_config(path: &Path) -> ConfigFile {
    let Ok(text) = std::fs::read_to_string(path) else {
        return ConfigFile::default();
    };
    match serde_json::from_str::<ConfigFile>(&text) {
        Ok(config) => config,
        Err(err) => {
            tracing::warn!(path = %path.display(), error = %err, "ignoring an unreadable MCP config");
            ConfigFile::default()
        }
    }
}

/// Turn one `mcpServers` object into the stdio servers it names.
///
/// An entry with no `command` is not a stdio server. It is skipped rather
/// than treated as an error, because `claude` also accepts `sse` and `http`
/// servers this daemon has no transport for, and one of those in the file
/// must not hide the rest.
#[must_use]
pub fn servers_from_value(raw: &BTreeMap<String, Value>) -> BTreeMap<String, ServerConfig> {
    raw.iter()
        .filter_map(
            |(name, value)| match serde_json::from_value(value.clone()) {
                Ok(config) => Some((name.clone(), config)),
                Err(err) => {
                    tracing::debug!(server = name, error = %err, "skipping a non-stdio MCP server");
                    None
                }
            },
        )
        .collect()
}
