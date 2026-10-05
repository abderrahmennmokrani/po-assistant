# PO Assistant

An AI pipeline built with **n8n** and **Claude** that helps a Product Owner turn a raw idea into structured product artifacts, with a human validation at every step.

You talk to the assistant in Slack. It drafts, you correct, you validate explicitly. Validated results are saved in **Postgres** (source of truth) and published to **Confluence**. One Slack channel = one project.

> **Status:** step 1 (elevator pitch) and step 2 (personas and user roles) are built and tested end to end. Next: user stories with a quality loop.

## What problem it solves

A Product Owner spends a lot of time producing the same framing documents for every new initiative. The PO Assistant produces a first draft of each one in seconds, keeps the PO in control (nothing is saved without an explicit validation), and stores everything where the team already works (Confluence, later Jira).

## What a conversation looks like

1. You create a Slack channel for the project and invite the bot.
2. The bot asks for the **Jira project code**, the **project name** and the **Confluence space key**.
3. You describe your idea in a sentence or two. The bot answers with an elevator pitch, no clarifying questions.
4. You ask for changes ("shorter", "add a line about pricing") until you validate ("validé", "looks good").
5. The pitch is saved in Postgres and published as a Confluence page; the link is posted in the channel.
6. Right after the pitch is published, the bot offers to start the users step. Answer yes and it proposes **personas** (groups of potential users) and **roles** (functions in the product). You correct, then approve both together.
7. Personas and roles are saved (two tables) and published to Confluence; the project status moves forward.

You can write in any language; the assistant answers in yours.

## Architecture

```
Slack message
   │
   ▼
Orchestrator ── ignores bots, message edits and deletions
   │            looks up the project by Slack channel_id in Postgres
   │            routes on the project status (Switch)
   ├── no project yet ──────────────► 01 Elevator Pitch
   ├── status = pitch_validated ────► 02 Personas and roles
   └── status = personas_and_roles_validated ► (user stories: not built yet)
```

Each sub-workflow follows the same pattern: **Guardrails → agent → Slack (human in the loop) → validation check → parsing agent → Postgres + Confluence → Slack confirmation.**

The project `status` column is updated last, so it only moves forward if everything before it succeeded.

## Design choices worth knowing

- **Guardrails in each sub-workflow**, on user input only (custom LLM guardrail, threshold 0.7): prompt injection, prompt-extraction requests, off-topic messages, secrets, personal data, abusive content.
- **A dedicated reply agent for blocked messages.** It answers in the user's language, reminds the user of the current step, and never reveals why the message was blocked.
- **Explicit validation only.** For personas and roles, only a clear approval of both together counts. A bare "ok", a partial approval or a change request is not a validation: the assistant explains it and shows the unchanged list. On validation, the last list is reproduced word for word.
- **Language rules.** Field labels stay in English. Contents follow the language of the PO's latest message; if the language changes, everything is translated, including persona and role names.
- **Model split.** Sonnet 5.5 writes the pitch and the personas and roles, Haiku 4.5 handles guardrails, parsing and reply agents. Nodes that need forced structured output use 4.x models, because 5-series models reject forced `tool_choice` through the API.
- **Error handling everywhere.** Every node retries, then routes to an error output: the user gets a Slack message, then *Stop and Error* marks the execution as failed so the global Error Workflow emails the admin with the workflow name and an execution link.

## Repository layout

```
workflows/   n8n exports: orchestrator, 01 pitch, 02 personas and roles, error notification
prompts/     system messages and guardrail prompts
sql/         database schema
evals/       evaluation datasets
```

## Getting started

### Prerequisites

| What | Notes |
|------|-------|
| n8n, self-hosted | Tested on 2.40.7. A public HTTPS URL is required because Slack calls your n8n webhook. |
| Postgres | Tested on 17. |
| Anthropic API key | Models used: Sonnet 5.5, Haiku 4.5 (Opus 4.8 only as LLM judge in the evaluation). |
| Slack workspace | Where you can create an app. |
| Confluence Cloud | A space per project, and an Atlassian API token. |
| Gmail account | Used by the error workflow to email the admin. |

### 1. Create the database tables

Use the schema in `sql/`. For reference, this is the minimal structure the workflows read and write (adapt types to your own conventions):

```sql
CREATE TABLE projects (
  id                   SERIAL PRIMARY KEY,
  project_name         TEXT NOT NULL,
  jira_key             TEXT,
  elevator_pitch       TEXT,
  status               TEXT,
  channel_id           TEXT,
  created_at           TIMESTAMPTZ DEFAULT now(),
  confluence_space_key TEXT
);

CREATE TABLE personas (project_id INTEGER REFERENCES projects(id), personas JSONB);
CREATE TABLE roles    (project_id INTEGER REFERENCES projects(id), roles    JSONB);
```

The chat memory (one conversation per Slack channel) is stored by n8n's Postgres Chat Memory node in its own history table, created automatically.

### 2. Create the credentials in n8n

- **Anthropic**: your API key.
- **Postgres**: connection to the database above.
- **Slack**: see step 3.
- **Confluence**: *HTTP Basic Auth*, username = your Atlassian e-mail, password = an API token created at <https://id.atlassian.com/manage-profile/security/api-tokens>. Tokens expire; if the Confluence step starts failing, regenerate it.
- **Gmail**: OAuth2, for the error notification workflow.

### 3. Create the Slack app

1. Create a Slack app and add a bot user.
2. Enable **Event Subscriptions** and set the Request URL to the webhook URL shown by the **Slack Trigger** node in the orchestrator.
3. Subscribe to message events and channel creation, and grant the bot scopes listed in n8n's [Slack credentials documentation](https://docs.n8n.io/integrations/builtin/credentials/slack/) for the events you use, plus permission to post messages.
4. Install the app in your workspace and copy the bot token into the n8n Slack credential.
5. Turn off token rotation (rotating tokens expire after 12 hours) and, on recent n8n versions, enable Slack signing secret verification.

Slack only allows one webhook URL per app, so you cannot test and run production with the same app at the same time.

### 4. Import the workflows

Import the four files from `workflows/`. They are exported inactive and without identifiers, so after import:

- map each node to your credentials;
- in the orchestrator, **re-select the two sub-workflows** in the *Execute Workflow* nodes;
- in the orchestrator, replace `YOUR_BOT_USER_ID` in the *Check for bot message* node with your Slack bot's user ID (the only `channel_join` event the bot reacts to is its own);
- in the pitch workflow, **re-select the personas sub-workflow** in its *Execute Workflow* node;
- replace `YOUR-DOMAIN.atlassian.net` in the two Confluence nodes, and `YOUR_EMAIL@example.com` in the error workflow;
- in each workflow's settings, set the **Error Workflow** to the error notification workflow;
- if you want to run evaluations, recreate the Data Tables and load the datasets from `evals/`.

### 5. Activate and test

1. Activate the four workflows.
2. Create a public Slack channel, invite the bot, and write a message. The bot should ask for the Jira code, project name and Confluence space key.
3. Describe an idea, ask for a change, validate. Check that the pitch appears in `projects` and as a Confluence page, then ask for the users and repeat.

### Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| No reply at all | Workflow inactive, bot not invited in the channel, or the Slack Request URL does not match the Slack Trigger webhook URL. |
| "An unexpected error occurred" in Slack | Open the failed execution from the admin e-mail. Typical causes: expired Atlassian token, wrong Confluence space key, database unreachable. |
| Confluence error after a validation | A page with the same title already exists in that space. |
| Message ignored after the personas step | Expected: the user stories step is not built yet. |
| Orchestrator stops silently on a new channel | Check that **Always Output Data** is ON for the project lookup node (*Execute a SQL query*). With zero rows and the option off, n8n stops the workflow without any output. |

## Evaluation

Agents were evaluated with n8n's Evaluation nodes, with datasets in `evals/`.

- **Elevator pitch:** 17 test cases (happy path, vague ideas, jargon, typos, English, onboarding, guardrails), scored by an LLM judge from 1 to 5, averaging about 4.1.
- **Guardrail reply agent:** a dataset covering injections, secrets, abusive content and several languages, checked for language match and for not leaking the reason for the block.
- **End to end:** real Slack runs on test projects validated the validation and language rules.

## Known limitations

- A message sent twice runs twice in parallel; there is no deduplication yet.
- Atlassian API tokens expire.
- Confluence refuses two pages with the same title in a space, so retrying a validation after a late failure ends in an error message.
- The user stories step is not built yet.
- Arabic replies were not reviewed by a native speaker.

## Roadmap

User stories with an evaluator-optimizer loop (writer, reviewer, Definition of Ready checker, at most two loops before handing over to the PO), then roadmap, DoR/DoD and Jira injection.

## Author

Abderrahmen Mokrani, Senior Product Owner.
