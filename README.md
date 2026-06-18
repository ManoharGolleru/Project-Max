# agent-harness v0.1

A local Linux terminal-first agent harness.

This package installs a generic local agent runtime. It does not build a specific app.

## Main goal

The package gives you:

- a local CLI command called agentctl
- machine checks through agentctl doctor
- Ollama model testing through agentctl model-test
- project workspace creation through agentctl init
- structured agent memory in .agent/
- permission prompts before shell commands
- logs and reports under ~/.agent-harness/

## Default target model

hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M

The real source of truth is:

~/.agent-harness/config.json

## Quick start

1. Install:

bash install.sh

2. Add agentctl to PATH for this shell:

export PATH="$HOME/.local/bin:$PATH"

3. Test:

agentctl doctor
agentctl model-test
agentctl init test-project
agentctl run test-project

## What v0.1 does

- Checks Python, Git, Docker, Node/npm, Ollama, RAM, swap, and disk
- Talks to Ollama through the local API
- Creates structured .agent memory
- Tests strict JSON output from the model
- Asks approval before shell commands
- Blocks obvious dangerous commands
- Stores logs and reports

## What v0.1 does not do yet

- No autonomous code editing
- No Playwright or axe-core UI inspection yet
- No MiniCPM routing yet
- No GUI
- No full Docker sandbox enforcement yet
