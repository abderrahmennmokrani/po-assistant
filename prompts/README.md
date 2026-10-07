# Prompts

System messages and guardrail prompts used by the PO Assistant agents, copied from the n8n workflows in `../workflows/`.

Each file is the exact text of the field in the matching node. To use one, paste it into the node field named below.

Lines such as `{{ $('When Executed by Another Workflow').item.json.elevator_pitch }}` are n8n expressions: the agent system messages that contain them must be set to **Expression** mode in n8n. Plain prompts (guardrails, judge) are set to **Fixed** mode.

## 01 - Elevator pitch (`workflows/po-assistant-01-elevator-pitch.json`)

| File | Node | Field | Model |
|------|------|-------|-------|
| `01-pitch/01_pitch_agent_system_message.txt` | Elevator pitch creator | Options > System Message | Claude Sonnet 5.5 |
| `01-pitch/02_guardrail_custom_prompt.txt` | Guardrails | Custom guardrail > Prompt (threshold 0.7) | Claude Haiku 4.5 |
| `01-pitch/03_guardrail_fail_reply_agent_system_message.txt` | Guardrail Fail reply to user agent | Options > System Message | Claude Haiku 4.5 |
| `01-pitch/04_parsing_agent_system_message.txt` | Parsing agent | Options > System Message | Claude Haiku 4.5 |
| `01-pitch/05_eval_llm_judge_prompt.txt` | Evaluation - Set metrics (LLM judge) | Prompt (evaluation only) | Claude Opus 4.8 |

## 02 - Personas and roles (`workflows/po-assistant-02-personas-roles.json`)

| File | Node | Field | Model |
|------|------|-------|-------|
| `02-personas-roles/01_personas_roles_creator_system_message.txt` | Personas & roles creator | Options > System Message | Claude Sonnet 5.5 |
| `02-personas-roles/02_guardrail_custom_prompt.txt` | Guardrails | Custom guardrail > Prompt (threshold 0.7) | Claude Haiku 4.5 |
| `02-personas-roles/03_guardrail_fail_reply_agent_system_message.txt` | Guardrail Fail reply to user agent | Options > System Message | Claude Haiku 4.5 |
| `02-personas-roles/04_parsing_agent_system_message.txt` | Parsing agent | Options > System Message | Claude Haiku 4.5 |

## 03 - Roadmap (`workflows/po-assistant-03-roadmap.json`)

| File | Node | Field | Model |
|------|------|-------|-------|
| `03-roadmap/01_roadmap_system_message_v14.txt` | Build the messages (Code node) | `TEMPLATE` constant; `{{ ... }}` placeholders are replaced by the node (`@@PITCH@@`, `@@PERSONAS@@`, `@@ROLES@@`) | Claude Opus 5.5 (HTTP Request, `effort: medium`, `max_tokens: 64000`) |
| `03-roadmap/02_guardrail_custom_prompt.txt` | Guardrails | Custom guardrail > Prompt (threshold 0.7) | Claude Haiku 4.5 |
| `03-roadmap/03_guardrail_fail_reply_agent_system_message.txt` | Guardrail Fail reply to user agent | Options > System Message | Claude Haiku 4.5 |

The roadmap has no parsing agent: the validated text is parsed by the *Parse the validated roadmap* Code node.

## How the agents are fed

- Agents receive the user message through the `guardrailsInput` field produced by the Guardrails node.
- The parsing agents receive the validated output of the previous agent and return structured JSON through a Structured Output Parser.
- Prompts are written in English; the agents answer in the language of the Product Owner (see the language rules inside the prompts).
- The personas creator also runs in a *propose* mode, called by the pitch workflow right after the pitch is published. Its **Text** field is `{{ $json.mode === 'propose' ? '[SYSTEM_EVENT] The pitch has just been validated and published. Ask the Product Owner whether they want to start creating the personas and roles.' : $json.guardrailsInput }}`; the system message handles the `[SYSTEM_EVENT]` prefix.
