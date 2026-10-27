-- PO Assistant: Postgres schema (steps 1 to 5 + Slack event deduplication)
-- One channel = one project. channel_id is the Slack channel ID.
-- projects.status moves forward: pitch_validated, personas_and_roles_validated,
-- road_map_validated, epics_completed, features_completed.
-- The orchestrator routes each message on this status.
-- Every table has created_at / updated_at (except processed_events).
-- updated_at is maintained by the set_updated_at() trigger function (defined at the end of this file).

CREATE TABLE IF NOT EXISTS projects (
    id                    SERIAL PRIMARY KEY,
    project_name          TEXT NOT NULL,
    jira_key              TEXT,
    elevator_pitch        TEXT,
    status                TEXT NOT NULL DEFAULT 'pitch_validated',
    channel_id            TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    confluence_space_key  TEXT,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Validated personas and roles, stored as JSON arrays (one row per validation).
CREATE TABLE IF NOT EXISTS personas (
    id          SERIAL PRIMARY KEY,
    project_id  INTEGER REFERENCES projects(id),
    personas    JSONB NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS roles (
    id          SERIAL PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id),
    roles       JSONB NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Roadmap: one row per project (vision, objective, journey, assumptions) written once the
-- Product Owner has validated the roadmap. "epics" keeps the brief epic list generated with it
-- (title, horizon, brief description); the epics table holds one row per epic.
CREATE TABLE IF NOT EXISTS roadmaps (
    id           SERIAL PRIMARY KEY,
    project_id   INTEGER NOT NULL REFERENCES projects(id),
    vision       TEXT NOT NULL,
    objective    TEXT NOT NULL,
    journey      TEXT NOT NULL,
    assumptions  TEXT NOT NULL DEFAULT '',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    epics        JSONB NOT NULL DEFAULT '[]'::jsonb,
    UNIQUE (project_id)
);

-- Epics are inserted as 'draft' when the roadmap is validated (priority = rank inside the horizon).
-- Workflow 04 develops the Now epics one at a time (description, rules, measures) and sets
-- them to 'validated'. Next and Later epics keep their brief description.
CREATE TABLE IF NOT EXISTS epics (
    id          SERIAL PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id),
    roadmap_id  INTEGER NOT NULL REFERENCES roadmaps(id) ON DELETE CASCADE,
    priority    INTEGER NOT NULL CHECK (priority > 0),
    title       TEXT NOT NULL,
    horizon     TEXT NOT NULL CHECK (horizon IN ('Now', 'Next', 'Later')),
    description TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'validated')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    rules       TEXT[] NOT NULL DEFAULT '{}',
    measures    TEXT[] NOT NULL DEFAULT '{}',
    UNIQUE (roadmap_id, horizon, priority)
);

-- Features are inserted as 'draft' (title, description, priority 1 = highest) from the functional
-- building blocks of a validated epic. Workflow 05 develops them one at a time (description,
-- rules, steps) and sets them to 'validated'.
CREATE TABLE IF NOT EXISTS features (
    id          SERIAL PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id),
    epic_id     INTEGER NOT NULL REFERENCES epics(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    description TEXT NOT NULL,
    priority    SMALLINT CHECK (priority >= 1 AND priority <= 3),
    rules       TEXT[] DEFAULT '{}',
    status      TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'validated')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    steps       TEXT[] NOT NULL DEFAULT '{}'
);

-- The steps of a validated feature are stored as draft user stories (developed by the next step).
CREATE TABLE IF NOT EXISTS stories (
    id          SERIAL PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id),
    epic_id     INTEGER NOT NULL REFERENCES epics(id),
    feature_id  INTEGER NOT NULL REFERENCES features(id),
    title       TEXT NOT NULL,
    description TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'validated')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Slack event deduplication (Slack retries an event if it is not acknowledged fast enough).
-- The orchestrator inserts "channel:ts"; a conflict means the event was already handled.
-- An hourly schedule in the orchestrator deletes rows older than one hour.
CREATE TABLE IF NOT EXISTS processed_events (
    event_key   TEXT PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- updated_at maintenance: one shared function, one BEFORE UPDATE trigger per table.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_projects_updated_at ON projects;
CREATE TRIGGER trg_projects_updated_at BEFORE UPDATE ON projects
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_personas_updated_at ON personas;
CREATE TRIGGER trg_personas_updated_at BEFORE UPDATE ON personas
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_roles_updated_at ON roles;
CREATE TRIGGER trg_roles_updated_at BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_roadmaps_updated_at ON roadmaps;
CREATE TRIGGER trg_roadmaps_updated_at BEFORE UPDATE ON roadmaps
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_epics_updated_at ON epics;
CREATE TRIGGER trg_epics_updated_at BEFORE UPDATE ON epics
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_features_updated_at ON features;
CREATE TRIGGER trg_features_updated_at BEFORE UPDATE ON features
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS stories_set_updated_at ON stories;
CREATE TRIGGER stories_set_updated_at BEFORE UPDATE ON stories
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The chat memory table (default name n8n_chat_histories, session_id = Slack channel ID plus a suffix)
-- is created and managed by n8n's Postgres Chat Memory node.
