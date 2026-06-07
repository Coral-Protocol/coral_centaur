#!/bin/bash
# Watch Coral WebSocket for new messages
# Usage: ./watch_coral.sh <session_id>
if [ -z "$1" ]; then
  echo "Usage: ./watch_coral.sh <session_id>"
  exit 1
fi
SESSION_ID="$1"
WS_URL="ws://localhost:5555/ws/v1/events/test/session/demo/$SESSION_ID"

python3 -u -c "
import asyncio, websockets, json, time

async def main():
    deadline = time.monotonic() + 180
    async with websockets.connect('$WS_URL') as ws:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print('timeout: 3 minutes without new messages. Check coral state now.', flush=True)
                return
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=remaining)
                try:
                    d = json.loads(msg)
                    if d.get('type') == 'thread_message_sent':
                        print('new message received', flush=True)
                        return
                except:
                    pass
            except asyncio.TimeoutError:
                print('timeout: 3 minutes without new messages. Check coral state now.', flush=True)
                return

asyncio.run(main())
"
