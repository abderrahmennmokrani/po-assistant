# PO Assistant

An AI pipeline built with **n8n** and **Claude** that helps a Product Owner turn a raw idea into structured product artifacts, with a human validation at every step.

You talk to the assistant in Slack. It drafts, you correct, you validate explicitly. Validated results are saved in **Postgres** (source of truth) and published to **Confluence**. One Slack channel = one project.

> **Status:** step 1 (elevator pitch), step 2 (personas and user roles), step 3 (roadmap), step 4 (epics) and step 5 (features) are built and tested end to end. Next: user stories per feature, with a quality loop, then the Jira push.

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
8. Right after the personas and roles are validated, the bot asks whether you want to start the roadmap. Answer yes and it generates a **vision**, an **objective**, a **journey**, **assumptions** and a short list of **epics** grouped in Now / Next / Later (title and brief description).
9. You negotiate it freely in the conversation (change an epic's horizon, add or remove an epic, ask a question) until you validate once, explicitly.
10. On validation, the roadmap is saved in Postgres (one row for the vision, objective, journey and assumptions, one row per epic with its horizon and its priority inside the horizon) and the project status becomes `road_map_validated`.
11. The epics of the Now horizon are then developed one at a time: description, business rules, functional building blocks ("how") with a priority, and success measures. You correct, then validate each epic, which is saved as soon as you validate it. When the last one is validated, the status becomes `epics_completed`.
12. The features of the Now epics (the building blocks of step 11) are then developed one at a time: description, business rules and steps (one step = one future user story). You correct, then validate each feature. After each validation the bot asks for the next feature; after the last one, the status becomes `features_completed` and the bot offers the user stories step.

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
   ├── status = personas_and_roles_validated ► 03 Roadmap
   ├── status = road_map_validated ──► 04 Epics
   └── status = epics_completed ────► 05 Features
```

Before any routing, the orchestrator records each Slack event (`channel:ts`) in Postgres with `INSERT ... ON CONFLICT DO NOTHING`. A Slack retry of the same event inserts nothing and stops there, so a message is never processed twice. An hourly schedule in the same workflow purges old rows.

Each sub-workflow follows the same pattern: **Guardrails → agent → Slack (human in the loop) → validation check → parsing → Postgres + Confluence → Slack confirmation.** The roadmap, epics and features are saved in Postgres only; they are not published to Confluence yet.

The project `status` column is updated last, so it only moves forward if everything before it succeeded.

## Design choices worth knowing

- **Guardrails in each sub-workflow** (01 to 05, each with a prompt adapted to its step), on user input only (custom LLM guardrail, threshold 0.7): prompt injection, prompt-extraction requests, off-topic messages, secrets, personal data, abusive content.
- **A dedicated reply agent for blocked messages.** It answers in the user's language, reminds the user of the current step, and never reveals why the message was blocked.
- **Explicit validation only.** For personas and roles, only a clear approval of both together counts. A bare "ok", a partial approval or a change request is not a validation: the assistant explains it and shows the unchanged list. On validation, the last list is reproduced word for word.
- **Language rules.** Field labels stay in English. Contents follow the language of the PO's latest message; if the language changes, everything is translated, including persona and role names.
- **Model split.** Sonnet 5.5 writes the pitch and the personas and roles, Opus 5.5 writes the roadmap, the epics and the features, Haiku 4.5 handles guardrails, parsing and reply agents. Nodes that need forced structured output use 4.x models, because 5-series models reject forced `tool_choice` through the API.
- **One item at a time, state in the database.** Workflows 04 and 05 pick the first draft epic (or feature) by priority, give the agent the full context plus an overview of its siblings for boundaries, and save the item as soon as the PO validates it. Each item has its own chat memory. Nothing depends on the chat history to know where the process stands.
- **Status set before the closing message.** When the last epic (or feature) is validated, the project status is updated before the closing question is sent, so the PO's next message is routed by the orchestrator straight to the next step.
- **The PO owns the consistency.** The assistant applies the requested change in the current item and does not try to detect the impact on the others.
- **Error handling everywhere.** Every node retries, then routes to an error output: the user gets a Slack message, then *Stop and Error* marks the execution as failed so the global Error Workflow emails the admin with the workflow name and an execution link.

## Repository layout

```
workflows/   n8n exports: orchestrator, 01 pitch, 02 personas and roles, 03 roadmap, 04 epics, 05 features, error notification
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
| Anthropic API key | Models used: Sonnet 5.5, Opus 5.5 (roadmap, epics, features), Haiku 4.5 (Opus 4.8 only as LLM judge in the evaluation). |
| Slack workspace | Where you can create an app. |
| Confluence Cloud | A space per project, and an Atlassian API token. |
| Gmail account | Used by the error workflow to email the admin. |

### 1. Create the database tables

Run `sql/schema.sql`. It creates `projects`, `personas`, `roles`, `roadmaps`, `epics`, `features`, `stories` and `processed_events` (Slack event deduplication).

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

Import the seven files from `workflows/`. They are exported inactive and without identifiers, so after import:

- map each node to your credentials;
- in the orchestrator, **re-select the five sub-workflows** (pitch, personas and roles, roadmap, epics, features) in the *Execute Workflow* nodes;
- in the orchestrator, replace `YOUR_BOT_USER_ID` in the *Check for bot message* node with your Slack bot's user ID (the only `channel_join` event the bot reacts to is its own);
- in the pitch workflow, **re-select the personas sub-workflow**, in the personas workflow **re-select the roadmap sub-workflow**, in the roadmap workflow **re-select the epics sub-workflow**, and in the epics workflow **re-select the features sub-workflow**, in their *Execute Workflow* nodes;
- replace `YOUR-DOMAIN.atlassian.net` in the Confluence nodes (pitch, personas and roles), and `YOUR_EMAIL@example.com` in the error workflow;
- in each workflow's settings, set the **Error Workflow** to the error notification workflow;
- if you want to run evaluations, recreate the Data Tables and load the datasets from `evals/`.

### 5. Activate and test

1. Activate the seven workflows.
2. Create a public Slack channel, invite the bot, and write a message. The bot should ask for the Jira code, project name and Confluence space key.
3. Describe an idea, ask for a change, validate. Check that the pitch appears in `projects` and as a Confluence page, then ask for the users, then for the roadmap, then go through the epics and the features, and repeat.

### Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| No reply at all | Workflow inactive, bot not invited in the channel, or the Slack Request URL does not match the Slack Trigger webhook URL. |
| "An unexpected error occurred" in Slack | Open the failed execution from the admin e-mail. Typical causes: expired Atlassian token, wrong Confluence space key, database unreachable. |
| Confluence error after a validation | A page with the same title already exists in that space. |
| Message after the features are validated gives an error | Expected for now: nothing is routed after `features_completed` yet. |
| No question about the roadmap after the personas are validated | The personas workflow must call the roadmap workflow with `mode = propose` and the `channel_id` (done by its *Edit Fields* node, which also sends `last_message`, the validating message, to choose the language). The roadmap workflow then sends an automatic `[SYSTEM_EVENT]` message and the agent only asks whether to start (no roadmap is generated). |
| Orchestrator stops silently on a new channel | Check that **Always Output Data** is ON for the project lookup node (*Execute a SQL query*). With zero rows and the option off, n8n stops the workflow without any output. |

## Evaluation

Agents were evaluated with n8n's Evaluation nodes, with datasets in `evals/`.

- **Elevator pitch:** 17 test cases (happy path, vague ideas, jargon, typos, English, onboarding, guardrails), scored by an LLM judge from 1 to 5, averaging about 4.1.
- **Guardrail reply agent:** a dataset covering injections, secrets, abusive content and several languages, checked for language match and for not leaking the reason for the block.
- **Roadmap, epics and features:** no n8n evaluation (each generation costs real money with Opus). The prompts were iterated on fictional test projects (digital, data and AI) and checked by hand, then validated in real Slack runs from the pitch to the last feature, with the database checked after each step.
- **End to end:** real Slack runs on test projects validated the validation and language rules.

## Known limitations

- Atlassian API tokens expire.
- Confluence refuses two pages with the same title in a space, so retrying a validation after a late failure ends in an error message (pitch, personas and roles).
- The database and the Confluence page are written in parallel: if Confluence fails after the database insert, the data is saved but the user gets an error.
- A project can have only one roadmap; there is no way to start over from Slack.
- The roadmap, epics and features are not published to Confluence yet.
- An epic or a feature cannot be reopened after its validation in the chat.
- Silent inconsistencies are possible after a change (for example a renamed epic still cited under its old title elsewhere): the assistant does not detect them, the PO checks them.
- Nothing is routed after `features_completed`: a new message ends in the generic error (user stories are not built yet).
- In *propose* mode the roadmap workflow loads neither the project context nor the history. The question is written in the language of the `last_message` field, which the personas workflow sends from its *Edit Fields* node (the Product Owner message that validated the personas and roles); without that field it falls back to French.
- No per-channel lock: two different messages sent a second apart in the same channel run in parallel.
- Arabic replies were not reviewed by a native speaker.

## Roadmap

User stories per feature with an evaluator-optimizer loop (writer, reviewer, Definition of Ready checker, at most two loops before handing over to the PO), then DoR/DoD and the Jira push.

## Author

Abderrahmen Mokrani, Senior Product Owner.

## Changelog

### v1.1.1 (2026-10-27)
- Refusal messages of steps 03, 04 and 05 now use the refusal prompt instead of the detection prompt.
- Workflow 05: if the first answer is a refusal ("non", "plus tard"), the assistant waits instead of presenting the first feature.
- Workflow 04: chat memory is now one conversation per epic.

### v1.1 (2026-10-27)
- Workflow 03 reworked: one generation of the vision, objective, journey, assumptions and a brief epic list, negotiated freely and validated once; epics saved as drafts with a priority inside their horizon.
- Added workflow 04: the Now epics are developed one at a time (description, business rules, building blocks with priority, success measures) and validated by the PO; status `epics_completed`.
- Added workflow 05: the features of the Now epics are developed one at a time (description, business rules, steps) and validated by the PO; status `features_completed`.
- Guardrails with a step-specific refusal message on steps 03, 04 and 05.
- Orchestrator routes the statuses `road_map_validated` and `epics_completed`.
- Error workflow email now includes the error details.
- The roadmap is no longer published to Confluence.

### v1.0 (2026-10-08)
- Roadmap validated point by point, final review, Confluence page.

### v0.2 (2026-10-05)
- Personas and roles, Slack event deduplication, SQL schema, evals.

### v0.1 (2026-10-04)
- Orchestrator, elevator pitch, first README.
