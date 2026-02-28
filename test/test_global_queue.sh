#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317,SC2329,SC2034,SC2154
# SC1091: helpers.sh is sourced at runtime
# SC2317: Functions defined inside tests are invoked indirectly via export -f / eval
# SC2034: Variables set here are used by sourced script functions
# SC2154: Variables are assigned by eval'd/sourced script code
set -euo pipefail

TEST_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "${TEST_SCRIPT_DIR}/helpers.sh"

# Source just the function definitions from global_queue.sh
# The main block starts at the comment "# main execution"
# We extract everything above that line and eval it
source_global_functions() {
    eval "$(sed -n '/^# main execution/q;p' "${TEST_SCRIPT_DIR}/../src/scripts/global_queue.sh")"
}

#--- Tests ---

test_fetch_accepts_2xx() {
    source_global_functions

    mock_curl_response() {
        echo '{"status":"cancelled"}' > "$3"
        echo "202"
    }
    export -f mock_curl_response

    fetch "https://example.com/cancel" "${TMP_DIR}/cancel.json" "POST"
    assert_equals "fetch returns success for 202" "0" "$?"
}

test_fetch_retries_on_transient_errors() {
    source_global_functions

    # Track call count
    echo "0" > "${TMP_DIR}/call_count"

    mock_curl_response() {
        local count
        count=$(cat "${TMP_DIR}/call_count")
        count=$((count + 1))
        echo "${count}" > "${TMP_DIR}/call_count"

        if [ "${count}" -lt 3 ]; then
            echo '{}' > "$3"
            echo "503"
        else
            echo '{"ok":true}' > "$3"
            echo "200"
        fi
    }
    export -f mock_curl_response

    # Override sleep to not actually wait
    sleep() { :; }
    export -f sleep

    fetch "https://example.com/api" "${TMP_DIR}/result.json"
    local call_count
    call_count=$(cat "${TMP_DIR}/call_count")
    assert_equals "fetch retried until success" "3" "${call_count}"
}

test_fetch_fails_on_non_transient_error() {
    source_global_functions

    mock_curl_response() {
        echo '{"message":"unauthorized"}' > "$3"
        echo "401"
    }
    export -f mock_curl_response

    # Run fetch in a subshell since it calls exit 1, not return 1
    local exit_code=0
    (fetch "https://example.com/api" "${TMP_DIR}/result.json") 2>/dev/null || exit_code=$?
    assert_equals "fetch fails on 401" "1" "${exit_code}"
}

test_jq_values_are_unquoted() {
    source_global_functions

    echo '[{"id":"wf-current-1111","created_at":"2026-01-15T10:00:00Z","name":"deploy","status":"running"}]' > "${TMP_DIR}/workflow_status.json"
    workflows_file="${TMP_DIR}/workflow_status.json"

    load_current_workflow_values

    assert_equals "my_commit_time unquoted" "2026-01-15T10:00:00Z" "${my_commit_time}"
    assert_equals "my_workflow_id unquoted" "wf-current-1111" "${my_workflow_id}"
}

test_stale_pipeline_files_cleaned() {
    source_global_functions

    # Create a stale pipeline file
    echo '{"items":[{"id":"wf-stale","name":"old","status":"running","created_at":"2025-01-01T00:00:00Z"}]}' > "${TMP_DIR}/pipeline-stale-9999.json"

    # Mock: pipelines file returns no pipelines
    echo '{"next_page_token":null,"items":[]}' > "${TMP_DIR}/pipeline_status.json"
    pipelines_file="${TMP_DIR}/pipeline_status.json"

    mock_curl_response() {
        echo '{"next_page_token":null,"items":[]}' > "$3"
        echo "200"
    }
    export -f mock_curl_response

    fetch_pipeline_workflows > /dev/null 2>&1 || true

    local stale_exists="no"
    [ -f "${TMP_DIR}/pipeline-stale-9999.json" ] && stale_exists="yes"
    assert_equals "stale pipeline file cleaned up" "no" "${stale_exists}"
}

test_url_encodes_branch() {
    source_global_functions

    export CIRCLE_BRANCH="feature/my branch+name"

    mock_curl_response() {
        # write captured URL to file for assertion
        echo "$2" > "${TMP_DIR}/captured_url"
        echo '{"next_page_token":null,"items":[]}' > "$3"
        echo "200"
    }
    export -f mock_curl_response

    pipelines_file="${TMP_DIR}/pipeline_status.json"
    fetch_pipelines > /dev/null 2>&1

    local captured_url
    captured_url=$(cat "${TMP_DIR}/captured_url" 2>/dev/null || echo "")
    assert_contains "branch URL-encoded in request" "feature%2Fmy%20branch%2Bname" "${captured_url}"
}

test_front_of_line_when_oldest() {
    source_global_functions

    # Only our workflow is running
    echo '[{"id":"wf-current-1111","created_at":"2026-01-15T10:00:00Z","name":"deploy","status":"running"}]' > "${TMP_DIR}/workflow_status.json"
    workflows_file="${TMP_DIR}/workflow_status.json"

    load_current_workflow_values

    oldest_running_workflow_id=$(jq -r '. | sort_by(.created_at, .id) | .[0].id' "${workflows_file}")
    oldest_commit_time=$(jq -r '. | sort_by(.created_at, .id) | .[0].created_at' "${workflows_file}")

    # Check front-of-line condition (same logic as global_queue.sh line 170)
    local is_front="no"
    if [[ -n "${my_commit_time}" ]] && [[ "${my_commit_time}" != "null" ]] && [[ "${oldest_commit_time}" > "${my_commit_time}" || ( "${oldest_commit_time}" = "${my_commit_time}" && "${oldest_running_workflow_id}" = "${my_workflow_id}" ) ]]; then
        is_front="yes"
    fi
    assert_equals "front of line when only workflow" "yes" "${is_front}"
}

test_queued_when_older_workflow_exists() {
    source_global_functions

    # Two workflows: ours and an older one
    cat > "${TMP_DIR}/workflow_status.json" << 'EOF'
[
    {"id":"wf-current-1111","created_at":"2026-01-15T10:00:00Z","name":"deploy","status":"running"},
    {"id":"wf-older-2222","created_at":"2026-01-15T09:50:00Z","name":"deploy","status":"running"}
]
EOF
    workflows_file="${TMP_DIR}/workflow_status.json"

    load_current_workflow_values

    oldest_running_workflow_id=$(jq -r '. | sort_by(.created_at, .id) | .[0].id' "${workflows_file}")
    oldest_commit_time=$(jq -r '. | sort_by(.created_at, .id) | .[0].created_at' "${workflows_file}")

    local is_front="no"
    if [[ -n "${my_commit_time}" ]] && [[ "${my_commit_time}" != "null" ]] && [[ "${oldest_commit_time}" > "${my_commit_time}" || ( "${oldest_commit_time}" = "${my_commit_time}" && "${oldest_running_workflow_id}" = "${my_workflow_id}" ) ]]; then
        is_front="yes"
    fi
    assert_equals "queued when older workflow exists" "no" "${is_front}"
}

test_tiebreaker_with_same_timestamp() {
    source_global_functions

    # Two workflows with same timestamp. Our ID (wf-current-1111) sorts before wf-other-2222
    cat > "${TMP_DIR}/workflow_status.json" << 'EOF'
[
    {"id":"wf-current-1111","created_at":"2026-01-15T10:00:00Z","name":"deploy","status":"running"},
    {"id":"wf-other-2222","created_at":"2026-01-15T10:00:00Z","name":"deploy","status":"running"}
]
EOF
    workflows_file="${TMP_DIR}/workflow_status.json"

    load_current_workflow_values

    oldest_running_workflow_id=$(jq -r '. | sort_by(.created_at, .id) | .[0].id' "${workflows_file}")
    oldest_commit_time=$(jq -r '. | sort_by(.created_at, .id) | .[0].created_at' "${workflows_file}")

    # wf-current-1111 sorts before wf-other-2222 lexicographically, so we should be front of line
    local is_front="no"
    if [[ -n "${my_commit_time}" ]] && [[ "${my_commit_time}" != "null" ]] && [[ "${oldest_commit_time}" > "${my_commit_time}" || ( "${oldest_commit_time}" = "${my_commit_time}" && "${oldest_running_workflow_id}" = "${my_workflow_id}" ) ]]; then
        is_front="yes"
    fi
    assert_equals "wins tiebreaker with same timestamp (smaller ID)" "yes" "${is_front}"

    # Now test the OTHER workflow should NOT be front of line
    export CIRCLE_WORKFLOW_ID="wf-other-2222"
    load_current_workflow_values

    local other_is_front="no"
    if [[ -n "${my_commit_time}" ]] && [[ "${my_commit_time}" != "null" ]] && [[ "${oldest_commit_time}" > "${my_commit_time}" || ( "${oldest_commit_time}" = "${my_commit_time}" && "${oldest_running_workflow_id}" = "${my_workflow_id}" ) ]]; then
        other_is_front="yes"
    fi
    assert_equals "loses tiebreaker with same timestamp (larger ID)" "no" "${other_is_front}"
}

# Run all tests
echo "=== Global Queue Tests ==="
run_test test_fetch_accepts_2xx
run_test test_fetch_retries_on_transient_errors
run_test test_fetch_fails_on_non_transient_error
run_test test_jq_values_are_unquoted
run_test test_stale_pipeline_files_cleaned
run_test test_url_encodes_branch
run_test test_front_of_line_when_oldest
run_test test_queued_when_older_workflow_exists
run_test test_tiebreaker_with_same_timestamp
print_results
