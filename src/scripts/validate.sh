#!/usr/bin/env bash
# shellcheck disable=SC2004

tmp=${TMP_DIR:-/tmp}

debug() {
    if [ "${CONFIG_DEBUG_ENABLED}" == "1" ]; then
        echo "DEBUG: ${*}"
    fi
}

# ensure we have the required variables present to execute
load_variables(){
    # just confirm our required variables are present
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
    debug "api call: ${method} ${url} > ${target}"

    http_response=$(curl -s -X "${method}" -H "Circle-Token: ${CIRCLECI_API_TOKEN}" -H "Content-Type: application/json" -o "${target}" -w "%{http_code}" "${url}")
    if [ "${http_response}" != "200" ]; then
        echo "ERROR: api-call: server returned error code: ${http_response}"
        debug "${target}"
        exit 1
    else
        debug "api call: success"
    fi
}

# fetch sibling workflows in the current pipeline
fetch_pipeline_workflows(){
    debug "Fetching workflow information for pipeline: ${CIRCLE_PIPELINE_ID}"
    pipeline_detail=${tmp}/pipeline-${CIRCLE_PIPELINE_ID}.json
    fetch "https://circleci.com/api/v2/pipeline/${CIRCLE_PIPELINE_ID}/workflow" "${pipeline_detail}"
    debug "Pipeline's details: $(jq -r '.' "${pipeline_detail}")"
}

load_variables
fetch_pipeline_workflows


# get data about all of the sibling test-pipelines
output=$(jq -r '.items | sort_by(.stopped_at) | .[].name | select(. | startswith("test-pipeline"))' "${pipeline_detail}")
# shellcheck disable=SC2206
actual=($output)
# this is the expected completion order
expected=("test-pipeline-b" "test-pipeline-c" "test-pipeline-a")

# iterate over results and ensure the ordering is correct.
length=${#actual[@]}
for ((i=0; i<$length; i++))
do
    a=${actual[$i]}
    b=${expected[$i]}
    if [ "$a" != "$b" ]; then
        echo "Expected $b but got $a"
        exit 1
    fi
done
