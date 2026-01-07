#!/bin/bash
set -e
set -o pipefail

tmp=${TMP_DIR:-/tmp}
workflows_file="${tmp}/workflow_status.json"

# logger command for debugging
debug() {
    if [ "${CONFIG_DEBUG_ENABLED}" == "1" ]; then
        echo "DEBUG: ${*}"
    fi
}

# ensure we have the required variables present to execute
load_variables(){
    # just confirm our required variables are present
    : "${CIRCLE_WORKFLOW_ID:?"Required Env Variable not found!"}"
    : "${CIRCLE_PIPELINE_ID:?"Required Env Variable not found!"}"
    : "${CIRCLE_PROJECT_USERNAME:?"Required Env Variable not found!"}"
    : "${CIRCLE_PROJECT_REPONAME:?"Required Env Variable not found!"}"
    # Only needed for private projects
    if [ -z "${CIRCLECI_API_TOKEN}" ]; then
        echo "CIRCLECI_API_TOKEN not set. Private projects will be inaccessible."
    else
        fetch "https://circleci.com/api/v2/me" "${tmp}/me.cci"
        me=$(jq -e '.id' "${tmp}/me.cci")
        echo "Using API key for user: ${me}"
    fi
}

# helper function to perform HTTP requests via curl
fetch(){
    url=$1
    target=$2
    method=${3:-GET}
    debug "Performing API ${method} Call to ${url} to ${target}"

    http_response=$(curl -s -X "${method}" -H "Circle-Token: ${CIRCLECI_API_TOKEN}" -H "Content-Type: application/json" -o "${target}" -w "%{http_code}" "${url}")
    if [ "${http_response}" != "200" ]; then
        echo "ERROR: Server returned error code: ${http_response}"
        debug "${target}"
        exit 1
    else
        debug "API Success"
    fi
}

# fetch all workflows within the current pipeline
fetch_pipeline_workflows(){
    debug "Fetching workflow information for pipeline: ${CIRCLE_PIPELINE_ID}"
    pipeline_detail=${tmp}/pipeline-${CIRCLE_PIPELINE_ID}.json
    fetch "https://circleci.com/api/v2/pipeline/${CIRCLE_PIPELINE_ID}/workflow" "${pipeline_detail}"
    debug "Pipeline's details: $(jq -r '.' "${pipeline_detail}")"
    # fetch all workflows that are not this workflow
    jq -s "[.[].items[] | select((.id != \"${CIRCLE_WORKFLOW_ID}\") and ((.status == \"running\") or (.status == \"created\")))]" "${pipeline_detail}" > "${workflows_file}"
}

# load all the data necessary to compare build executions
update_comparables(){
    fetch_pipeline_workflows

    running_workflows=$(jq length "${workflows_file}")
    debug "Running workflows: ${running_workflows}"
}

load_variables
echo "This build will block until all previous builds complete."
wait_start_time=$(date +%s)
loop_time=11

# queue loop
confidence=0
while true; do
    update_comparables
    now=$(date +%s)
    wait_time=$(( now - wait_start_time ))

    # if we have no running workflows, check confidence, and move to front of line.
    if [[ "${running_workflows}" -eq 0 ]] ; then
        if [ $confidence -lt "${CONFIG_CONFIDENCE}" ]; then
            # To grow confidence, we check again with a delay.
            confidence=$((confidence+1))
            echo "API shows no running pipeline workflows, but it is possible a previous workflow has pending jobs not yet visible in API."
            echo "Rerunning check ${confidence}/${CONFIG_CONFIDENCE}"
        else
            echo "Front of the line, WooHoo!, Build continuing"
            break
        fi
    else
        # If we fail, reset confidence
        confidence=0
        echo "This workflow (${CIRCLE_WORKFLOW_ID}) is queued, waiting for ${running_workflows} pipeline workflows to complete."
        echo "Total Queue time: ${wait_time} seconds."
    fi

    sleep $loop_time
done
