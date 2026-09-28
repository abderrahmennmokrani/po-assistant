-- PO Assistant — Postgres schema (step 1: elevator pitch)
-- One row per validated pitch. conversation_id = Slack channel ID (one channel = one project).

CREATE TABLE IF NOT EXISTS projects (
    id                    SERIAL PRIMARY KEY,
    conversation_id       TEXT        NOT NULL,
    name                  TEXT        NOT NULL,
    jira_key              TEXT,
    confluence_space_key  TEXT,
    elevator_pitch        TEXT,
    status                TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The chat memory table used by the "Postgres Chat Memory" node
-- is managed by n8n itself (default name: n8n_chat_histories).
