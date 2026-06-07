#!/bin/bash
# Puppet: a dummy agent that connects to Coral MCP and stays alive.
# Launched by Coral Server via executable runtime.

echo "=== Coral Puppet Agent (Centaur Sandbox) ==="
echo "Agent ID:       $CORAL_AGENT_ID"
echo "Session ID:     $CORAL_SESSION_ID"
echo "Connection URL: $CORAL_CONNECTION_URL"

# Send MCP initialize request to establish Connected status
echo ">>> Sending MCP initialize handshake..."
RESPONSE=$(curl -s -D /tmp/puppet-headers-$CORAL_AGENT_ID.txt \
  -X POST "$CORAL_CONNECTION_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {
        "name": "puppet-agent",
        "version": "0.1.0"
      }
    }
  }')

echo ">>> Initialize response: $RESPONSE"

# Extract mcp-session-id from response headers
MCP_SESSION_ID=$(grep -i 'mcp-session-id' /tmp/puppet-headers-$CORAL_AGENT_ID.txt | tr -d '\r' | awk '{print $2}')
echo ">>> MCP Session ID: $MCP_SESSION_ID"

# Send initialized notification to confirm connection
curl -s -X POST "$CORAL_CONNECTION_URL" \
  -H "Content-Type: application/json" \
  -H "mcp-session-id: $MCP_SESSION_ID" \
  -d '{
    "jsonrpc": "2.0",
    "method": "notifications/initialized"
  }' > /dev/null 2>&1

echo ">>> Puppet agent connected and idle."

# Keep the process alive
while true; do
    sleep 3600
done
