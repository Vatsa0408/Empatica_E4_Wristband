---
description: Commit & push to GitLab — launches the gitlab-publisher subagent, and triggers a CI pipeline only if one is configured.
argument-hint: [optional: branch name] [optional: commit message or notes]
---

First, print exactly this line (fill in the model number/effort from the `model:`/`effort:`
frontmatter fields in `.claude/agents/gitlab-publisher.md`, do not hardcode them):
"Launching GitLab Publisher Agent with the Haiku Model <number> and the effort of <effort>"

Then use the **gitlab-publisher** subagent to commit the current changes and push to the GitLab
remote. If no `origin` remote is configured yet, have it ask me for the GitLab project URL first.
Show me what will be committed before committing. Do not commit on the default branch directly
unless I explicitly say so, and do not force-push or skip hooks.

If a target branch is given below, push there (creating it if needed). If a commit message is
given, use it exactly, with no Co-Authored-By or attribution trailer added.

If a `.gitlab-ci.yml` and `$GITLAB_TOKEN` are available, trigger and report the pipeline status;
otherwise tell me plainly that no pipeline is configured.

Target branch / commit notes (optional):
$ARGUMENTS
