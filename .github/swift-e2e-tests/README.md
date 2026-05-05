# Swift E2E Test Fixtures

Fixtures for the `swift-e2e-tests` workflow live here.

`swift/Scripts/TestE2E.sh` exposes this directory to the Swift test process as
`WENDY_AGENT_E2E_FIXTURES_DIR` so tests can use stable, checked-in fixture data
without mixing it with the hardware integration fixtures in `.github/ci-tests/`.
