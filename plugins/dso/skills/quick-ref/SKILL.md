---
name: quick-ref
description: Auto-discover and display all plugin scripts and skills available in this workflow plugin.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Quick Reference: Plugin Scripts & Skills

Auto-discovers all available scripts and skills in the workflow plugin at invocation time. No hardcoded lists — everything is resolved dynamically.

## Usage

```
/dso:quick-ref              # Show all scripts and skills
/dso:quick-ref scripts      # Show only scripts
/dso:quick-ref skills       # Show only skills
```

## Execution

### Step 1: Resolve Plugin Root

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
```

### Step 2: Discover Plugin Scripts

List all `.sh` files in the plugin `scripts/` directory and extract the first comment line (after the shebang and filename comment) as a description.

```bash
scripts_dir="${PLUGIN_ROOT}/scripts"
for script in "$scripts_dir"/*.sh; do
  name="$(basename "$script")"
  # Extract the description: second comment line (first after #!/... line)
  desc="$(sed -n '2s/^# *//p' "$script")"
  # If line 2 is a filename echo, try line 3
  if [[ "$desc" == *"$name"* ]] || [[ -z "$desc" ]]; then
    desc="$(sed -n '3s/^# *//p' "$script")"
  fi
  echo "| $name | $desc |"
done
```

Present the results as a markdown table:

| Script | Description |
|--------|-------------|
| *(auto-discovered at invocation time)* | *(first comment line)* |

### Step 3: Discover Skills

List all skills by scanning for `SKILL.md` files under the plugin `skills/` directory.

```bash
skills_dir="${PLUGIN_ROOT}/skills"
for skill_file in "$skills_dir"/*/SKILL.md; do
  skill_dir="$(dirname "$skill_file")"
  skill_name="$(basename "$skill_dir")"
  # Extract description from YAML frontmatter
  desc="$(sed -n '/^description:/s/^description: *//p' "$skill_file")"
  # Check if user-invocable
  invocable="$(sed -n '/^user-invocable:/s/^user-invocable: *//p' "$skill_file")"
  echo "| /$skill_name | $desc | $invocable |"
done
```

Present the results as a markdown table:

| Skill | Description | User-Invocable |
|-------|-------------|----------------|
| *(auto-discovered at invocation time)* | *(from frontmatter)* | *(true/false)* |

### Step 4: Output

Combine the two tables with section headers and present to the user. If the user passed `scripts` or `skills` as an argument, show only the relevant section.
