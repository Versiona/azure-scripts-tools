# Tests

Unit and integration tests for the scripts in this repository.
All tests run **without** an Azure login or any Azure resources.

## Requirements

| Tool | Purpose |
|------|---------|
| `bash` | Test runner |
| `jq` | Used by `test_unit_functions.sh` |

## Running all tests

From the repo root:

```bash
bash tests/run_tests.sh
```

Or from inside the `tests/` folder:

```bash
bash run_tests.sh
```

Exit code is `0` if all suites pass, `1` if any fail.

## Test files

| File | What it tests |
|------|--------------|
| `test_help_and_args.sh` | `--help` / `-h` output, unknown flag handling, and `bash -n` syntax check |
| `test_unit_functions.sh` | Pure bash/jq helper functions: `parse_sql_version_from_offer`, `normalize_la_output`, `load_subscriptions_file`, license field |
| `test_helper.sh` | Shared assertion helpers (`assert_eq`, `assert_contains`, `assert_exit_zero`, `suite`, `summary`) — not a test suite itself |

## Example output

```
══ test_help_and_args.sh ══
  ✓ -h shows version
  ✓ -h shows -s flag
  ...

══ test_unit_functions.sh ══
  ✓ SQL2019-WS2019 → 2019
  ✓ flat array passes through unchanged
  ...

All test suites passed.
```
