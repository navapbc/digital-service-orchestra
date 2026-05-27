#!/usr/bin/env bash
# Canonical UI-file detection gate for the visual evaluator pipeline.
# Accepts file paths on stdin (one per line) or as arguments.
# Exit 0 = UI files present; Exit 1 = no UI files found.

set -euo pipefail

UI_EXTENSIONS="css|scss|sass|less|js|ts|tsx|jsx|html|jinja|jinja2|svelte|vue"
UI_DIRECTORIES="components/|templates/|static/|frontend/|ui/|styles/|layouts/|pages/"

match_ui_file() {
  local file="$1"
  if [[ "$file" =~ \.($UI_EXTENSIONS)$ ]]; then
    return 0
  fi
  if [[ "$file" =~ ($UI_DIRECTORIES) ]]; then
    return 0
  fi
  return 1
}

files=()
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  while IFS= read -r line; do
    [[ -n "$line" ]] && files+=("$line")
  done
fi

if [[ ${#files[@]} -eq 0 ]]; then
  exit 1
fi

for f in "${files[@]}"; do
  if match_ui_file "$f"; then
    exit 0
  fi
done

exit 1
