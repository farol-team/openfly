# Contributing

Run the tests in README before opening a pull request. Keep changes focused and
include a regression test when fixing lifecycle or security behavior. Never use
customer credentials or real servers in tests.

Changes must preserve tenant ownership, idempotency, fencing, explicit result
acknowledgement and confirmed cleanup. A transport timeout is not proof that a
command did not execute. Provider error messages must not disclose credentials.

Security reports belong in private vulnerability reporting, not public issues.
CI uses read-only repository permissions and does not run pull-request code with
deployment secrets. Contributions are submitted under the repository MIT license.
