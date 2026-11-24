-- PO Assistant: Postgres schema (steps 1 to 7 + Slack event deduplication)
-- One channel = one project. channel_id is the Slack channel ID.
-- projects.status moves forward: pitch_validated, personas_and_roles_validated,
-- road_map_validated, epics_completed, features_completed, stories_completed.
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
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    dor_status            TEXT,   -- NULL until the Definition of Ready is validated, then 'validated'
    dor_page_id           TEXT    -- id of the Confluence page that holds the DoR
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
-- Product Owner has validated the roadmap. The epics table holds one row per epic.
CREATE TABLE IF NOT EXISTS roadmaps (
    id           SERIAL PRIMARY KEY,
    project_id   INTEGER NOT NULL REFERENCES projects(id),
    vision       TEXT NOT NULL,
    objective    TEXT NOT NULL,
    journey      TEXT NOT NULL,
    assumptions  TEXT NOT NULL DEFAULT '',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (project_id)
);

-- Epics are inserted as 'draft' when the roadmap is validated, with a priority and a horizon.
-- Workflow 04 develops the Now epics one at a time (the description holds the epic text: description,
-- rules and success measures) and sets them to 'validated'. Next and Later epics keep their brief
-- description. priority is one of Highest, High, Medium, Low, Lowest.
CREATE TABLE IF NOT EXISTS epics (
    id          SERIAL PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id),
    roadmap_id  INTEGER NOT NULL REFERENCES roadmaps(id) ON DELETE CASCADE,
    priority    TEXT NOT NULL CHECK (priority IN ('Highest', 'High', 'Medium', 'Low', 'Lowest')),
    title       TEXT NOT NULL,
    horizon     TEXT NOT NULL CHECK (horizon IN ('Now', 'Next', 'Later')),
    description TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'validated')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    jira_ticket_id TEXT   -- Jira issue id, written by workflow 07 (NULL = not pushed yet)
);

-- Features are inserted as 'draft' (title, description, priority) when an epic is validated in
-- workflow 04. Workflow 05 develops them one at a time (value and product rules, stored in
-- description) and sets them to 'validated'. priority is one of Highest, High, Medium, Low, Lowest.
CREATE TABLE IF NOT EXISTS features (
    id          SERIAL PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id),
    epic_id     INTEGER NOT NULL REFERENCES epics(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    description TEXT NOT NULL,
    priority    TEXT CHECK (priority IN ('Highest', 'High', 'Medium', 'Low', 'Lowest')),
    status      TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'validated')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    jira_ticket_id      TEXT,  -- Jira issue id of the feature (workflow 07)
    epic_jira_ticket_id TEXT   -- Jira issue id of its epic, so the feature can be created under it
);

-- The stories of a feature are inserted as 'draft' (title, description, priority) when the feature is
-- validated in workflow 05. Workflow 06 writes the statement and acceptance criteria of each story
-- (in description) and sets it to 'validated'. priority: Highest, High, Medium, Low, Lowest.
CREATE TABLE IF NOT EXISTS stories (
    id          SERIAL PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id),
    epic_id     INTEGER NOT NULL REFERENCES epics(id),
    feature_id  INTEGER NOT NULL REFERENCES features(id),
    title       TEXT NOT NULL,
    description TEXT NOT NULL,
    priority    TEXT CHECK (priority IN ('Highest', 'High', 'Medium', 'Low', 'Lowest')),
    status      TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'validated')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    jira_ticket_id         TEXT,  -- Jira issue id of the story (workflow 07)
    feature_jira_ticket_id TEXT,  -- Jira issue id of its feature (story is linked to it)
    epic_jira_ticket_id    TEXT   -- Jira issue id of its epic (story is created under it)
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

-- Upgrading an existing database from v1.1.x (columns added in v1.2.0):
-- ALTER TABLE projects ADD COLUMN IF NOT EXISTS dor_status TEXT, ADD COLUMN IF NOT EXISTS dor_page_id TEXT;
-- ALTER TABLE epics    ADD COLUMN IF NOT EXISTS jira_ticket_id TEXT;
-- ALTER TABLE features ADD COLUMN IF NOT EXISTS jira_ticket_id TEXT, ADD COLUMN IF NOT EXISTS epic_jira_ticket_id TEXT;
-- ALTER TABLE stories  ADD COLUMN IF NOT EXISTS jira_ticket_id TEXT, ADD COLUMN IF NOT EXISTS feature_jira_ticket_id TEXT, ADD COLUMN IF NOT EXISTS epic_jira_ticket_id TEXT;

-- Upgrading an existing database from v1.2.x to v1.3.0.
-- Priorities become text labels (Highest, High, Medium, Low, Lowest). Existing numeric priorities are
-- mapped by rank (epics: 1 Highest, 2 High, 3 Medium, 4 Low, else Lowest; features: 1 High, 2 Medium, 3 Low); adjust if needed. The rules, measures and steps columns
-- and the epics column of roadmaps are no longer used.
-- ALTER TABLE epics DROP CONSTRAINT IF EXISTS epics_priority_check;
-- ALTER TABLE epics DROP CONSTRAINT IF EXISTS epics_roadmap_id_horizon_priority_key;
-- ALTER TABLE epics ALTER COLUMN priority TYPE TEXT USING CASE priority WHEN 1 THEN 'Highest' WHEN 2 THEN 'High' WHEN 3 THEN 'Medium' WHEN 4 THEN 'Low' ELSE 'Lowest' END;
-- ALTER TABLE epics ADD CONSTRAINT epics_priority_check CHECK (priority IN ('Highest', 'High', 'Medium', 'Low', 'Lowest'));
-- ALTER TABLE features DROP CONSTRAINT IF EXISTS features_priority_check;
-- ALTER TABLE features ALTER COLUMN priority TYPE TEXT USING CASE priority WHEN 1 THEN 'High' WHEN 2 THEN 'Medium' WHEN 3 THEN 'Low' END;
-- ALTER TABLE features ADD CONSTRAINT features_priority_check CHECK (priority IN ('Highest', 'High', 'Medium', 'Low', 'Lowest'));
-- ALTER TABLE stories  ADD COLUMN IF NOT EXISTS priority TEXT CHECK (priority IN ('Highest', 'High', 'Medium', 'Low', 'Lowest'));
-- Optional cleanup of unused columns:
-- ALTER TABLE epics DROP COLUMN IF EXISTS rules, DROP COLUMN IF EXISTS measures;
-- ALTER TABLE features DROP COLUMN IF EXISTS rules, DROP COLUMN IF EXISTS steps;
-- ALTER TABLE roadmaps DROP COLUMN IF EXISTS epics;
