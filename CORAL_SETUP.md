# Coral + Centaur Setup Guide

This guide walks through setting up Coral multi-agent orchestration inside Centaur, from scratch. By the end, you'll be able to type `@bot --coral` in Slack and have multiple AI agents collaborating on your task.

## Prerequisites

- A working Centaur local deployment (see [SETUP_GUIDE.md](SETUP_GUIDE.md))
  - Docker Desktop running
  - kind cluster with Centaur deployed
  - Slack app configured and working
  - `@bot --claude reply with PONG` returns PONG
- Git and basic terminal knowledge

## Step 1: Clone coral-server Source

coral-server is a Kotlin/Gradle project. You need the source to build the JAR.

```bash
# Clone coral-server (adjust path as needed)
cd ~/coral
git clone https://github.com/Coral-Protocol/coral-server.git
```

## Step 2: Build coral-server JAR

coral-server compiles to a fat JAR that requires JDK 24.

```bash
cd ~/coral/coral-server

# Build (skipping tests for speed)
./gradlew build -x test

# Verify the JAR was created (~106MB)
ls -la build/libs/coral-server-*.jar
```

If you don't have JDK 24 locally, Gradle will download it automatically.

## Step 3: Copy JAR into Centaur

```bash
# Copy the built JAR to Centaur's sandbox directory
cp build/libs/coral-server-*.jar /path/to/centaur/services/sandbox/coral-server.jar

# Verify
ls -la /path/to/centaur/services/sandbox/coral-server.jar
# Should be ~106MB
```

This JAR is excluded from git (`.gitignore`) because it exceeds GitHub's 100MB file limit. You must build and copy it manually.

## Step 4: Verify Coral Files Exist

The following files should already be in the repo. Verify they're present:

```bash
cd /path/to/centaur

# Coral persona (Slack entry point)
cat tools/personas/coral/pyproject.toml
cat tools/personas/coral/PROMPT.md

# Worker agent configs
cat services/sandbox/coral-agents/claude-code/coral-agent.toml
cat services/sandbox/coral-agents/claude-code/startup.sh

# Puppet agent configs
cat services/sandbox/coral-agents/puppet/coral-agent.toml
cat services/sandbox/coral-agents/puppet/startup.sh

# Utility scripts
cat services/sandbox/watch_coral.sh
cat services/sandbox/coral-event-bridge.py

# DB migration
cat services/api/db/migrations/041_add_coral_events.sql
```

If any are missing, pull the latest from the repo.

## Step 5: Configure values.dev.yaml

Ensure `contrib/chart/values.dev.yaml` has these settings under `sandbox`:

```yaml
sandbox:
  image:
    pullPolicy: IfNotPresent
  extraEnv:
    CLAUDE_CODE_AUTH_MODE: access_token   # or api_key if using ANTHROPIC_API_KEY
    CORAL_ENABLED: "1"                    # starts coral-server sidecar in sandbox
```

## Step 6: Build Docker Images

Two images need rebuilding — sandbox (contains coral-server + JDK) and API (contains coral persona):

```bash
cd /path/to/centaur

# Build sandbox image (includes JDK 24 + coral-server.jar + agent configs)
# This is the slowest step on first build (~10-15 min) due to JDK download
docker build --target sandbox -t centaur-agent:latest -f services/sandbox/Dockerfile .

# Build API image (includes coral persona in tools/personas/)
docker build -t centaur-api:latest -f services/api/Dockerfile .
```

### What the sandbox Dockerfile does for Coral:

1. Downloads Temurin JDK 24 and builds a minimal JRE via `jlink` → `/opt/coral-java/`
2. Copies `coral-server.jar` → `/opt/coral-server/coral-server.jar`
3. Copies `watch_coral.sh` → `/usr/local/bin/watch_coral.sh`
4. Copies `coral-event-bridge.py` → `/usr/local/bin/coral-event-bridge`
5. Copies `coral-agents/` → `/home/agent/coral-agents/`

## Step 7: Load Images into kind

```bash
kind load docker-image centaur-agent:latest centaur-api:latest --name centaur
```

This takes several minutes (sandbox image is ~3GB). Wait for the command to finish.

## Step 8: Deploy

```bash
# Deploy updated Helm chart
helm upgrade --install centaur contrib/chart -n centaur -f contrib/chart/values.dev.yaml

# Delete old sandbox pods so new ones use the updated image
kubectl delete pods -n centaur -l centaur.ai/managed=true

# Restart API to pick up coral persona
kubectl rollout restart deployment/centaur-centaur-api -n centaur
```

## Step 9: Verify

```bash
# Check API has coral persona
kubectl exec -n centaur deploy/centaur-centaur-api -- ls /app/tools/personas/
# Expected output: coral eng

# Check all pods are running
kubectl get pods -n centaur

# Health check
kubectl exec -n centaur deploy/centaur-centaur-api -- curl -fsS http://localhost:8000/health
# Expected: {"status":"ok"}
```

## Step 10: Test in Slack

Make sure your tunnel is running:

```bash
# Terminal 1
kubectl port-forward -n centaur svc/centaur-centaur-slackbot 3001:3001

# Terminal 2
ngrok http --url=your-domain.ngrok-free.dev 3001
```

Then in Slack:

```
# Test single agent (should still work)
@bot --claude reply with exactly PONG

# Test multi-agent with Coral
@bot --coral spawn 2 agents to write poems about cats and dogs, then summarize
```

## What Happens When You Use --coral

1. Slackbot receives the message, triggers `slack_thread_turn` workflow
2. `--coral` is parsed as `persona="coral"`, loads `tools/personas/coral/PROMPT.md`
3. Sandbox pod starts with Claude Code + coral-server sidecar on port 5555
4. `entrypoint.sh` symlinks `coral-agents/` to `~/.coral/agents/` and starts coral-server
5. Claude Code reads the coral orchestrator prompt and becomes the orchestrator
6. Orchestrator uses `curl` to call coral-server API — creates sessions, spawns agents
7. Worker agents (separate Claude Code processes) connect to coral via MCP
8. Workers execute tasks in parallel, sharing the same workspace
9. Orchestrator collects results via `watch_coral.sh` + GET polling
10. Summary posted back to Slack thread

## Troubleshooting

### coral-server not starting

```bash
# Check if coral-server process is running inside sandbox
kubectl exec -n centaur <sandbox-pod> -c sandbox -- ps aux | grep java

# Check coral-server logs
kubectl exec -n centaur <sandbox-pod> -c sandbox -- cat /home/agent/.coral/logs/coral-server.log
```

Common issues:
- **UnsupportedClassVersionError**: JDK version mismatch. coral-server needs JDK 24. Check `/opt/coral-java/bin/java -version`
- **Permission denied on JAR**: The JAR needs to be readable by the `agent` user (uid 1001)
- **Port 5555 not listening**: coral-server may have crashed on startup. Check logs.

### Agents not found in registry

```bash
# Check what agents coral-server sees
kubectl exec -n centaur <sandbox-pod> -c sandbox -- \
  curl -s http://localhost:5555/api/v1/registry -H "Authorization: Bearer test"
```

If only built-in agents (echo, puppet, etc.) appear:
- Verify symlinks exist: `ls -la ~/.coral/agents/`
- Verify `config.toml` has correct `localAgents` path
- Check coral-server log for registry scan errors

### Agent spawn fails with 401

- OAuth token may have expired. Check token-broker:
  ```bash
  kubectl logs -n centaur deploy/centaur-centaur-token-broker --tail=10
  ```
- If `credential marked dead`, update `CLAUDE_CODE_BLOB` in 1Password and restart broker:
  ```bash
  # Extract current refresh token
  security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -g 2>&1 | \
    grep "^password:" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps({'refresh_token': d['claudeAiOauth']['refreshToken']}))"

  # Update 1Password
  op item edit CLAUDE_CODE_BLOB --vault centaur 'credential={"refresh_token":"sk-ant-ort01-NEW_TOKEN_HERE"}'

  # Restart broker
  kubectl rollout restart deployment/centaur-centaur-token-broker -n centaur
  ```

### Slack shows only ~33 steps then stops

This is a Slack Block Kit limitation (max 50 blocks per message). The agent continues working — the final result is delivered as a separate message. Not fixable without splitting output across multiple Slack messages.

### No response in Slack

1. Check ngrok is running: `curl http://127.0.0.1:4040/api/tunnels`
2. Check port-forward is running: `ps aux | grep port-forward`
3. Check slackbot logs: `kubectl logs -n centaur deploy/centaur-centaur-slackbot --tail=20`

## Updating coral-server

When coral-server source is updated:

```bash
# Rebuild JAR
cd ~/coral/coral-server
git pull
./gradlew build -x test

# Copy to Centaur
cp build/libs/coral-server-*.jar /path/to/centaur/services/sandbox/coral-server.jar

# Rebuild and redeploy sandbox image
cd /path/to/centaur
docker build --target sandbox -t centaur-agent:latest -f services/sandbox/Dockerfile .
kind load docker-image centaur-agent:latest --name centaur
kubectl delete pods -n centaur -l centaur.ai/managed=true
```

## Stop / Resume

### Stop

```bash
pkill ngrok
pkill -f "kubectl port-forward"
osascript -e 'quit app "Docker Desktop"'
```

### Resume

```bash
open -a "Docker Desktop"
# Wait ~30 seconds for Docker to start

kubectl get pods -n centaur                # verify pods recovered
kubectl port-forward -n centaur svc/centaur-centaur-slackbot 3001:3001 &
ngrok http --url=your-domain.ngrok-free.dev 3001
```
