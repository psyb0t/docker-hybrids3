# Testing

- `make test` is what CI runs and must stay green. It builds the production image, runs `make test-unit` (pytest on `tests/test_lock_unit.py` in the dev container), then `./test.sh` with `TEST_PYTHON_IMAGE` set to the dev image. It needs Docker, curl and Bash on the host, no credentials and no network beyond image pulls.
- `test.sh` builds `psyb0t/hybrids3:latest-test`, starts it with the config written in `tests/common.sh` `setup()`, and reaches it by bridge IP. No host ports are published. The proxy tests in `tests/test_proxy.sh` start their own backend and nginx containers and remove them.
- Python inside the shell tests goes through the `py` helper in `tests/common.sh`, never a bare `python3`, so it runs in the dev image when `TEST_PYTHON_IMAGE` is set. The helper mounts the repository read-only at its host path, which `tests/test_lock.sh` needs to import `app/lock.py`.
- A new integration test is a `test_*` function in a `tests/test_*.sh` file followed by `ALL_TESTS+=(test_name)`. `test.sh` sources every `tests/test_*.sh`. Tests share one container, so use object keys unique to the test and delete what you create.
- Use the bucket names and placeholder keys from the test config (`public-bucket`/`pub-key`, `private-bucket`/`priv-key`, `expiring-bucket`, `tiny-bucket`, `test-master-key`). Never a real key.
- Lock timing tests depend on the test config values (`lock_acquire_timeout: 0.5`, `lock_hold_timeout: 2`, `lock_max_waiters: 15`). Change them together.
- Auth, presign, path prefix and MCP changes need a test for each interface they touch: HTTP in `test_http.sh`/`test_auth.sh`, S3 in `test_s3.sh`, MCP in `test_mcp.sh`, prefix in `test_proxy.sh`, attacks in `test_security.sh`.
- Lint (`make lint`) is part of done. Do not weaken it with `|| true`, broad `noqa` or new mypy ignores.
