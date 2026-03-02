#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317,SC2329,SC2034,SC2154
# SC1091: helpers.sh is sourced at runtime
# SC2317: Functions defined inside tests are invoked indirectly via export -f / eval
# SC2034: Variables set here are used by sourced script functions
# SC2154: Variables are assigned by eval'd/sourced script code
set -euo pipefail

TEST_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "${TEST_SCRIPT_DIR}/helpers.sh"

# Source just the function definitions from pipeline_queue.sh
# The main block starts at "load_variables" call (after function defs)
source_pipeline_functions() {
    eval "$(sed -n '/^load_variables$/q;p' "${TEST_SCRIPT_DIR}/../src/scripts/pipeline_queue.sh")"
}

#--- Tests ---

test_filters_out_current_workflow() {
    source_pipeline_functions

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

    workflows_file="${TMP_DIR}/workflow_status.json"
    fetch_pipeline_workflows > /dev/null 2>&1

    local count
    count=$(jq length "${workflows_file}")
    assert_equals "filters out current workflow" "1" "${count}"
}

test_no_running_workflows_besides_self() {
    source_pipeline_functions

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

    workflows_file="${TMP_DIR}/workflow_status.json"
    update_comparables > /dev/null 2>&1

    assert_equals "no running workflows besides self" "0" "${running_workflows}"
}

test_filters_completed_workflows() {
    source_pipeline_functions

    mock_curl_response() {
        cat > "$3" << 'FIXTURE'
{
    "next_page_token": null,
    "items": [
        {"id": "wf-current-1111", "name": "wf-a", "status": "running", "created_at": "2026-01-15T10:00:00Z"},
        {"id": "wf-other-3333", "name": "wf-b", "status": "success", "created_at": "2026-01-15T09:50:00Z"},
        {"id": "wf-other-4444", "name": "wf-c", "status": "failed", "created_at": "2026-01-15T09:45:00Z"}
    ]
}
FIXTURE
        echo "200"
    }
    export -f mock_curl_response

    workflows_file="${TMP_DIR}/workflow_status.json"
    fetch_pipeline_workflows > /dev/null 2>&1

    local count
    count=$(jq length "${workflows_file}")
    assert_equals "completed and failed workflows filtered out" "0" "${count}"
}

test_counts_running_workflows() {
    source_pipeline_functions

    mock_curl_response() {
        cat > "$3" << 'FIXTURE'
{
    "next_page_token": null,
    "items": [
        {"id": "wf-current-1111", "name": "wf-a", "status": "running", "created_at": "2026-01-15T10:00:00Z"},
        {"id": "wf-other-3333", "name": "wf-b", "status": "running", "created_at": "2026-01-15T10:00:00Z"},
        {"id": "wf-other-4444", "name": "wf-c", "status": "created", "created_at": "2026-01-15T10:00:00Z"}
    ]
}
FIXTURE
        echo "200"
    }
    export -f mock_curl_response

    workflows_file="${TMP_DIR}/workflow_status.json"
    update_comparables > /dev/null 2>&1

    assert_equals "counts running+created workflows (excluding self)" "2" "${running_workflows}"
}

# Run all tests
echo "=== Pipeline Queue Tests ==="
run_test test_filters_out_current_workflow
run_test test_no_running_workflows_besides_self
run_test test_filters_completed_workflows
run_test test_counts_running_workflows
print_results
