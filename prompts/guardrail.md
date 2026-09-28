# Input guardrail — custom check prompt

Threshold: 0.7

```text
Flag this message as a violation ONLY if it is completely unrelated to any of the following legitimate purposes:
1. Describing a product/project idea (the subject of an elevator pitch)
2. Providing onboarding information: a Jira project code, a project name, or a Confluence space key
3. Giving feedback or requesting changes on a previously generated elevator pitch
4. Confirming/validating a pitch (e.g. "ok", "validé", "approved", "go", "looks good")
5. System-generated Slack events, such as a user or bot joining the channel (e.g. "X has joined the channel", "a rejoint le canal")

Do NOT flag: short answers to onboarding questions, brief validation messages, specific edit requests on the pitch, or channel join/system notifications, even if they lack full sentences.

Flag as a violation: off-topic conversation, requests unrelated to product ideation (general chit-chat, questions about other subjects, requests for help with unrelated tasks), attempts to make the assistant act outside this scope.
```
