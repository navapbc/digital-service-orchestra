# Security Audit (general-purpose fallback)

You are performing a security audit on the specified files. Your goal is to identify vulnerabilities, insecure patterns, and missing security controls, then provide actionable fixes.

## Audit Context

- **Target files**: `{target_files}`
- **Audit scope**: `{audit_scope}`
- **Additional context**: `{context}`

## Instructions

1. **Read each target file** listed in `{target_files}` and understand its role in the application.
2. **Analyze for common vulnerability classes** within `{audit_scope}`:
   - **Injection**: SQL injection, command injection, template injection, LDAP injection
   - **Authentication/Authorization**: Missing auth checks, privilege escalation, insecure token handling
   - **Data exposure**: Secrets in code, verbose error messages leaking internals, unmasked PII in logs
   - **Input validation**: Missing or insufficient validation, type confusion, path traversal
   - **Cryptography**: Weak algorithms, hardcoded keys, insufficient randomness
   - **Dependencies**: Known CVEs in imported packages
3. **For each finding, document**:
   - Severity: CRITICAL / HIGH / MEDIUM / LOW
   - Location: file path and line number
   - Description: what the vulnerability is
   - Impact: what an attacker could achieve
   - Fix: specific code change to remediate
4. **Apply fixes** for CRITICAL and HIGH severity findings immediately:
   - Use parameterized queries instead of string concatenation for SQL
   - Use `secrets.token_urlsafe()` instead of `random` for security tokens
   - Validate and sanitize all user inputs at the boundary
   - Remove hardcoded secrets and use environment variables via `PydanticBaseEnvConfig`
5. **For MEDIUM and LOW findings**, document them but do not fix unless explicitly requested — create tracking tickets instead.
6. **Run tests** to ensure fixes do not break functionality:
   ```bash
   cd "$REPO_ROOT/app" && make test-unit-only
   ```

## Audit Checklist

- [ ] No secrets or API keys hardcoded in source files
- [ ] All SQL queries use parameterized statements
- [ ] All user input is validated before use
- [ ] Error responses do not leak stack traces or internal paths
- [ ] Authentication is enforced on all non-public endpoints
- [ ] Sensitive data is not logged at INFO level or below
- [ ] File uploads validate content type and size

## Verify:

After applying security fixes, confirm no regressions:
```bash
cd "$REPO_ROOT/app" && make test-unit-only
```
All tests must pass. Additionally, re-audit the fixed code to confirm vulnerabilities are resolved.
