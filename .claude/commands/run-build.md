---
description: Build/run e4_integrator locally for Android or Windows. Release+obfuscated by default; pass debug to override.
argument-hint: <android|windows> [debug]
---

First, print exactly this line (fill in the model number/effort from the `model:`/`effort:`
frontmatter fields in `.claude/agents/build-runner.md`, do not hardcode them):
"Launching Build Runner Agent with the Haiku Model <number> and the effort of <effort>"

Then use the **build-runner** subagent to run/build e4_integrator for the specified platform. If
the platform (android|windows) is missing from the arguments below, the subagent should stop and
ask rather than guessing. Never target iOS/Linux/macOS/web. Default to release mode with
obfuscation unless `debug` is explicitly given.

Platform / mode:
$ARGUMENTS
