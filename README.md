# PO Assistant

An AI pipeline built with **n8n** and **Claude** that helps a Product Owner turn a raw idea into structured product artifacts, with a human validation at every step.

You talk to the assistant in Slack. It drafts, you correct, you validate explicitly. Validated results are saved in **Postgres** (source of truth), published to **Confluence** (pitch, personas and roles, Definition of Ready) and pushed to **Jira** (epics, features, stories). One Slack channel = one project.

> **Status: V1 complete.** The full chain is built and tested end to end in Slack: elevator pitch, personas and roles, roadmap, epics, features, Definition of Ready, user stories, then the push of the epics, features and stories to Jira. Next (V2): a quality loop on the stories.

## What problem it solves

A Product Owner spends a lot of time producing the same framing documents for every new initiative. The PO Assistant produces a first draft of each one in seconds, keeps the PO in control (nothing is saved without an explicit validation), and stores everything where the team already works (Confluence for the framing documents, Jira for the backlog).

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
12. The features of the Now epics (the building blocks of step 11) are then developed one at a time: description, business rules and steps (one step = one future user story). You correct, then validate each feature. After each validation the bot asks for the next feature; after the last one, the status becomes `features_completed`.
13. The bot then sets up the **Definition of Ready (DoR)**, the rules every story must respect. It asks whether you already have one. If not, it proposes a short DoR from the project context and you correct and validate it; if yes, you paste it and the bot formats it (you can change it or use it as is). The validated DoR is published as a Confluence page, which the team can edit later: the stories always read the current page.
14. The user stories of each feature are then written one feature at a time: for each step of the feature, a statement ("As a... I want... so that...") and acceptance criteria that follow your DoR. You correct, then validate. After the last feature, the status becomes `stories_completed`.
15. **Workflow 07** pushes the validated items to Jira at the end of each phase: the Now epics when the epics are done, the features under their epic when the features are done, the stories under their epic (linked to their feature) when the stories are done. At the very end, an agent posts the link to the Jira board in the channel, in your language.

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
   ├── status = epics_completed ────► 05 Features
   └── status = features_completed ─► 06 Definition of Ready, then Stories

04, 05 and 06 each call 07 Jira integration at the end of their phase (without waiting for it).
```

Before any routing, the orchestrator records each Slack event (`channel:ts`) in Postgres with `INSERT ... ON CONFLICT DO NOTHING`. A Slack retry of the same event inserts nothing and stops there, so a message is never processed twice. An hourly schedule in the same workflow purges old rows.

Each sub-workflow follows the same pattern: **Guardrails → agent → Slack (human in the loop) → validation check → parsing → Postgres + Confluence → Slack confirmation.** The roadmap, epics, features and stories are saved in Postgres; the Definition of Ready is published to Confluence; epics, features and stories are pushed to Jira by workflow 07.

The project `status` column is updated last, so it only moves forward if everything before it succeeded.

## Design choices worth knowing

- **Guardrails in each conversational sub-workflow** (01 to 06, each with a prompt adapted to its step), on user input only (custom LLM guardrail, threshold 0.7): prompt injection, prompt-extraction requests, off-topic messages, secrets, personal data, abusive content.
- **A dedicated reply agent for blocked messages.** It answers in the user's language, reminds the user of the current step, and never reveals why the message was blocked.
- **Explicit validation only.** For personas and roles, only a clear approval of both together counts. A bare "ok", a partial approval or a change request is not a validation: the assistant explains it and shows the unchanged list. On validation, the last list is reproduced word for word.
- **Language rules.** Field labels stay in English. Contents follow the language of the PO's latest message; if the language changes, everything is translated, including persona and role names.
- **Model split.** Sonnet 5.5 writes the pitch and the personas and roles, Opus 5.5 writes the roadmap, the epics, the features, the Definition of Ready and the stories, Haiku 4.5 handles guardrails, parsing, reply agents and the final Jira message. Nodes that need forced structured output use 4.x models, because 5-series models reject forced `tool_choice` through the API.
- **One item at a time, state in the database.** Workflows 04 and 05 pick the first draft epic (or feature) by priority, give the agent the full context plus an overview of its siblings for boundaries, and save the item as soon as the PO validates it. Each item has its own chat memory. Nothing depends on the chat history to know where the process stands.
- **A DoR that belongs to the team.** The Definition of Ready lives in a Confluence page, not in the prompt. Before each feature the stories agent reads the page again, so a change made by the team in Confluence applies to the next stories without touching the assistant.
- **Jira push by level, with ids stored.** Workflow 07 reads the project status to know which level to push. Epics and features are selected only while their `jira_ticket_id` is empty; the Jira id returned for an epic is stored on the epic and on its features, the id of a feature on its stories, so each level can be created under or linked to the previous one. Stories are created one per 3 seconds to stay under Jira's rate limit.
- **Status set before the closing message.** When the last epic (or feature) is validated, the project status is updated before the closing question is sent, so the PO's next message is routed by the orchestrator straight to the next step.
- **The PO owns the consistency.** The assistant applies the requested change in the current item and does not try to detect the impact on the others.
- **Error handling everywhere.** Every node retries, then routes to an error output: the user gets a Slack message, then *Stop and Error* marks the execution as failed so the global Error Workflow emails the admin with the workflow name and an execution link.

## Repository layout

```
workflows/   n8n exports: orchestrator, 01 pitch, 02 personas and roles, 03 roadmap, 04 epics, 05 features, 06 stories, 07 Jira integration, error notification
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
| Anthropic API key | Models used: Sonnet 5.5, Opus 5.5 (roadmap, epics, features, DoR, stories), Haiku 4.5 (Opus 4.8 only as LLM judge in the evaluation). |
| Slack workspace | Where you can create an app. |
| Confluence Cloud | A space per project, and an Atlassian API token. |
| Jira Cloud | A **team-managed** software project per assistant project, with the issue types Epic, Feature and Story (see step 4). The same Atlassian API token is used. |
| Gmail account | Used by the error workflow to email the admin. |

### 1. Create the database tables

Run `sql/schema.sql`. It creates `projects`, `personas`, `roles`, `roadmaps`, `epics`, `features`, `stories` and `processed_events` (Slack event deduplication). The file ends with the `ALTER TABLE` statements to upgrade a database created with v1.1.x.

The chat memory (one conversation per Slack channel) is stored by n8n's Postgres Chat Memory node in its own history table, created automatically.

### 2. Create the credentials in n8n

- **Anthropic**: your API key.
- **Postgres**: connection to the database above.
- **Slack**: see step 3.
- **Atlassian** (Confluence and Jira): *HTTP Basic Auth*, username = your Atlassian e-mail, password = an API token created at <https://id.atlassian.com/manage-profile/security/api-tokens>. Tokens expire; if the Confluence or Jira steps start failing, regenerate it.
- **Gmail**: OAuth2, for the error notification workflow.

### 3. Create the Slack app

1. Create a Slack app and add a bot user.
2. Enable **Event Subscriptions** and set the Request URL to the webhook URL shown by the **Slack Trigger** node in the orchestrator.
3. Subscribe to message events and channel creation, and grant the bot scopes listed in n8n's [Slack credentials documentation](https://docs.n8n.io/integrations/builtin/credentials/slack/) for the events you use, plus permission to post messages.
4. Install the app in your workspace and copy the bot token into the n8n Slack credential.
5. Turn off token rotation (rotating tokens expire after 12 hours) and, on recent n8n versions, enable Slack signing secret verification.

Slack only allows one webhook URL per app, so you cannot test and run production with the same app at the same time.

### 4. Import the workflows

Import the nine files from `workflows/`. They are exported inactive and without identifiers, so after import:

- map each node to your credentials;
- in the orchestrator, **re-select the six sub-workflows** (01 to 06) in the *Execute Workflow* nodes;
- in the orchestrator, replace `YOUR_BOT_USER_ID` in the *Check for bot message* node with your Slack bot's user ID (the only `channel_join` event the bot reacts to is its own);
- in the pitch workflow, **re-select the personas sub-workflow**, in the personas workflow **re-select the roadmap sub-workflow**, in the roadmap workflow **re-select the epics sub-workflow**, in the epics workflow **re-select the features sub-workflow and the Jira sub-workflow**, in the features workflow **re-select the stories sub-workflow and the Jira sub-workflow**, and in the stories workflow **re-select the Jira sub-workflow**, in their *Execute Workflow* nodes;
- replace `YOUR-DOMAIN.atlassian.net` with your Atlassian site, in the Confluence nodes (pitch, personas and roles, stories) and in the Jira nodes (workflow 07). If your Confluence and Jira sites have different names, use each one in its own nodes. Replace `YOUR_EMAIL@example.com` in the error workflow;
- in workflow 07, the issue types are hard-coded: the epic is created by name (`Epic`), the feature and the story by **issue type id** (`10156` and `10119` in the author's Jira). Find yours with `GET https://YOUR-DOMAIN.atlassian.net/rest/api/3/issuetype` and change them in the nodes *insert features in jira* and *insert stories in jira*. Stories are linked to their feature with the `Relates` link type;
- in each workflow's settings, set the **Error Workflow** to the error notification workflow;
- if you want to run evaluations, recreate the Data Tables and load the datasets from `evals/`.

### 5. Activate and test

1. Activate the nine workflows.
2. Create a public Slack channel, invite the bot, and write a message. The bot should ask for the Jira code, project name and Confluence space key.
3. Describe an idea, ask for a change, validate. Check that the pitch appears in `projects` and as a Confluence page, then ask for the users, then for the roadmap, then go through the epics, the features, the DoR and the stories. At the end, check the tickets in the Jira backlog and the link posted in Slack. The Jira key you give at the first message must be an existing Jira project.

### Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| No reply at all | Workflow inactive, bot not invited in the channel, or the Slack Request URL does not match the Slack Trigger webhook URL. |
| "An unexpected error occurred" in Slack | Open the failed execution from the admin e-mail. Typical causes: expired Atlassian token, wrong Confluence space key, database unreachable. |
| Confluence error after a validation | A page with the same title already exists in that space. |
| Message after the stories are validated gives an error | Expected: nothing is routed after `stories_completed` (the orchestrator's fallback output ends in the generic error). |
| Jira shows duplicated tickets, or the stories branch of workflow 07 returns far more items than there are stories | *Execute Once* must stay ON in workflow 07 on *Get project infos* and *HTTP Request* (board lookup). Check that the setting was saved (workflow history) and keep a single editor tab open. |
| Jira returns a 400 on issue creation | The issue type ids of workflow 07 do not match your Jira project, or the Jira key does not exist. |
| A manual *Execute step* gives a different result from a real run | Manual runs use pinned data, production runs ignore it. Unpin the Slack Trigger and the trigger of workflow 07. |
| A sub-workflow receives nothing | The mapping of an *Execute Workflow* node can end up empty (`{}`). The sub-workflows accept all incoming data, so each call is fed by an *Edit Fields* node placed just before it (orchestrator, 04, 05, 06). |
| No question about the roadmap after the personas are validated | The personas workflow must call the roadmap workflow with `mode = propose` and the `channel_id` (done by its *Edit Fields* node, which also sends `last_message`, the validating message, to choose the language). The roadmap workflow then sends an automatic `[SYSTEM_EVENT]` message and the agent only asks whether to start (no roadmap is generated). |
| Orchestrator stops silently on a new channel | Check that **Always Output Data** is ON for the project lookup node (*Execute a SQL query*). With zero rows and the option off, n8n stops the workflow without any output. |

## Evaluation

Agents were evaluated with n8n's Evaluation nodes, with datasets in `evals/`.

- **Elevator pitch:** 17 test cases (happy path, vague ideas, jargon, typos, English, onboarding, guardrails), scored by an LLM judge from 1 to 5, averaging about 4.1.
- **Guardrail reply agent:** a dataset covering injections, secrets, abusive content and several languages, checked for language match and for not leaking the reason for the block.
- **Roadmap, epics, features, DoR and stories:** no n8n evaluation (each generation costs real money with Opus). The prompts were iterated on fictional test projects (digital, data and AI) and checked by hand, then validated in real Slack runs from the pitch to the Jira push, with the database checked after each step.
- **End to end:** real Slack runs on test projects validated the validation and language rules.

## Known limitations

- Atlassian API tokens expire.
- Confluence refuses two pages with the same title in a space, so retrying a validation after a late failure ends in an error message (pitch, personas and roles).
- The database and the Confluence page are written in parallel: if Confluence fails after the database insert, the data is saved but the user gets an error.
- A project can have only one roadmap; there is no way to start over from Slack.
- An epic or a feature cannot be reopened after its validation in the chat.
- Silent inconsistencies are possible after a change (for example a renamed epic still cited under its old title elsewhere): the assistant does not detect them, the PO checks them.
- Nothing is routed after `stories_completed`: a new message in the channel ends in the generic error (and an e-mail to the admin).
- The Jira push is not waited for: if it fails, the PO is not told in Slack, only the admin gets the e-mail. Running the stories push twice creates duplicates (its query does not filter on `jira_ticket_id`, unlike the epics and features ones).
- Jira issue type ids are hard-coded in workflow 07; the Jira project must exist beforehand.
- Stories can contain circular dependencies (A depends on B, B on A): the DoR asks to indicate dependencies, nothing checks them.
- Only the Now epics are detailed and pushed to Jira.
- In *propose* mode the roadmap workflow loads neither the project context nor the history. The question is written in the language of the `last_message` field, which the personas workflow sends from its *Edit Fields* node (the Product Owner message that validated the personas and roles); without that field it falls back to French.
- No per-channel lock: two different messages sent a second apart in the same channel run in parallel.
- Arabic replies were not reviewed by a native speaker.

## Roadmap

V2: a quality loop on the stories (evaluator-optimizer: writer, reviewer, Definition of Ready checker, at most two loops before handing over to the PO), a dependency check between stories, a Definition of Done.

## Author

Abderrahmen Mokrani, Senior Product Owner.

## Changelog

### v1.2.0 (2026-11-12) - V1 complete
- Added workflow 06: Definition of Ready (proposed, or pasted by the PO, validated, published as a Confluence page and re-read before each feature), then the user stories of each feature, one feature at a time; status `stories_completed`.
- Added workflow 07: pushes the Now epics, the features (under their epic) and the stories (under their epic, linked to their feature) to Jira, stores the Jira ids in Postgres, then posts the Jira board link in Slack in the PO's language.
- Orchestrator: routes `features_completed` to workflow 06; an *Edit Fields* node now feeds workflow 01, so it always receives the channel and the message.
- Workflows 04 and 05: call workflow 07 at the end of their phase. Closing message of the last epic, feature and story set adapted (no question when the next step starts by itself).
- Schema: `projects.dor_status`, `projects.dor_page_id` and the `jira_ticket_id` columns on epics, features and stories.
- Prompts updated for 02, 04 and 05, added for 06 and 07.

### v1.1.2 (2026-10-27)
- Workflows 04 and 05: when called in propose mode, the sub-workflow now runs the same context queries as a normal turn, so the first epic or feature is presented automatically.
- Workflow 04: the closing message of the last epic is sent before the first feature is presented, and the features are inserted before the call to 05.
- Workflow 04: the closing message of the last epic no longer asks a question.
- Workflow 05: `If propose mode` no longer outputs an empty item, which caused a spurious run on every user message.

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
