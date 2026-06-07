# Coral ↔ Centaur Integration Guide

This document describes how Coral Protocol's multi-agent orchestration was integrated into Centaur's secure, durable agent runtime, enabling multi-agent collaboration triggered from Slack.

## Overview

Centaur runs a single AI agent per Slack conversation thread inside an isolated Kubernetes sandbox. Coral extends this by running as an on-demand sidecar inside the sandbox — when the orchestrator agent decides a task benefits from multi-agent collaboration, it spawns a Coral session with multiple worker agents, all sharing the same workspace.

```
Slack "@bot --coral spawn 2 agents to research ETH and BTC"
    ↓
Centaur API → K8s Sandbox Pod
    ├── Claude Code (orchestrator, primary harness)
    ├── coral-server (sidecar, idle until called)
    ├── tool-server (Centaur tools on localhost:8000)
    └── iron-proxy (credential injection)
    ↓
Orchestrator decomposes task → calls coral API → spawns worker agents
    ├── researcher-1 (Claude Code process): researches ETH
    ├── researcher-2 (Claude Code process): researches BTC
    └── (shared workspace — both see same files)
    ↓
Workers communicate via Coral threads/messages → results returned to Slack
```

## Architecture

### Design Decisions

**1. Coral-server is a sidecar, not a harness**

The primary harness (Claude Code / Codex / Amp) remains unchanged. coral-server starts as a background process inside the sandbox pod and stays idle until the orchestrator calls it. No changes to Centaur's `_ENGINE_HARNESSES` or `build_harness_cmd()`.

**2. Orchestrator uses curl to call Coral API directly**

Following the coral-agent-swarm skill pattern, the orchestrator agent calls coral-server's REST API via bash `curl` commands — no Centaur tool wrapper needed. The orchestrator has full bash permissions inside the sandbox.

**3. Worker agents use native Coral MCP**

Worker agents spawned by coral-server communicate using native MCP tools (`coral_send_message`, `coral_wait_for_mention`). This communication does not go through Centaur's tool layer.

**4. All agents share the sandbox workspace**

All coral agent processes run in the same K8s pod, sharing `/home/agent/workspace/`. One agent writes a file, another can read it immediately. Only `ExecutableRuntime` is used (no Docker-in-Docker inside K8s).

**5. Triggered via Centaur Persona**

A `coral` persona is registered in Centaur's tool manager. Users activate it with `--coral` in Slack, which loads the orchestrator prompt (PROMPT.md) that teaches the agent how to use coral-server.

### Dependency Chain

```
Slack message (@bot --coral ...)
    │
    ▼
ngrok tunnel → kubectl port-forward → Slackbot (services/slackbot/)
    │
    ▼
Slackbot POST /workflows/runs → slack_thread_turn workflow
    │
    ▼
Workflow parses --coral → persona_id="coral" → engine="claude-code"
    │
    ▼
spawn_assignment → K8s sandbox pod created
    │
    ▼
entrypoint.sh:
  ├── Configure Claude Code auth (OAuth access_token via iron-proxy)
  ├── Start coral-server sidecar (java -jar coral-server.jar, port 5555)
  ├── Symlink coral-agents/ → ~/.coral/agents/
  └── exec claude-app-wrapper → Claude Code CLI with coral PROMPT.md
    │
    ▼
Orchestrator (Claude Code):
  ├── curl localhost:5555 → verify coral-server ready
  ├── curl POST /api/v1/local/session → create session with agents
  ├── coral-server spawns worker processes (ExecutableRuntime)
  ├── curl POST .../thread → create communication channels
  ├── curl POST .../thread/message → assign tasks to workers
  ├── watch_coral.sh → wait for responses (WebSocket)
  ├── curl GET .../extended → read results
  ├── curl DELETE .../agent → kill finished workers
  └── Output summary → Slack thread
```

## Files Created / Modified

### New Files

| File | Purpose |
|---|---|
| `tools/personas/coral/pyproject.toml` | Persona declaration: `type="persona"`, `engine="claude-code"` |
| `tools/personas/coral/PROMPT.md` | Orchestrator prompt — Coral API reference, task decomposition workflow, communication loop |
| `services/sandbox/coral-agents/claude-code/coral-agent.toml` | Worker agent manifest for coral-server registry |
| `services/sandbox/coral-agents/claude-code/startup.sh` | Worker startup: writes `.mcp.json`, `CLAUDE.md`, launches `claude` CLI connected to coral MCP |
| `services/sandbox/coral-agents/puppet/coral-agent.toml` | Puppet agent manifest (orchestrator's proxy identity in Coral) |
| `services/sandbox/coral-agents/puppet/startup.sh` | Puppet startup: MCP handshake then sleep |
| `services/sandbox/watch_coral.sh` | WebSocket listener — blocks until `thread_message_sent` event, used by orchestrator to wait for agent responses |
| `services/sandbox/coral-event-bridge.py` | Lightweight HTTP server that receives coral-server webhook events and forwards to Centaur Postgres |
| `services/sandbox/coral-server.jar` | Pre-built coral-server fat JAR (~111MB) |
| `services/api/db/migrations/041_add_coral_events.sql` | Database migration for `coral_session_events` table |

### Modified Files

| File | Change |
|---|---|
| `services/sandbox/Dockerfile` | Added JDK 24 (Temurin) minimal JRE, coral-server.jar, watch_coral.sh, coral-event-bridge, coral-agents/ |
| `services/sandbox/entrypoint.sh` | Added coral-server sidecar startup block (symlink agents to `~/.coral/agents/`, generate `config.toml`, start java process) |
| `services/sandbox/claude-app-wrapper.py` | Added `--max-turns 2000` to Claude Code CLI command (default was 24) |
| `contrib/chart/values.dev.yaml` | Added `CORAL_ENABLED: "1"` and `CLAUDE_CODE_AUTH_MODE: access_token` to sandbox extraEnv |
| `services/slackbot/src/constants.ts` | Increased `taskCount` and `maxTasks` from 24 to 500 for longer multi-agent sessions |

## How to Use in Slack

### Basic (single agent, unchanged)

```
@bot --claude help me debug this function
@bot reply with PONG
```

### Multi-agent with Coral

```
@bot --coral spawn 2 agents to research ETH and BTC, then summarize
@bot --coral use 3 agents to analyze security issues in this codebase
@bot --coral start a debate: should we rewrite the auth module?
```

The `--coral` flag activates the coral persona. The orchestrator agent will:

1. Analyze the task and decide if multi-agent is needed
2. Start a Coral session with the appropriate number of worker agents
3. Create threads and assign tasks to each worker
4. Wait for results using the communication loop
5. Summarize findings and report back in the Slack thread

### What Happens Behind the Scenes

1. The `--coral` flag is parsed by `slack_thread_turn` workflow as `persona="coral"`
2. Centaur spawns a sandbox pod with Claude Code + coral-server sidecar
3. Claude Code reads the coral orchestrator prompt from `PROMPT.md`
4. The orchestrator calls coral-server API to create sessions and spawn agents
5. Worker agents (also Claude Code instances) connect to coral-server via MCP
6. Workers execute tasks autonomously and communicate through Coral threads
7. The orchestrator collects results and sends the summary to Slack

### Task Processing Workflow

The orchestrator follows this decision tree (from the coral-agent-swarm pattern):

1. **Atomic task?** Execute directly or spawn parallel agents for breadth
2. **Needs decomposition?** Break into subtasks, map dependencies
3. **Parallelizable subtasks?** Spawn one agent per independent subtask
4. **Needs verification?** Spawn a separate verifier agent
5. **Needs debate?** Spawn agents with opposing viewpoints in a shared thread

## Coral Agent Configuration

### Worker Agent (claude-code-agent)

Each worker agent launched by coral-server:

- Gets its own instance directory under `instances/<session-id>/<agent-id>/`
- Has a `.mcp.json` pointing to coral-server's MCP endpoint
- Has a `CLAUDE.md` with the worker prompt:
  - Start by calling `coral_wait_for_mention`
  - Communication loop: wait → read state → process → respond → repeat
  - Fully autonomous — no human input
  - Full tool access (read/write files, run commands)

### Puppet Agent

A minimal agent that connects to coral-server MCP and stays alive as the orchestrator's proxy identity. It does not run any LLM — just an MCP handshake and sleep.

### coral-server Configuration

Generated at sandbox startup in `~/.coral-config/config.toml`:

```toml
[auth]
keys = ["test"]

[network]
bindPort = 5555
bindAddress = "0.0.0.0"
externalAddress = "http://localhost:5555"

[registry]
includeCoralHomeAgents = true
localAgents = ["/home/agent/coral-agents/*"]

[session]
defaultWaitTimeoutMs = 300000
```

## Traceability

### Centaur-side (existing)

All orchestrator activity is recorded in Centaur's Postgres:
- `execution_events` — every tool call, text output, usage stats
- `execution_summary` — duration, token usage, cost, tool call counts
- `chat_messages` — user messages and agent responses

### Coral-side (new)

Coral session events can be bridged to Centaur Postgres via `coral-event-bridge.py`:

```sql
CREATE TABLE coral_session_events (
    id TEXT PRIMARY KEY,
    thread_key TEXT NOT NULL,
    execution_id TEXT,
    coral_session_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    agent_name TEXT,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

Event types: `coral_session_created`, `coral_agent_started`, `coral_message_sent`, `coral_agent_completed`, `coral_session_closed`.

## Known Limitations

1. **Slack Block Kit limit**: Slack messages support max 50 blocks. Multi-agent sessions with many steps will stop rendering in the live view after ~33 steps. The final result is delivered as a separate message.

2. **Shared credentials**: All worker agents in a coral session share the same iron-proxy instance and OAuth token. There is no per-agent credential isolation within a single sandbox pod.

3. **No Docker-in-Docker**: coral-server must use `ExecutableRuntime` inside K8s pods. `DockerRuntime` is not available.

4. **JDK 24 requirement**: coral-server is compiled with JDK 24 (class version 65.0). The sandbox image includes a Temurin 24 minimal JRE.

5. **OAuth token rotation**: When the token-broker refreshes the OAuth token, it writes back to 1Password, invalidating any local Claude Code session using the old token. Running Centaur and local Claude Code simultaneously requires separate `/login` after each broker refresh.

## Building and Deploying

### Prerequisites

- coral-server JAR must be pre-built:
  ```bash
  cd /path/to/coral-server
  ./gradlew build -x test
  cp build/libs/coral-server-*.jar /path/to/centaur/services/sandbox/coral-server.jar
  ```

### Build

```bash
# Rebuild sandbox image (includes coral-server + JDK + agent configs)
docker build --target sandbox -t centaur-agent:latest -f services/sandbox/Dockerfile .

# Rebuild API image (includes coral persona)
docker build -t centaur-api:latest -f services/api/Dockerfile .

# Load into kind cluster
kind load docker-image centaur-agent:latest centaur-api:latest --name centaur
```

### Deploy

```bash
# Ensure CORAL_ENABLED is set in values.dev.yaml
# sandbox.extraEnv.CORAL_ENABLED: "1"

# Deploy
helm upgrade --install centaur contrib/chart -n centaur -f contrib/chart/values.dev.yaml

# Clean old sandboxes so new ones pick up the updated image
kubectl delete pods -n centaur -l centaur.ai/managed=true
```

### Verify

```bash
# Check API loaded coral persona
kubectl exec -n centaur deploy/centaur-centaur-api -- ls /app/tools/personas/
# Should show: coral eng

# Test in Slack
@bot --coral spawn 2 agents to write poems about cats and dogs, then summarize
```
