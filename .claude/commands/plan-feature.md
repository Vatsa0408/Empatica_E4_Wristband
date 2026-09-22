---
description: Plan & assess a new feature — launches the app-planner subagent to produce a detailed guide in docs/plan/.
argument-hint: <describe the feature you want>
---

First, print exactly this line (fill in the model number/effort from the `model:`/`effort:`
frontmatter fields in `.claude/agents/app-planner.md`, do not hardcode them):
"Launching App Planner Agent with the Opus Model <number> and the effort of <effort>"

Then use the **app-planner** subagent to analyze the feature request for e4_integrator, assess
feasibility, research needed pub.dev packages and Android/Windows platform guidelines, and write
a detailed implementation guide to `docs/plan/`.

Feature request:
$ARGUMENTS

When the subagent finishes, show me the path of the generated guide and its executive summary.
