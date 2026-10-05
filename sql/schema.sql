-- PO Assistant: Postgres schema (steps 1 and 2)
-- One channel = one project. channel_id is the Slack channel ID.
-- status moves forward: pitch_validated, then personas_and_roles_validated.

CREATE TABLE IF NOT EXISTS projects (
    id                    SERIAL PRIMARY KEY,
    project_name          TEXT NOT NULL,
    jira_key              TEXT,
    elevator_pitch        TEXT,
    status                TEXT,
    channel_id            TEXT,
    created_at            TIMESTAMPTZ DEFAULT now(),
    confluence_space_key  TEXT
);

-- Validated personas and roles, stored as JSON arrays (one row per validation).
CREATE TABLE IF NOT EXISTS personas (
    project_id  INTEGER REFERENCES projects(id),
    personas    JSONB
);

CREATE TABLE IF NOT EXISTS roles (
    project_id  INTEGER REFERENCES projects(id),
    roles       JSONB
);

-- The chat memory table (default name n8n_chat_histories, session_id = Slack channel ID)
-- is created and managed by n8n's Postgres Chat Memory node.
