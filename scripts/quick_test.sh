#!/usr/bin/env bash
set -euo pipefail

agentctl doctor
agentctl model-test
agentctl init smoke-test-project
agentctl inspect smoke-test-project
