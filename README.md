# OpenFly

[![CI](https://github.com/farol-team/openfly/actions/workflows/ci.yml/badge.svg)](https://github.com/farol-team/openfly/actions/workflows/ci.yml)

A small, inspectable control plane for running agent tasks in isolated environments.
Built with Ruby on Rails, PostgreSQL and a Python runtime bridge.

**Experimental.** This is source code for self-hosted evaluation, not a hosted
service or a production security certification. The public release contains the
control plane, client libraries and synthetic tests. Application-specific
integrations, deployment credentials and internal infrastructure history are
not included.

## What it does

- Tenant-scoped sessions, immutable templates, quotas and idempotent operations.
- Leases and fencing: an execution with an unknown outcome is never automatically replayed.
- Streamed output, validated workspace archives, structured results and explicit acknowledgement.
- Independent maintenance, bounded cleanup retries and recovery artifacts.
- Observed runtime state, worker heartbeats, readiness and operator diagnostics.
- Ruby and JavaScript clients. CubeSandbox transport; Docker for development tests only.

An application keeps ownership of its agent, approvals and publication of results.
OpenFly allocates execution resources. A workspace checkpoint is not a VM memory
snapshot or a backup of a remote customer server.

## Run the tests

Requirements: Linux, Ruby 3.4, PostgreSQL 18, Python 3.12+, Node 22 and Docker
for the optional real-container test. PostgreSQL must accept the configured
local role. Tests refuse to run unless the database is named `execution_pool_test`.

```sh
bundle install
export DATABASE_URL=postgresql:///execution_pool_test
export SECRET_KEY_BASE="$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')"
export POOL_TOKEN_PEPPER="$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')"
RAILS_ENV=test bin/rails db:prepare
bin/rails test
python3 -m unittest discover -s test/runtime -p '*_test.py'
node --test test/client_test.mjs
```

For real guest execution, filesystem permissions, streaming and confirmed cleanup:

```sh
docker build -t openfly-runtime:test -f test/fixtures/Dockerfile .
POOL_DOCKER_INTEGRATION=1 bin/rails test
```

The Docker test is explicitly opt-in. It is not evidence of KVM isolation.
The CI workflow runs both contract tests and the Docker integration.

## Run the development API

Create a separate development database and configure the variables in
[.env.example](.env.example). Rails does not automatically source this file.
Generate fresh keys; do not reuse test credentials in a deployment.

```sh
RAILS_ENV=development bin/rails db:prepare
bin/rails server -b 127.0.0.1 -p 17440
# Separate terminals, with the same environment:
bin/pool-worker
bin/pool-maintenance
```

`GET /live` checks the API process. `GET /ready` checks dependencies and fresh
execution/maintenance heartbeats. Capacity is reported separately; a busy pool
is not an unhealthy API. `bin/pool-admin status` provides operator diagnostics.

For local Docker setup, set `POOL_ALLOW_DOCKER_TEST=1` and
`POOL_DEV_IMAGE=openfly-runtime:test`, then run
`bin/pool-admin dev-bootstrap /absolute/private/tokens.json` once, followed by
`bin/pool-dev-health` in another terminal. This creates two example tenants and
writes random credentials to a private file, never stdout. The historical example
tenant/template names are not live service endpoints.

See [OpenAPI](api/openapi.json), [API semantics](docs/api.md),
[security boundaries](SECURITY.md) and [contributing](CONTRIBUTING.md).

## Boundaries

CubeSandbox requires a separately admitted host and operator configuration.
Cluster management, CubeEgress credential injection and native cross-node VM
snapshots are not implemented in this release. Current secret bindings deliver
credentials into the guest; redaction is not a data-loss prevention system.

Use private routing and TLS at a trusted reverse proxy, request-size/rate limits,
dedicated service users, protected storage and tested backups. Public source does
not imply that exposing the API directly to the internet is safe.

MIT licensed. External dependencies retain their own licenses.
