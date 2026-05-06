---
name: interface-contracts
description: Use when planning a feature where multiple components implement the same boundary, work can be parallelized across agents, or several tasks are blocked by a shared dependency. Defines an abstract base class or Protocol with @abstractmethod decorators, complete type hints, behavior-documenting docstrings, and contract tests; sets up the interface task plus per-implementation tasks with depends_on links so multiple agents can work in parallel. Trigger phrases include 'interface contract', 'parallel implementation', 'shared boundary', 'multi-agent coordination', 'contract-first', 'unblock parallel work', 'define an ABC', 'set up a Protocol'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Interface Contracts for Parallel Development

When planning new features or tasks, **proactively identify interface boundaries** that enable parallel development between agents. Formal interface contracts allow multiple agents to work simultaneously on different components that will integrate together.


## When to Create an Interface Contract

```
Create interface contract if ANY:
  - Multiple components need to communicate? → Yes
  - Work can be parallelized across agents? → Yes
  - 3+ tasks blocked by same dependency? → Yes
Otherwise: No interface needed
```

## Interface Contract Requirements

Every interface contract must include:

1. **Abstract base class or Protocol** with `@abstractmethod` decorators
2. **Complete type hints** for all parameters and return values
3. **Comprehensive docstrings** documenting behavior, not just structure
4. **Unit test file** with tests that verify the contract (can test against mock/stub implementations)

### Example from This Codebase

```python
# src/services/extraction/base.py
from abc import ABC, abstractmethod

class ExtractionProvider(ABC):
    """Contract for document extraction providers.

    Implementations must handle PDF, DOCX, and TXT formats.
    All methods are thread-safe and may be called concurrently.
    """

    @abstractmethod
    def extract_text(self, file_path: str) -> ExtractionResult:
        """Extract text content from a document.

        Args:
            file_path: Absolute path to the document file.

        Returns:
            ExtractionResult containing:
            - text: The extracted text content
            - metadata: Document metadata dict
            - page_count: Number of pages (1 for non-paginated)

        Raises:
            FileNotFoundError: If file_path does not exist
            UnsupportedFormatError: If file format is not supported
            ExtractionError: If extraction fails for other reasons

        Thread Safety:
            This method is thread-safe and may be called concurrently.
        """
        pass
```

## Parallel Work Pattern

```
Pattern: Main Agent → Create interface contract (ABC, tests, docs)
         → Interface complete
         → [parallel] Impl Agent 1: Provider A | Impl Agent 2: Provider B
         → Both complete → Integration ready
```

## Task Setup

```bash
# 1. Create interface task (unblocks others)
.claude/scripts/dso ticket create task "Define MyProvider interface contract" --priority 1 -d "Define the abstract base class for MyProvider: method signatures, expected behavior, error contracts."
# Returns: <issue-id>

# 2. Create implementation tasks
.claude/scripts/dso ticket create task "Implement ConcreteProviderA" --priority 2 -d "Implement MyProvider interface for ConcreteProviderA. Must satisfy all contracts from <issue-id>."
.claude/scripts/dso ticket create task "Implement ConcreteProviderB" --priority 2 -d "Implement MyProvider interface for ConcreteProviderB. Must satisfy all contracts from <issue-id>."
# Returns: <issue-id-a>, <issue-id-b>

# 3. Set dependencies
.claude/scripts/dso ticket link <issue-id-a> <issue-id> depends_on
.claude/scripts/dso ticket link <issue-id-b> <issue-id> depends_on

# 4. Document interface after completion
.claude/scripts/dso ticket comment <issue-id> "Interface: src/services/domain/base.py
Key methods: process(), validate()
Constraint: All implementations thread-safe"
```

### Documenting Interface Contracts for Other Agents

When you complete an interface contract task, ensure:

1. **The interface file exists** with all abstract methods decorated
2. **Tests exist** that verify the contract (even if they test stubs)
3. **The ticket issue notes** include:
   - Path to the interface file
   - Key methods and their purposes
   - Any non-obvious constraints or invariants

## Checklist

Before marking an interface contract task complete:

- [ ] ABC/Protocol with `@abstractmethod` decorators
- [ ] Complete type hints on all methods
- [ ] Docstrings document behavior + exceptions + thread safety
- [ ] Test file with contract verification tests
- [ ] Lint (type-check) passes: `LINT_CMD=$(.claude/scripts/dso read-config commands.lint) && $LINT_CMD`
- [ ] Ticket notes include file path and constraints

## Common Pitfalls

| Pitfall | Problem | Solution |
|---------|---------|----------|
| Forgetting `@abstractmethod` | Subclasses can skip implementation | Always decorate abstract methods |
| Missing return type hints | MyPy can't verify implementations match | Use `-> ReturnType` on all methods |
| No docstring on abstract method | Contract is unclear to implementers | Document expected behavior fully |
| Not running mypy after changes | Type errors slip through to CI | Run `LINT_CMD=$(.claude/scripts/dso read-config commands.lint) && $LINT_CMD` after changes |

## Workflow Summary

```bash
# 1. Create the abstract base class with @abstractmethod decorators
# 2. Write comprehensive docstrings
# 3. Create concrete implementation(s)
# 4. Write tests for base class and implementations
# 5. Run type checking - REQUIRED
LINT_CMD=$(.claude/scripts/dso read-config commands.lint) && $LINT_CMD  # Must pass

# 6. Run validation
.claude/scripts/dso validate.sh --ci

# 7. Commit using the project commit workflow (CLAUDE.md rule 13)
# Use /dso:commit or follow COMMIT-WORKFLOW.md — never raw git commit
```
