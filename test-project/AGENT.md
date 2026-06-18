# Agent workspace

This folder is managed by agent-harness.

Important folders:

- `workspace/`: files the agent is allowed to inspect and work inside.
- `.agent/`: structured memory, command history, plans, and logs.

Useful terminal commands:

```bash
agentctl dashboard .
agentctl chat .
agentctl run .
agentctl inspect .
agentctl last .
```
