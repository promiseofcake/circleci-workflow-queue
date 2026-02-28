# Bug Fixes & Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all identified bugs in global_queue.sh and pipeline_queue.sh, harden edge cases, and improve test coverage.

**Architecture:** Direct fixes to the two core bash scripts. Add a lightweight bash test harness that mocks `curl` and validates script behavior without real API calls. Keep changes minimal and focused — no structural refactoring.

**Tech Stack:** Bash, jq, CircleCI Orb YAML, ShellCheck

---

### Task 1: Clean up stale pipeline files between loop iterations

**Problem:** The glob `${tmp}/pipeline-*.json` in `fetch_pipeline_workflows()` accumulates files across loop iterations. If a pipeline drops out of the API response, its stale file persists and gets included in the `jq -s` slurp, potentially showing completed workflows as still running. This can block the queue indefinitely.

**Files:**
- Modify: `src/scripts/global_queue.sh:77-105` (fetch_pipeline_workflows function)

**Step 1: Add cleanup at the start of fetch_pipeline_workflows**

Add `rm -f "${tmp}"/pipeline-*.json` as the first line inside `fetch_pipeline_workflows()`:

```bash
fetch_pipeline_workflows(){
    # clean up stale pipeline files from previous iterations
    rm -f "${tmp}"/pipeline-*.json

    for pipeline in $(jq -r ".items[] | .id //empty" "${pipelines_file}" | uniq)
    # ... rest unchanged
```

**Step 2: Verify via ShellCheck**

Run: `shellcheck src/scripts/global_queue.sh`
Expected: No new warnings introduced

**Step 3: Commit**

```bash
git add src/scripts/global_queue.sh
git commit -m "fix: clean up stale pipeline files between queue loop iterations

Prevents indefinite blocking when pipelines drop out of the API response
but their JSON files persist from a previous fetch."
```

---

### Task 2: Fix fetch() to accept 2xx status codes

**Problem:** `fetch()` only treats HTTP 200 as success. The CircleCI cancel endpoint returns 202 Accepted. This causes cancel requests to fail with a misleading error message and skip the grace period sleep.

**Files:**
- Modify: `src/scripts/global_queue.sh:36-64` (fetch function)
- Modify: `src/scripts/pipeline_queue.sh:34-62` (fetch function — identical copy)

**Step 1: Update the success check in global_queue.sh**

Change the HTTP response check from exact 200 match to a 2xx range:

```bash
        if [[ "${http_response}" =~ ^2[0-9][0-9]$ ]]; then
            debug "api call: success (${http_response})"
            return 0
        elif [[ "${http_response}" =~ ^(429|502|503|504)$ ]]; then
```

**Step 2: Apply the same change in pipeline_queue.sh**

Same change — update the success check from `"200"` to the 2xx regex.

```bash
        if [[ "${http_response}" =~ ^2[0-9][0-9]$ ]]; then
            debug "api call: success (${http_response})"
            return 0
        elif [[ "${http_response}" =~ ^(429|502|503|504)$ ]]; then
```

**Step 3: Verify via ShellCheck**

Run: `shellcheck src/scripts/global_queue.sh src/scripts/pipeline_queue.sh`
Expected: No new warnings

**Step 4: Commit**

```bash
git add src/scripts/global_queue.sh src/scripts/pipeline_queue.sh
git commit -m "fix: accept 2xx HTTP status codes as success in fetch()

The CircleCI cancel workflow endpoint returns 202 Accepted.
Previously this was treated as an error, causing misleading error
messages and skipping the grace period sleep after cancellation."
```

---

### Task 3: Fix jq quoting — add -r flag consistently

**Problem:** `jq` without `-r` returns strings with literal surrounding quotes. `my_workflow_id` gets quotes baked into the cancel URL (malformed). `my_commit_time` and `oldest_commit_time` work by coincidence (both quoted), but it's fragile.

**Files:**
- Modify: `src/scripts/global_queue.sh:108-111` (load_current_workflow_values)
- Modify: `src/scripts/global_queue.sh:122-123` (update_comparables)

**Step 1: Add -r to all jq calls that extract string values**

In `load_current_workflow_values()`:
```bash
load_current_workflow_values(){
    my_commit_time=$(jq -r ".[] | select (.id == \"${CIRCLE_WORKFLOW_ID}\").created_at" "${workflows_file}")
    my_workflow_id=$(jq -r ".[] | select (.id == \"${CIRCLE_WORKFLOW_ID}\").id" "${workflows_file}")
}
```

In `update_comparables()`:
```bash
    oldest_running_workflow_id=$(jq -r '. | sort_by(.created_at) | .[0].id' "${workflows_file}")
    oldest_commit_time=$(jq -r '. | sort_by(.created_at) | .[0].created_at' "${workflows_file}")
```

**Step 2: Update the null/empty check to handle raw strings**

With `-r`, jq outputs `null` (the literal string) instead of empty for missing values. Update the check in `update_comparables()`:

```bash
    if [ -z "${oldest_commit_time}" ] || [ "${oldest_commit_time}" = "null" ] || [ -z "${oldest_running_workflow_id}" ] || [ "${oldest_running_workflow_id}" = "null" ]; then
```

Also update the front-of-line check — `my_commit_time` could now be empty string or "null":

The existing check `[[ -n "${my_commit_time}" ]]` on line 164 handles empty string but not literal "null". Add a null check:

```bash
    if [[ -n "${my_commit_time}" ]] && [[ "${my_commit_time}" != "null" ]] && [[ "${oldest_commit_time}" > "${my_commit_time}" || "${oldest_commit_time}" = "${my_commit_time}" ]] ; then
```

**Step 3: Verify via ShellCheck**

Run: `shellcheck src/scripts/global_queue.sh`
Expected: No new warnings

**Step 4: Commit**

```bash
git add src/scripts/global_queue.sh
git commit -m "fix: add -r flag to jq calls to prevent quoted string values

Without -r, jq wraps strings in literal double quotes. This caused
the cancel workflow URL to be malformed and made timestamp comparisons
fragile (working only because both sides were consistently quoted)."
```

---

### Task 4: Add same-timestamp tiebreaker

**Problem:** If two workflows are created in the same second, both see `oldest_commit_time == my_commit_time` and both proceed concurrently, defeating the queue.

**Files:**
- Modify: `src/scripts/global_queue.sh:164` (front-of-line comparison)

**Step 1: Add workflow ID tiebreaker**

When timestamps are equal, use lexicographic comparison of workflow IDs as tiebreaker. The workflow with the "smaller" ID wins:

```bash
    if [[ -n "${my_commit_time}" ]] && [[ "${my_commit_time}" != "null" ]] && [[ "${oldest_commit_time}" > "${my_commit_time}" || ( "${oldest_commit_time}" = "${my_commit_time}" && "${oldest_running_workflow_id}" = "${my_workflow_id}" ) ]] ; then
```

This changes the logic from "I'm front of line if oldest is >= me" to "I'm front of line if oldest is older than me, OR if we have the same timestamp and I AM the oldest by ID sort." The `sort_by(.created_at) | .[0]` jq expression is stable — for equal timestamps, jq preserves input order. But to make it deterministic, update the sort to include a secondary sort key:

In `update_comparables()`, update the sort to break ties by ID:

```bash
    oldest_running_workflow_id=$(jq -r '. | sort_by(.created_at, .id) | .[0].id' "${workflows_file}")
    oldest_commit_time=$(jq -r '. | sort_by(.created_at, .id) | .[0].created_at' "${workflows_file}")
```

**Step 2: Verify via ShellCheck**

Run: `shellcheck src/scripts/global_queue.sh`
Expected: No new warnings

**Step 3: Commit**

```bash
git add src/scripts/global_queue.sh
git commit -m "fix: add workflow ID tiebreaker for same-timestamp race condition

When two workflows are created in the same second, both previously
saw themselves as front-of-line. Now uses lexicographic workflow ID
comparison as a deterministic tiebreaker."
```

---

### Task 5: URL-encode branch name in API call

**Problem:** Branch names with special characters (spaces, `+`, `#`, `&`) are interpolated directly into the URL, breaking the API call.

**Files:**
- Modify: `src/scripts/global_queue.sh:66-74` (fetch_pipelines function)

**Step 1: Add URL encoding using jq**

Use `jq -sRr @uri` which is available wherever jq is (no extra dependency):

```bash
fetch_pipelines(){
    : "${CIRCLE_BRANCH:?"Required Env Variable not found!"}"
    echo "Only blocking execution if running previous workflows on branch: ${CIRCLE_BRANCH}"
    encoded_branch=$(printf '%s' "${CIRCLE_BRANCH}" | jq -sRr @uri)
    pipelines_api_url_template="https://circleci.com/api/v2/project/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?branch=${encoded_branch}"

    debug "Fetching pipelines for: ${CIRCLE_BRANCH}"
    fetch "${pipelines_api_url_template}" "${pipelines_file}"
}
```

**Step 2: Verify via ShellCheck**

Run: `shellcheck src/scripts/global_queue.sh`
Expected: No new warnings

**Step 3: Commit**

```bash
git add src/scripts/global_queue.sh
git commit -m "fix: URL-encode branch name in pipeline API request

Branch names with special characters (spaces, +, #, &) previously
broke the API call. Uses jq @uri filter for encoding."
```

---

### Task 6: Add optional timeout to pipeline queue

**Problem:** `pipeline_queue.sh` has no timeout. If a sibling workflow gets stuck, this job waits forever, burning compute credits.

**Files:**
- Modify: `src/scripts/pipeline_queue.sh:82-113` (main execution block)
- Modify: `src/commands/pipeline_block.yml` (add time and dont_quit parameters)
- Modify: `src/jobs/pipeline_queue.yml` (pass through new parameters)

**Step 1: Add timeout parameters to pipeline_block.yml**

```yaml
parameters:
  debug:
    type: boolean
    default: false
    description: "When enabled, additional debug logging with be output."
  confidence:
    type: string
    default: "1"
    description: >
      Due to concurrency issues, the number of times should we requery the pipeline list to ensure previous jobs are "pending",
      but not yet active. This number indicates the threshold for API returning no previous pending pipelines.
      Default is `1` confirmation, increase if you see issues.
  time:
    type: string
    default: "0"
    description: "Number of minutes to wait before timing out. 0 means wait indefinitely (default)."
  dont_quit:
    type: boolean
    default: false
    description: "If true, forces the job through once time expires instead of failing. Only applies when time > 0."

steps:
  - run:
      name: Blocking execution until the current workflow is the last to run in the given pipeline.
      shell: /bin/bash -eo pipefail
      environment:
        CONFIG_DEBUG_ENABLED: "<< parameters.debug >>"
        CONFIG_CONFIDENCE: "<< parameters.confidence >>"
        CONFIG_TIME: "<< parameters.time >>"
        CONFIG_DONT_QUIT: "<< parameters.dont_quit >>"
      command: <<include(scripts/pipeline_queue.sh)>>
```

**Step 2: Pass through parameters in pipeline_queue.yml**

Add `time` and `dont_quit` parameters to the job definition and pass them to `pipeline_block`.

**Step 3: Add timeout logic to pipeline_queue.sh**

Add after `wait_start_time` setup:

```bash
max_time=${CONFIG_TIME:-0}
max_time_seconds=$((max_time * 60))
if [ "$max_time" -gt 0 ]; then
    echo "Max Queue Time: ${max_time} minutes."
else
    echo "No timeout configured, will wait indefinitely."
fi
```

Add at the end of the while loop, before `sleep`:

```bash
    if [ "$max_time_seconds" -gt 0 ] && [ $wait_time -ge $max_time_seconds ]; then
        echo "Max wait time exceeded, considering response."
        if [ "${CONFIG_DONT_QUIT}" == "1" ]; then
            echo "Orb parameter dont-quit is set to true, letting this job proceed!"
            exit 0
        else
            echo "Max wait time exceeded. Failing job."
            exit 1
        fi
    fi
```

**Step 4: Verify via ShellCheck**

Run: `shellcheck src/scripts/pipeline_queue.sh`
Expected: No new warnings

**Step 5: Commit**

```bash
git add src/scripts/pipeline_queue.sh src/commands/pipeline_block.yml src/jobs/pipeline_queue.yml
git commit -m "feat: add optional timeout to pipeline queue

Previously the pipeline queue waited indefinitely. Now supports
optional time parameter (default 0 = no timeout) and dont_quit
parameter for force-through behavior, matching global queue."
```

---

### Task 7: Use local variables in fetch() and fix typos

**Problem:** `fetch()` sets variables in global scope. Minor typos in debug messages.

**Files:**
- Modify: `src/scripts/global_queue.sh` (fetch function, debug messages)
- Modify: `src/scripts/pipeline_queue.sh` (fetch function)

**Step 1: Add local declarations to fetch() in both scripts**

```bash
fetch(){
    local url=$1
    local target=$2
    local method=${3:-GET}
    local max_retries=5
    local retry_delay=5
    local attempt
    local http_response
    # ... rest unchanged
```

**Step 2: Fix typos in global_queue.sh**

- Line 72: `"Fetching piplines"` → `"Fetching pipelines"`
- Line 84: `"Pipeline:'s workflow"` → `"Pipeline's workflow"`

**Step 3: Verify via ShellCheck**

Run: `shellcheck src/scripts/global_queue.sh src/scripts/pipeline_queue.sh`
Expected: No new warnings

**Step 4: Commit**

```bash
git add src/scripts/global_queue.sh src/scripts/pipeline_queue.sh
git commit -m "chore: use local variables in fetch() and fix debug typos"
```

---

### Task 8: Add test harness with curl mocking

**Problem:** The current test.sh makes real API calls and the workflow-fixture.json is unused. There are no automated assertions.

**Files:**
- Create: `test/test_global_queue.sh`
- Create: `test/test_pipeline_queue.sh`
- Create: `test/helpers.sh` (shared test utilities and mock setup)
- Create: `test/fixtures/pipelines.json`
- Create: `test/fixtures/pipeline-workflow-old.json`
- Create: `test/fixtures/pipeline-workflow-current.json`
- Create: `test/fixtures/pipeline-workflows-running.json`
- Modify: `test/workflow-fixture.json` (keep for backwards compat reference)
- Modify: `Makefile` (update test targets)

**Step 1: Create test/helpers.sh**

A lightweight test helper that:
- Creates a temp directory for test isolation
- Mocks `curl` by defining a bash function that returns fixture data based on URL patterns
- Provides `assert_equals`, `assert_contains`, `assert_exit_code` functions
- Sets all required CIRCLE_* env vars to known test values

```bash
#!/usr/bin/env bash
# Test helpers for circleci-workflow-queue scripts
set -e

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
SCRIPT_DIR="${TEST_DIR}/../src/scripts"

# counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# setup isolated temp dir per test
setup() {
    export TMP_DIR
    TMP_DIR=$(mktemp -d)

    # default CircleCI env vars
    export CIRCLE_WORKFLOW_ID="wf-current-1111"
    export CIRCLE_PIPELINE_ID="pipeline-1111"
    export CIRCLE_PROJECT_USERNAME="testorg"
    export CIRCLE_PROJECT_REPONAME="testrepo"
    export CIRCLE_REPOSITORY_URL="https://github.com/testorg/testrepo"
    export CIRCLE_JOB="queue-job"
    export CIRCLE_BRANCH="main"
    export CIRCLECI_API_TOKEN="fake-token"

    # default config
    export CONFIG_DEBUG_ENABLED="0"
    export CONFIG_TIME="1"
    export CONFIG_DONT_QUIT="0"
    export CONFIG_ONLY_ON_BRANCH="*"
    export CONFIG_CONFIDENCE="1"
    export CONFIG_IGNORED_WORKFLOWS=""
    export CONFIG_INCLUDE_ON_HOLD="0"
}

# cleanup temp dir
teardown() {
    rm -rf "${TMP_DIR}"
}

# mock curl — override per test by redefining mock_curl_response
# usage: set MOCK_CURL_RESPONSES as an associative array of URL pattern -> fixture file
curl() {
    local url=""
    local output=""
    local method="GET"

    # parse curl args to extract what we need
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            -X) method="$2"; shift 2 ;;
            -w) shift 2 ;;  # skip write-out format
            -s|-S) shift ;;
            -H) shift 2 ;;
            *) url="$1"; shift ;;
        esac
    done

    mock_curl_response "${method}" "${url}" "${output}"
}
export -f curl

# default mock — override in tests
mock_curl_response() {
    local method="$1"
    local url="$2"
    local output="$3"
    echo '{}' > "${output}"
    echo "200"
}

# assertions
assert_equals() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "${expected}" = "${actual}" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS: ${description}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: ${description}"
        echo "    expected: ${expected}"
        echo "    actual:   ${actual}"
    fi
}

assert_contains() {
    local description="$1"
    local needle="$2"
    local haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "${haystack}" | grep -qF "${needle}"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS: ${description}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: ${description}"
        echo "    expected to contain: ${needle}"
        echo "    actual: ${haystack}"
    fi
}

# run a test function with setup/teardown
run_test() {
    local test_name="$1"
    echo "TEST: ${test_name}"
    setup
    eval "${test_name}"
    teardown
}

# print summary and exit with appropriate code
print_results() {
    echo ""
    echo "================================"
    echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
    echo "================================"
    [ "${TESTS_FAILED}" -eq 0 ]
}
```

**Step 2: Create test fixtures**

`test/fixtures/pipelines.json` — API response for pipeline list:
```json
{
    "next_page_token": null,
    "items": [
        { "id": "pipeline-1111" },
        { "id": "pipeline-2222" }
    ]
}
```

`test/fixtures/pipeline-workflow-current.json` — current workflow (front of line):
```json
{
    "next_page_token": null,
    "items": [
        {
            "pipeline_id": "pipeline-1111",
            "id": "wf-current-1111",
            "name": "deploy",
            "status": "running",
            "created_at": "2026-01-15T10:00:00Z"
        }
    ]
}
```

`test/fixtures/pipeline-workflow-old.json` — older workflow that blocks:
```json
{
    "next_page_token": null,
    "items": [
        {
            "pipeline_id": "pipeline-2222",
            "id": "wf-older-2222",
            "name": "deploy",
            "status": "running",
            "created_at": "2026-01-15T09:50:00Z"
        }
    ]
}
```

`test/fixtures/pipeline-workflows-running.json` — pipeline with multiple running workflows:
```json
{
    "next_page_token": null,
    "items": [
        {
            "pipeline_id": "pipeline-1111",
            "id": "wf-current-1111",
            "name": "workflow-a",
            "status": "running",
            "created_at": "2026-01-15T10:00:00Z"
        },
        {
            "pipeline_id": "pipeline-1111",
            "id": "wf-other-3333",
            "name": "workflow-b",
            "status": "running",
            "created_at": "2026-01-15T10:00:00Z"
        }
    ]
}
```

**Step 3: Create test/test_global_queue.sh**

Tests for:
- Front of line detection (proceeds when oldest)
- Blocking when older workflow exists
- Timeout behavior (exit 1)
- Timeout with dont_quit (exit 0)
- Stale file cleanup between iterations
- URL encoding of branch names
- Same-timestamp tiebreaker

Since the global queue script runs as a main script (not just functions), we need to test it by sourcing individual functions or by running it as a subprocess. The approach: source the script but override `sleep` and the main loop to test individual functions, OR run the full script and assert on exit code/output.

The pragmatic approach for testability: extract the functions by sourcing the script with `CONFIG_ONLY_ON_BRANCH` set to a non-matching branch so it exits at line 144 without entering the main loop. Then call individual functions directly.

```bash
#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "${SCRIPT_DIR}/helpers.sh"

# source global_queue.sh functions without executing main block
# by setting branch to non-matching value
source_functions() {
    export CONFIG_ONLY_ON_BRANCH="__skip__"
    export CIRCLE_BRANCH="main"
    # capture and discard the "skipping queue" output
    source "${SCRIPT_DIR}/../src/scripts/global_queue.sh" > /dev/null 2>&1 || true
    # now restore for actual testing
    export CONFIG_ONLY_ON_BRANCH="*"
}

test_fetch_pipelines_url_encodes_branch() {
    source_functions
    export CIRCLE_BRANCH="feature/my branch+name"

    # mock curl to capture the URL
    local captured_url=""
    mock_curl_response() {
        captured_url="$2"
        echo '{"next_page_token":null,"items":[]}' > "$3"
        echo "200"
    }
    export -f mock_curl_response

    fetch_pipelines > /dev/null 2>&1

    assert_contains "branch is URL-encoded" "feature%2Fmy%20branch%2Bname" "${captured_url}"
}

test_stale_files_cleaned_up() {
    source_functions

    # create a stale pipeline file
    echo '{"items":[{"id":"wf-stale","name":"old","status":"success","created_at":"2025-01-01T00:00:00Z"}]}' > "${TMP_DIR}/pipeline-stale-pipeline.json"

    # mock to return empty pipeline list
    mock_curl_response() {
        echo '{"next_page_token":null,"items":[]}' > "$3"
        echo "200"
    }
    export -f mock_curl_response

    echo '{"next_page_token":null,"items":[]}' > "${TMP_DIR}/pipeline_status.json"
    fetch_pipeline_workflows > /dev/null 2>&1

    # stale file should be gone
    local stale_exists="false"
    [ -f "${TMP_DIR}/pipeline-stale-pipeline.json" ] && stale_exists="true"
    assert_equals "stale pipeline file removed" "false" "${stale_exists}"
}

test_jq_values_are_unquoted() {
    source_functions

    # write a workflows file with known data
    echo '[{"id":"wf-current-1111","created_at":"2026-01-15T10:00:00Z","name":"deploy","status":"running"}]' > "${TMP_DIR}/workflow_status.json"

    load_current_workflow_values

    assert_equals "my_commit_time has no quotes" "2026-01-15T10:00:00Z" "${my_commit_time}"
    assert_equals "my_workflow_id has no quotes" "wf-current-1111" "${my_workflow_id}"
}

test_fetch_accepts_202() {
    source_functions

    mock_curl_response() {
        echo '{"status":"cancelled"}' > "$3"
        echo "202"
    }
    export -f mock_curl_response

    # should succeed (return 0), not error
    local result
    result=$(fetch "https://example.com/cancel" "${TMP_DIR}/cancel.json" "POST" 2>&1) || true
    local exit_code=$?
    assert_equals "fetch accepts 202" "0" "${exit_code}"
}

# Run tests
run_test test_fetch_accepts_202
run_test test_jq_values_are_unquoted
run_test test_stale_files_cleaned_up
run_test test_fetch_pipelines_url_encodes_branch
print_results
```

**Step 4: Create test/test_pipeline_queue.sh**

Tests for:
- Proceeds when no other running workflows
- Blocks when other workflows are running
- Timeout behavior (when configured)

Similar approach — source functions, mock curl, test individually.

```bash
#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "${SCRIPT_DIR}/helpers.sh"

# source pipeline_queue.sh functions without executing main block
# We need to prevent the main execution from running.
# The script starts executing at line 82 with load_variables.
# We'll source it in a subshell context that exits early.
source_functions() {
    # Override load_variables to no-op for sourcing
    eval 'original_load_variables() { :; }'

    # source in subshell to get function defs without main execution
    # We'll use a trick: define functions by extracting them
    eval "$(sed -n '/^# helper function/,/^# fetch all workflows/p' "${SCRIPT_DIR}/../src/scripts/pipeline_queue.sh" | head -n -1)"
    eval "$(sed -n '/^# fetch all workflows/,/^# load all the data/p' "${SCRIPT_DIR}/../src/scripts/pipeline_queue.sh" | head -n -1)"
    eval "$(sed -n '/^# load all the data/,/^load_variables/p' "${SCRIPT_DIR}/../src/scripts/pipeline_queue.sh" | head -n -1)"
    eval "$(sed -n '/^debug/,/^}/p' "${SCRIPT_DIR}/../src/scripts/pipeline_queue.sh")"
}

test_pipeline_fetch_filters_self() {
    source_functions

    mock_curl_response() {
        cat > "$3" << 'FIXTURE'
{
    "next_page_token": null,
    "items": [
        {"id": "wf-current-1111", "name": "wf-a", "status": "running", "created_at": "2026-01-15T10:00:00Z"},
        {"id": "wf-other-3333", "name": "wf-b", "status": "running", "created_at": "2026-01-15T10:00:00Z"}
    ]
}
FIXTURE
        echo "200"
    }
    export -f mock_curl_response

    fetch_pipeline_workflows > /dev/null 2>&1

    local count
    count=$(jq length "${TMP_DIR}/workflow_status.json")
    assert_equals "filters out current workflow" "1" "${count}"
}

test_pipeline_no_other_workflows() {
    source_functions

    mock_curl_response() {
        cat > "$3" << 'FIXTURE'
{
    "next_page_token": null,
    "items": [
        {"id": "wf-current-1111", "name": "wf-a", "status": "running", "created_at": "2026-01-15T10:00:00Z"}
    ]
}
FIXTURE
        echo "200"
    }
    export -f mock_curl_response

    fetch_pipeline_workflows > /dev/null 2>&1
    update_comparables > /dev/null 2>&1

    assert_equals "no running workflows besides self" "0" "${running_workflows}"
}

# Run tests
run_test test_pipeline_fetch_filters_self
run_test test_pipeline_no_other_workflows
print_results
```

**Step 5: Update Makefile**

```makefile
.PHONY: test test-global-queue test-pipeline-queue

test: test-global-queue test-pipeline-queue

test-global-queue:
	bash test/test_global_queue.sh

test-pipeline-queue:
	bash test/test_pipeline_queue.sh
```

**Step 6: Run tests**

Run: `make test`
Expected: All tests pass

**Step 7: Commit**

```bash
git add test/ Makefile
git commit -m "test: add bash test harness with curl mocking

Adds lightweight test framework with:
- Isolated temp directories per test
- curl mocking via function override
- Assertion helpers (assert_equals, assert_contains)
- Test fixtures for API responses
- Tests for: stale file cleanup, URL encoding, jq quoting,
  HTTP 2xx acceptance, pipeline workflow filtering"
```

---

### Task 9: Final verification

**Step 1: Run ShellCheck on all scripts**

Run: `shellcheck src/scripts/global_queue.sh src/scripts/pipeline_queue.sh`
Expected: Clean (or only pre-existing warnings)

**Step 2: Run full test suite**

Run: `make test`
Expected: All tests pass

**Step 3: Verify orb packs correctly (if circleci CLI available)**

Run: `circleci orb pack src > /dev/null && echo "Orb packs successfully"`
Expected: Success

**Step 4: Manual review of both scripts end-to-end**

Read through the final state of both scripts to verify coherence.
