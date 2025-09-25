#!/bin/bash
tmp=${TMP_DIR:-/tmp}
pipelines_file="${tmp}/pipeline_status.json"
workflows_file="${tmp}/workflow_status.json"

# logger command for debugging
debug() {
    if [ "${CONFIG_DEBUG_ENABLED}" == "1" ]; then
        echo "DEBUG: ${*}"
    fi
}

# ensure we have the required variables present to execute
load_variables(){
    : "${CIRCLE_WORKFLOW_ID:?"Required Env Variable not found!"}"
    : "${CIRCLE_PROJECT_USERNAME:?"Required Env Variable not found!"}"
    : "${CIRCLE_PROJECT_REPONAME:?"Required Env Variable not found!"}"
    : "${CIRCLE_REPOSITORY_URL:?"Required Env Variable not found!"}"
    : "${CIRCLE_JOB:?"Required Env Variable not found!"}"

    # required for private projects
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

# fetch all current pipelines for a given branch
fetch_pipelines(){
    : "${CIRCLE_BRANCH:?"Required Env Variable not found!"}"
    echo "Only blocking execution if running previous workflows on branch: ${CIRCLE_BRANCH}"
    pipelines_api_url_template="https://circleci.com/api/v2/project/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?branch=${CIRCLE_BRANCH}"

    debug "Fetching piplines for: ${CIRCLE_BRANCH}"
    fetch "${pipelines_api_url_template}" "${pipelines_file}"
}

# iterate over all pipelines, and fetch workflow information
fetch_pipeline_workflows(){
    for pipeline in $(jq -r ".items[] | .id //empty" "${pipelines_file}" | uniq)
    do
        debug "Fetching workflow metadata for pipeline: ${pipeline}"
        pipeline_detail=${tmp}/pipeline-${pipeline}.json
        fetch "https://circleci.com/api/v2/pipeline/${pipeline}/workflow" "${pipeline_detail}"
        created_at=$(jq -r '.items[] | .created_at' "${pipeline_detail}")
        debug "Pipeline:'s workflow was created at: ${created_at}"
    done

    # filter out any workflows that are not active
    if [ "${CONFIG_INCLUDE_ON_HOLD}" = "1" ]; then
        active_statuses="$(printf '%s' '["running","created","on_hold"]')"
    else
        active_statuses="$(printf '%s' '["running","created"]')"
    fi

    debug "filtering on statuses: ${active_statuses}"

    # filter out any workflows that match the ignored list
    ignored_workflows="[]"
    if [ -n "${CONFIG_IGNORED_WORKFLOWS}" ]; then
        ignored_workflows=$(printf '"%s"' "${CONFIG_IGNORED_WORKFLOWS}" | jq 'split(",")')
    fi

    debug "ignoring workflows: ${ignored_workflows}"

    jq -s "[.[].items[] | select(([.name] | inside(${ignored_workflows}) | not) and ([.status] | inside(${active_statuses})))]" "${tmp}"/pipeline-*.json > "${workflows_file}"
}

# parse workflows to fetch parmeters about this current running workflow
load_current_workflow_values(){
    my_commit_time=$(jq ".[] | select (.id == \"${CIRCLE_WORKFLOW_ID}\").created_at" "${workflows_file}")
    my_workflow_id=$(jq ".[] | select (.id == \"${CIRCLE_WORKFLOW_ID}\").id" "${workflows_file}")
}

# load all the data necessary to compare build executions
update_comparables(){
    fetch_pipelines

    fetch_pipeline_workflows

    load_current_workflow_values

    echo "This job will block until no previous workflows have *any* workflows running."
    oldest_running_workflow_id=$(jq '. | sort_by(.created_at) | .[0].id' "${workflows_file}")
    oldest_commit_time=$(jq '. | sort_by(.created_at) | .[0].created_at' "${workflows_file}")
    if [ -z "${oldest_commit_time}" ] || [ -z "${oldest_running_workflow_id}" ]; then
        echo "ERROR: API Error - unable to load previous workflow timings. File a bug"
        exit 1
    fi

    debug "Oldest workflow: ${oldest_running_workflow_id}"
}

# will perform a cancel request for the workflow in question
cancel_current_workflow(){
    echo "Cancelleing workflow ${my_workflow_id}"
    fetch "https://circleci.com/api/v2/workflow/${my_workflow_id}" "${tmp}/cancel-workflow-${my_workflow_id}.out" "POST"
}


# main execution
# set values that wont change while we wait
if [ "${CONFIG_ONLY_ON_BRANCH}" = "*" ] || [ "${CONFIG_ONLY_ON_BRANCH}" = "${CIRCLE_BRANCH}" ]; then
    echo "${CIRCLE_BRANCH} queueable"
else
    echo "Queueing only happens on ${CONFIG_ONLY_ON_BRANCH} branch, skipping queue"
    exit 0
fi

load_variables
max_time=${CONFIG_TIME}
echo "This build will block until all previous builds complete."
echo "Max Queue Time: ${max_time} minutes."
wait_start_time=$(date +%s)
loop_time=11
max_time_seconds=$((max_time * 60))

# queue loop
confidence=0
while true; do
    update_comparables
    now=$(date +%s)
    wait_time=$((now - wait_start_time))
    echo "This Workflow Timestamp: ${my_commit_time}"
    echo "Oldest Workflow Timestamp: ${oldest_commit_time}"
    if [[ -n "${my_commit_time}" ]] && [[ "${oldest_commit_time}" > "${my_commit_time}" || "${oldest_commit_time}" = "${my_commit_time}" ]] ; then
    # API returns Y-M-D HH:MM (with 24 hour clock) so alphabetical string compare is accurate to timestamp compare as well
    # Workflow API does not include pending, so it is posisble we queried in between a workfow transition, and we;re NOT really front of line.
    if [ $confidence -lt "${CONFIG_CONFIDENCE}" ];then
        # To grow confidence, we check again with a delay.
        confidence=$((confidence+1))
        echo "API shows no previous workflows, but it is possible a previous workflow has pending jobs not yet visible in API."
        echo "Rerunning check ${confidence}/${CONFIG_CONFIDENCE}"
    else
        echo "Front of the line, WooHoo!, Build continuing"
        break
    fi
    else
        # If we fail, reset confidence
        confidence=0
        echo "This build (${CIRCLE_WORKFLOW_ID}) is queued, waiting for workflow (${oldest_running_workflow_id}) to complete."
        echo "Total Queue time: ${wait_time} seconds."
    fi

    if [ $wait_time -ge $max_time_seconds ]; then
        echo "Max wait time exceeded, considering response."
        if [ "${CONFIG_DONT_QUIT}" == "1" ];then
            echo "Orb parameter dont-quit is set to true, letting this job proceed!"
            exit 0
        else
            cancel_current_workflow
            sleep 10 # wait for API to cancel this job, rather than showing as failure
            exit 1 # but just in case, fail job
        fi
    fi

    sleep $loop_time
done
