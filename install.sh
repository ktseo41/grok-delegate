#!/usr/bin/env bash
# Install the grok-delegate skill into a Claude Code skills directory.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest_root="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
agents_dir="${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}"
with_subagent=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) dest_root="$2"; shift 2 ;;
    --with-subagent) with_subagent=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [--dest DIR] [--with-subagent]
  --dest DIR         Skills directory to install into (default: \$CLAUDE_SKILLS_DIR or ~/.claude/skills)
  --with-subagent    Also install the 'grok' dispatcher subagent to \$CLAUDE_AGENTS_DIR or ~/.claude/agents,
                     so you can delegate with '@grok ...' (runs grok in its own context; see agents/grok.md)
Installs the skill to <DIR>/grok-delegate.
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

dest="$dest_root/grok-delegate"
mkdir -p "$dest/scripts"
cp "$repo_dir/SKILL.md" "$dest/SKILL.md"
cp "$repo_dir/scripts/grok-run.sh" "$dest/scripts/grok-run.sh"
chmod +x "$dest/scripts/grok-run.sh"
echo "Installed grok-delegate -> $dest"

if [[ "$with_subagent" -eq 1 ]]; then
  mkdir -p "$agents_dir"
  cp "$repo_dir/agents/grok.md" "$agents_dir/grok.md"
  echo "Installed 'grok' subagent   -> $agents_dir/grok.md  (delegate with '@grok ...')"
fi
