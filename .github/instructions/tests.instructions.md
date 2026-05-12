---
applyTo: "tests/**"
---

# Test Coverage Requirements

Coverage areas for tests:

- Tests exercise observable behavior of new code paths.
- Edge-case and error-path coverage.
- Test isolation — no cross-test state, no order dependency.
- Mock scope — mocks target dependencies, not the system under test.
