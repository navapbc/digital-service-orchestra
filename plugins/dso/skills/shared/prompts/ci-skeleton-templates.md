# CI Skeleton Templates (Per-Stack)

Self-contained GitHub Actions setup blocks. Load this prompt only when the architect-foundation skill (or another skill) is generating CI configuration.

**Rules:**

1. Include only the block(s) whose dependency files exist in the target project.
2. Each block is structurally isolated — own `if:` conditional, never interleaved with other ecosystems.
3. All `hashFiles()` paths are root-relative (no leading `./` or `/`).

## Python

```yaml
- name: Set up Python
  if: hashFiles('requirements.txt') != '' || hashFiles('pyproject.toml') != ''
  uses: actions/setup-python@v5
  with:
    python-version: '3.x'
```

## Node

```yaml
- name: Set up Node
  if: hashFiles('package-lock.json') != '' || hashFiles('yarn.lock') != ''
  uses: actions/setup-node@v4
```

## Ruby

```yaml
- name: Set up Ruby
  if: hashFiles('Gemfile.lock') != '' || hashFiles('Gemfile') != ''
  uses: ruby/setup-ruby@v1
```

<!-- Epic F: append Java block here -->
