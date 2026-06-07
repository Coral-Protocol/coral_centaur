#!/bin/bash
# Coral Claude Code Worker Agent — launched by coral-server via executable runtime.
# Adapted from coral-skills-testbed for Centaur sandbox environment.
#
# Each session gets its own subdirectory under instances/<session-id>/<agent-id>.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_DIR="$SCRIPT_DIR/instances/$CORAL_SESSION_ID/$CORAL_AGENT_ID"
mkdir -p "$INSTANCE_DIR"

CLAUDE_SETTINGS_DIR="$INSTANCE_DIR/.claude"
mkdir -p "$CLAUDE_SETTINGS_DIR"

echo "=== Coral Claude Code Worker (Centaur Sandbox) ==="
echo "Agent ID:       $CORAL_AGENT_ID"
echo "Session ID:     $CORAL_SESSION_ID"
echo "Connection URL: $CORAL_CONNECTION_URL"
echo "Instance dir:   $INSTANCE_DIR"

# Write .mcp.json for MCP server discovery (found from cwd)
cat > "$INSTANCE_DIR/.mcp.json" << EOF
{
  "mcpServers": {
    "coral": {
      "type": "http",
      "url": "$CORAL_CONNECTION_URL",
      "timeout": 1200000
    }
  }
}
EOF

# Write .claude/settings.local.json to auto-trust and auto-approve coral MCP server
cat > "$CLAUDE_SETTINGS_DIR/settings.local.json" << EOF
{
  "permissions": {
    "allow": [
      "mcp__coral"
    ]
  },
  "enabledMcpjsonServers": [
    "coral"
  ],
  "enableAllProjectMcpServers": true
}
EOF

# Write worker CLAUDE.md
cat > "$INSTANCE_DIR/CLAUDE.md" << 'WORKER_EOF'
# Coral Worker Agent

You are a worker agent in a Coral multi-agent session running inside a Centaur sandbox.

## Startup

Your first action MUST be to call `coral_wait_for_mention` to receive your task assignment.

## Communication Loop

Follow this exact loop every time you wait for messages:

1. Call `coral_wait_for_mention`
2. After it returns (whether with a message or a timeout), ALWAYS read `coral://state` resource to check for any messages you may have missed
3. If you find unread messages in the state that you haven't processed yet, handle them
4. Go back to step 1

This is critical because messages can arrive while you are not waiting, and `coral_wait_for_mention` only catches messages that arrive DURING the wait. The `coral://state` resource records ALL messages in threads you participate in.

## Communication Rules

- After EVERY message you send via `coral_send_message`, you MUST immediately enter the Communication Loop above
- Do NOT wait for human input. You are fully autonomous.
- Follow instructions from other agents completely.
- When your task is done, send a completion message mentioning the requester, then enter the Communication Loop for further instructions.

## Restrictions

- Do NOT ask the human for input or confirmation.
- Do NOT idle. Always be either working on a task or waiting for a mention.

## Capabilities

You have full access to tools: read/write files, run commands, search code, etc. Use whatever tools are needed to complete the task assigned to you.

You also have access to Centaur tools via the `call` helper if available in your environment.
WORKER_EOF

echo ">>> Auto-launching Claude Code for worker agent: $CORAL_AGENT_ID"
cd "$INSTANCE_DIR"
exec claude --permission-mode bypassPermissions -p "read coral://state resource then call coral_wait_for_mention"
