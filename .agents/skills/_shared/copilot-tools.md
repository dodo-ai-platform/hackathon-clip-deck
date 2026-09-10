# Cross-agent tool mapping (Claude Code ↔ GitHub Copilot CLI)

These skills do almost all real work through **plain `bash`** (running `gh`, `kubectl`,
`docker`, `git`, and the bundled `*.sh` scripts), which is identical on both agents.
Only the *agent-native* file/IO tools differ. Map by capability, don't hardcode.

| Capability | Claude Code | GitHub Copilot CLI | Portable fallback |
|------------|-------------|--------------------|-------------------|
| Run a shell command | `Bash` | `shell` / built-in exec | — |
| Read a file | `Read` | `read` / shell `cat` | `cat <file>` |
| Create / overwrite a file | `Write` | `write` / shell heredoc | `cat > f <<'EOF' … EOF` |
| Edit in place | `Edit` | `edit` / shell `sed` | `sed -i …` (GNU) / `python -` |
| Ask the user | `AskUserQuestion` | inline prompt | plain question in chat |

## Rules for these skills

- **Prefer the bundled `.sh` scripts and `gh`/`kubectl`** over agent-native tools — they behave the same everywhere.
- When you must read or modify a file (e.g. append the `CLAUDE.md → PLATFORM.md` link, fill `k8s/*.yaml`, rewrite the `Dockerfile`), use the agent's native read/write/edit tool if present; otherwise fall back to shell (`cat`, `sed`, heredoc).
- Skill discovery dir differs: Claude Code loads from `~/.claude/skills/`, Copilot/Codex from `~/.agents/skills/`. `install-skills.sh --dest` targets the right one (defaults to `~/.claude/skills` when `~/.claude` exists, else `~/.agents/skills`).
- Never assume a tool name — detect what's available and degrade to shell.
