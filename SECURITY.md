# Security

OpenFly is experimental infrastructure for trusted operators. No production
security audit or isolation certification is claimed.

Report vulnerabilities through GitHub private vulnerability reporting for this
repository. Do not post credentials, exploit details or customer data in public
issues. There is no guaranteed response SLA.

## Trust boundaries

- The API and PostgreSQL are trusted control-plane components. Service tokens
  select tenants; operators need a separate explicit scope.
- User argv executes only in the guest. Docker is a development backend and is
  rejected in production; it is not a microVM isolation guarantee.
- Template definitions, node configuration, runtime credentials and admission
  records are operator-owned. Provider admission is not automatically certified.
- Secrets live in private tmpfs and are consumed once. A permitted guest can copy
  or transform a credential. Output redaction cannot prevent all exfiltration.
- Unknown execution outcomes require reconciliation. Never blindly replay a
  command that may have modified an external system.
- Resource reservations remain held until cleanup is confirmed. Recovery data
  and unacknowledged results may be retained indefinitely and need operator review.
- Native VM snapshots, cross-node recovery and egress credential injection are
  not implemented. Archive validation is not a substitute for application review.

Deploy behind TLS and private routing; enforce request size/rate limits. Protect
PostgreSQL, blob storage, token pepper and provider configuration. Test backup and
restore. Do not run acceptance tests against a production database.

## Release checks

The initial public snapshot excludes private configuration, internal reports,
application adapters and internal Git history. Tests cover tenant boundaries,
revocation, secret handling, fencing, crash recovery, archive traversal and real
Docker execution. Gitleaks, Brakeman and bundler-audit are useful automated checks,
not proof that no vulnerability exists. Dependency advisories change over time.
