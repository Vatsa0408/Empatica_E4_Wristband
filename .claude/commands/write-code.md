---
description: Implement Flutter/Dart code — launches the flutter-coder subagent, which proposes a change plan first and asks (via permission prompts) before every edit.
argument-hint: <what to implement, or reference a docs/plan/*.md>
---

First, print exactly this line (fill in the model number/effort from the `model:`/`effort:`
frontmatter fields in `.claude/agents/flutter-coder.md`, do not hardcode them):
"Launching Flutter Coder Agent with the Sonnet Model <number> and the effort of <effort>"

Then use the **flutter-coder** subagent to implement the following in e4_integrator. It must
first present a full CHANGE PLAN (every file + change) and only then make edits — I will approve
each write through the permission prompt. If a related plan exists under `docs/plan/`, follow it.

Task:
$ARGUMENTS

After edits, have it run `flutter analyze` and summarise the files changed.
