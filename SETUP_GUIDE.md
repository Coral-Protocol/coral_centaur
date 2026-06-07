# Centaur Local Setup Guide (macOS + Claude Code OAuth)

This guide walks through setting up Centaur locally on macOS with a kind Kubernetes cluster, ngrok tunnel, and Claude Code using OAuth (access_token mode with a Claude Pro/Max subscription).

## Prerequisites

- macOS (Apple Silicon or Intel)
- Docker Desktop running
- A Slack workspace where you have admin access
- A 1Password account (free trial works)
- A Claude Pro/Max subscription (for OAuth-based Claude Code)

## Phase A: Install Tools

```bash
brew install helm just kind jq ngrok
```

Verify:

```bash
docker --version
kubectl version --client
helm version
just --version
kind version
```

## Phase B: Create Kubernetes Cluster

```bash
kind create cluster --name centaur
kubectl config use-context kind-centaur
kubectl get nodes
```

## Phase C: Create Slack App

1. Go to https://api.slack.com/apps → **Create New App** (from scratch)
2. Name it (e.g., `centaur-coral`), select your workspace
3. Go to **OAuth & Permissions** → **Bot Token Scopes**, add:
   - `app_mentions:read`
   - `chat:write`
4. Click **Install to Workspace** → Authorize
5. Copy the **Bot User OAuth Token** (`xoxb-...`) — this is `SLACK_BOT_TOKEN`
6. Go to **Basic Information** → copy the **Signing Secret** — this is `SLACK_SIGNING_SECRET`

> Note: The `xapp-...` App-Level Token is NOT what we need. We need the `xoxb-...` Bot Token.

## Phase D: Set Up 1Password

### D1: Create a Vault

In 1Password, create a new vault named `centaur`.

### D2: Extract Claude Code OAuth Credentials

On macOS, Claude Code stores OAuth credentials in the Keychain. Extract them:

```bash
# Get the full credentials JSON
security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -g 2>&1 | grep "^password:"
```

From the output, note:
- `refreshToken` value (starts with `sk-ant-ort01-...`)

The OAuth client ID is a fixed public value baked into the Claude Code binary:

```
9d1c250a-e61b-44d9-88ed-5944d1962f5e
```

### D3: Store Credentials in 1Password

Create two **API Credential** items in the `centaur` vault:

**Item 1: `CLAUDE_CODE_CLIENT_ID`**
- Title: `CLAUDE_CODE_CLIENT_ID`
- credential field: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`

**Item 2: `CLAUDE_CODE_BLOB`**
- Title: `CLAUDE_CODE_BLOB`
- credential field (must be JSON):
  ```json
  {"refresh_token":"sk-ant-ort01-YOUR_REFRESH_TOKEN_HERE"}
  ```

> IMPORTANT: `CLAUDE_CODE_BLOB` must be a JSON object, not a raw string. The token broker parses it as JSON.

### D4: Create a Service Account

1. Go to https://start.1password.com → **Developer** → **Directory** tab
2. Under **Access Tokens**, click **Service Accounts**
3. Create a new service account (any name, e.g., `centaur-sa`)
4. Grant it **Read & Write** access to the `centaur` vault (write is required because the token broker writes back refreshed tokens)
5. Copy the Service Account Token (starts with `ops_...`) — only shown once

## Phase E: Build and Deploy

### E1: Export Environment Variables

```bash
export OP_SERVICE_ACCOUNT_TOKEN="ops_..."
export OP_VAULT="centaur"
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_SIGNING_SECRET="your_signing_secret"
export SLACKBOT_API_KEY=$(openssl rand -hex 32)
```

### E2: Configure access_token Mode

Edit `contrib/chart/values.dev.yaml` and add `extraEnv` under `sandbox`:

```yaml
sandbox:
  image:
    pullPolicy: IfNotPresent
  extraEnv:
    CLAUDE_CODE_AUTH_MODE: access_token
```

Without this, the sandbox uses `api_key` mode (requires `ANTHROPIC_API_KEY`) instead of OAuth.

### E3: Build Docker Images

```bash
just build
# If memory constrained, use sequential builds:
# JUST_BUILD_SEQUENTIAL=1 just build
```

This builds 4 images:
- `centaur-api:latest` (~1.7GB)
- `centaur-iron-proxy:latest` (~93MB)
- `centaur-slackbot:latest` (~400MB)
- `centaur-agent:latest` (~2.5GB) — the sandbox image, takes longest

### E4: Load Images into kind

```bash
kind load docker-image \
  centaur-api:latest \
  centaur-slackbot:latest \
  centaur-iron-proxy:latest \
  centaur-agent:latest \
  --name centaur
```

This takes several minutes due to the 2.5GB agent image.

### E5: Bootstrap Secrets and Deploy

```bash
just bootstrap-secrets
just deploy
```

### E6: Verify

```bash
# Check all pods are Running
kubectl get pods -n centaur

# Health check
kubectl exec -n centaur deploy/centaur-centaur-api -- \
  curl -fsS http://localhost:8000/health
# Expected: {"status":"ok"}
```

## Phase F: Set Up Tunnel

Slack needs a public HTTPS URL to send webhook events.

### F1: Configure ngrok

```bash
ngrok config add-authtoken YOUR_NGROK_AUTHTOKEN
```

Sign up at https://dashboard.ngrok.com/signup if you don't have an account.

### F2: Start port-forward and tunnel

```bash
# Terminal 1: port-forward slackbot
kubectl port-forward -n centaur svc/centaur-centaur-slackbot 3001:3001

# Terminal 2: start ngrok
ngrok http 3001
# Or with a fixed domain (if you have one):
# ngrok http --url=your-domain.ngrok-free.dev 3001
```

Note the ngrok URL (e.g., `https://xxxx.ngrok-free.dev`).

> Note: `cloudflared` is an alternative but may fail if your network blocks port 7844 (UDP/TCP). ngrok uses standard port 443 and is more reliable.

## Phase G: Configure Slack Event Subscriptions

1. Go to https://api.slack.com/apps → select your app
2. Click **Event Subscriptions** → toggle ON
3. Set **Request URL** to:
   ```
   https://your-ngrok-url/api/webhooks/slack
   ```
4. Wait for Slack to verify (should show "Verified")
5. Under **Subscribe to bot events**, add: `app_mention`
6. Click **Save Changes**
7. If prompted, **Reinstall** the app

## Phase H: Test

1. Invite the bot to a channel: `/invite @your-bot-name`
2. Send a message:
   ```
   @your-bot-name --claude reply with exactly PONG
   ```
3. The bot should reply with `PONG` in a thread

The `--claude` flag selects the Claude Code harness. Without it, the default harness is Codex (requires `OPENAI_API_KEY` in 1Password).

## Troubleshooting

### Check logs

```bash
just logs slackbot    # Slack event handling
just logs api         # API / execution logs
kubectl logs -n centaur deploy/centaur-centaur-token-broker  # OAuth token refresh
kubectl get pods -n centaur -l centaur.ai/managed=true       # Sandbox pods
kubectl logs -n centaur -l centaur.ai/managed=true --all-containers  # Sandbox logs
```

### Check ngrok requests

```bash
# ngrok exposes a local dashboard
curl -s http://127.0.0.1:4040/api/requests/http | jq '.requests[] | {uri: .request.uri, status: .response.status_code}'
```

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| No response in Slack | Slack events not reaching slackbot | Check ngrok is running, Event Subscriptions URL is correct |
| `Invalid API key` | Wrong auth mode or missing credentials | Ensure `CLAUDE_CODE_AUTH_MODE: access_token` is in values.dev.yaml and redeploy |
| `parsing credential blob: invalid character` | `CLAUDE_CODE_BLOB` is not JSON | Edit 1Password item, set credential to `{"refresh_token":"sk-ant-ort01-..."}` |
| `credential marked dead` | Token broker failed to load after retries | Fix the credential in 1Password, then `kubectl rollout restart deployment/centaur-centaur-token-broker -n centaur` |
| Bot replies but no content (0 chars) | Default harness is Codex, no OpenAI key | Use `--claude` flag or add `OPENAI_API_KEY` to 1Password |
| Sandbox pods in `ImagePullBackOff` | Images not loaded into kind | Run `kind load docker-image ... --name centaur` |

### Restart Everything

```bash
# Redeploy after config changes
just deploy

# Delete old sandboxes (new ones created on next message)
kubectl delete pods -n centaur -l centaur.ai/managed=true

# Restart specific service
kubectl rollout restart deployment/centaur-centaur-api -n centaur
kubectl rollout restart deployment/centaur-centaur-token-broker -n centaur
```

### Stop (Pause Everything)

```bash
# 1. Stop the tunnel and port-forward
pkill ngrok
pkill -f "kubectl port-forward"

# 2. Stop Docker Desktop (K8s cluster hibernates with it)
osascript -e 'quit app "Docker Desktop"'
```

### Resume (Start Again)

```bash
# 1. Start Docker Desktop (K8s cluster and all pods auto-recover)
open -a "Docker Desktop"
# Wait ~30 seconds for Docker to fully start

# 2. Verify pods are running
kubectl get pods -n centaur

# 3. Start port-forward and tunnel
kubectl port-forward -n centaur svc/centaur-centaur-slackbot 3001:3001 &
ngrok http --url=regally-sappy-unmanned.ngrok-free.dev 3001
```

Then go to Slack and `@your-bot-name --claude your question here`.
