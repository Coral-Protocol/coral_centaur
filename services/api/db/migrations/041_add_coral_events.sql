-- migrate:up

CREATE TABLE coral_session_events (
    id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    thread_key TEXT NOT NULL,
    execution_id TEXT,
    coral_session_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    agent_name TEXT,
    payload JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_coral_events_thread ON coral_session_events(thread_key);
CREATE INDEX idx_coral_events_session ON coral_session_events(coral_session_id);
CREATE INDEX idx_coral_events_type ON coral_session_events(event_type);

-- migrate:down

DROP TABLE IF EXISTS coral_session_events;
