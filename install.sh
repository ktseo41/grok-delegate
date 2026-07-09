#!/usr/bin/env bash
# Install the grok-delegate skill into a Claude Code skills directory.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest_root="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) dest_root="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [--dest DIR]
  --dest DIR   Skills directory to install into (default: \$CLAUDE_SKILLS_DIR or ~/.claude/skills)
Installs to <DIR>/grok-delegate.
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
