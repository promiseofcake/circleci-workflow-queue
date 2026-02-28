#!/usr/bin/env bash
# Test helpers for circleci-workflow-queue scripts
set -euo pipefail

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

# mock curl -- tests override mock_curl_response to control behavior
curl() {
    local url=""
    local output=""
    local method="GET"

    # parse curl args to extract what we need
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            -X) method="$2"; shift 2 ;;
            -w) shift 2 ;;
            -s|-S) shift ;;
            -H) shift 2 ;;
            *) url="$1"; shift ;;
        esac
    done

    mock_curl_response "${method}" "${url}" "${output}"
}
export -f curl

# default mock -- returns 200 with empty JSON
mock_curl_response() {
    local method="$1"
    local url="$2"
    local output="$3"
    echo '{}' > "${output}"
    echo "200"
}
export -f mock_curl_response

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

assert_not_contains() {
    local description="$1"
    local needle="$2"
    local haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "${haystack}" | grep -qF "${needle}"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS: ${description}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: ${description}"
        echo "    expected NOT to contain: ${needle}"
        echo "    actual: ${haystack}"
    fi
}

# run a test function with setup/teardown
run_test() {
    local test_name="$1"
    echo "TEST: ${test_name}"
    setup
    if eval "${test_name}"; then
        teardown
    else
        local exit_code=$?
        teardown
        echo "  FAIL: ${test_name} exited with code ${exit_code}"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# print summary and exit with appropriate code
print_results() {
    echo ""
    echo "================================"
    echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
    echo "================================"
    [ "${TESTS_FAILED}" -eq 0 ]
}
