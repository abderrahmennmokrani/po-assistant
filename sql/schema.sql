-- PO Assistant: Postgres schema (steps 1 to 3 + event deduplication)
-- One channel = one project. channel_id is the Slack channel ID.
-- status moves forward: pitch_validated, personas_and_roles_validated, roadmap_validated.

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

-- Roadmap: one row (unique per project) for the vision / objective / journey / assumptions,
-- one row per epic. Deleting a roadmap deletes its epics.
-- The roadmap is generated once, then validated point by point: each of the four items and
-- each epic has a status ('created' until the Product Owner validates it, then 'validated').
-- 'labels' keeps the exact wording of the labels in the language of the roadmap
-- (e.g. "Objectif : ") so items and epics can be shown again without calling the model.
CREATE TABLE IF NOT EXISTS roadmaps (
    id                 SERIAL PRIMARY KEY,
    project_id         INTEGER NOT NULL REFERENCES projects(id),
    vision             TEXT NOT NULL,
    objective          TEXT NOT NULL,
    journey            TEXT,
    assumptions        TEXT,
    vision_status      TEXT NOT NULL DEFAULT 'created' CHECK (vision_status      IN ('created','validated')),
    objective_status   TEXT NOT NULL DEFAULT 'created' CHECK (objective_status   IN ('created','validated')),
    journey_status     TEXT NOT NULL DEFAULT 'created' CHECK (journey_status     IN ('created','validated')),
    assumptions_status TEXT NOT NULL DEFAULT 'created' CHECK (assumptions_status IN ('created','validated')),
    labels             JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (project_id)
);

CREATE TABLE IF NOT EXISTS epics (
    id          SERIAL PRIMARY KEY,
    roadmap_id  INTEGER NOT NULL REFERENCES roadmaps(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    title       TEXT NOT NULL,
    horizon     TEXT NOT NULL CHECK (horizon IN ('Now', 'Next', 'Later')),
    description TEXT NOT NULL,
    how         TEXT,                                -- short sentence when the epic has only one or two features
    features    JSONB NOT NULL DEFAULT '[]',         -- [{ "name": ..., "description": ... }]
    rules       JSONB NOT NULL DEFAULT '[]',         -- [ "...", ... ], empty for Later epics
    status      TEXT NOT NULL DEFAULT 'created' CHECK (status IN ('created','validated')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (roadmap_id, position)
);

-- Slack event deduplication (Slack retries an event if it is not acknowledged fast enough).
-- The orchestrator inserts "channel:ts"; a conflict means the event was already handled.
-- An hourly schedule in the orchestrator deletes rows older than one hour.
CREATE TABLE IF NOT EXISTS processed_events (
    event_key   TEXT PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The chat memory table (default name n8n_chat_histories, session_id = Slack channel ID)
-- is created and managed by n8n's Postgres Chat Memory node. The roadmap workflow also
-- reads and writes it directly with SQL.
