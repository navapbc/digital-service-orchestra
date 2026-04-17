init

## Optional Dependencies

### ast-grep (structural code search)

[ast-grep](https://ast-grep.github.io/) provides syntax-aware structural pattern matching for code search. DSO skills use it for cross-file dependency discovery during planning, investigation, and batch overlap analysis. All workflows gracefully fall back to grep when ast-grep is not installed.

> **Note**: Full setup steps live in [INSTALL.md](./INSTALL.md).

**Install**:
- macOS: `brew install ast-grep`
- Linux: `cargo install ast-grep --locked`

The CLI binary is `sg`. Verify installation: `sg --version`
