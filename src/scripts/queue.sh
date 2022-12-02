#!/bin/bash

debug() {
    if [ -n "${DEBUG_ENABLED}" ]; then
        echo "DEBUG: ${*}"
    fi
}

tmp="/tmp"
pipeline_file="${tmp}/pipeline_status.json"
workflows_file="${tmp}/workflow_status.json"

load_variables(){
    # just confirm our required variables are present
    : ${CIRCLE_BUILD_NUM:?"Required Env Variable not found!"}
    : ${CIRCLE_WORKFLOW_ID:?"Required Env Variable not found!"}
    : ${CIRCLE_PROJECT_USERNAME:?"Required Env Variable not found!"}
    : ${CIRCLE_PROJECT_REPONAME:?"Required Env Variable not found!"}
    : ${CIRCLE_REPOSITORY_URL:?"Required Env Variable not found!"}
    : ${CIRCLE_JOB:?"Required Env Variable not found!"}
    # Only needed for private projects
    if [ -z "${CIRCLECI_USER_AUTH}" ]; then
        echo "CIRCLECI_USER_AUTH not set. Private projects will be inaccessible."
    else
        fetch "https://circleci.com/api/v2/me" "/tmp/me.cci"
        me=$(jq -e '.id' /tmp/me.cci)
        echo "Using API key for user: ${me}"
    fi
}

fetch(){
    debug "Making API Call to ${1}"
    url=$1
    target=$2
    debug "API CALL ${url}"
    http_response=$(curl -s -X GET -H "Authorization: Basic ${CIRCLECI_USER_AUTH}" -H "Content-Type: application/json" -o "${target}" -w "%{http_code}" "${url}")
    if [ $http_response != "200" ]; then
        echo "ERROR: Server returned error code: $http_response"
        cat ${target}
        # exit 1
    else
        debug "API Success"
    fi
}

fetch_pipelines(){
    : ${CIRCLE_BRANCH:?"Required Env Variable not found!"}
    echo "Only blocking execution if running previous workflows on branch: ${CIRCLE_BRANCH}"
    pipelines_api_url_template="https://circleci.com/api/v2/project/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?branch=${CIRCLE_BRANCH}"

    debug "DEBUG Attempting to access CircleCI API. If the build process fails after this step, ensure your CIRCLECI_USER_AUTH  is set."
    fetch "$pipelines_api_url_template" "${pipeline_file}"
    echo "DEBUG API access successful"
}

fetch_pipeline_workflows(){
    for pipeline in `jq -r ".items[] | .id //empty" ${pipeline_file} | uniq`
    do
        debug "Checking time of pipeline: ${pipeline}"
        pipeline_detail=${tmp}/pipeline-${pipeline}.json
        fetch "https://circleci.com/api/v2/pipeline/${pipeline}/workflow" "${pipeline_detail}"
        created_at=`jq -r '.items[] | .created_at' ${pipeline_detail}`
        debug "Pipeline was created at: ${created_at}"
    done
    jq -s '[.[].items[]]' ${tmp}/pipeline-*.json > ${workflows_file}
}

load_current_workflow_values(){
    my_commit_time=`jq '.[] | select (.pipeline_number == ${CIRCLE_BUILD_NUM}).created_at' ${workflows_file}`
    my_workflow_id`jq '.[] | select (.pipeline_number == ${CIRCLE_BUILD_NUM}).id' ${workflows_file}`
}

update_comparables(){
    fetch_pipelines

    fetch_pipeline_workflows

    load_current_workflow_values

    echo "This job will block until no previous workflows have *any* workflows running."
    oldest_running_workflow_id=`jq '. | sort_by(.created_at) | .[0].id' ${workflows_file}`
    oldest_commit_time=`jq '. | sort_by(.created_at) | .[0].created_at' ${workflows_file}`
    if [ -z "${oldest_commit_time}" || -z "${oldest_running_workflow_id}" ]; then
        echo "ERROR: API Error - unable to load previous workflow timings. File a bug"
        exit 1
    fi

    debug "Oldest workflow: ${oldest_running_workflow_id}"
}

cancel_current_workflow(){
    echo "Cancelleing workflow ${my_workflow_id}"
    cancel_api_url_template="https://circleci.com/api/v2/workflow/${my_workflow_id}"
    curl -s -X POST -H "Authorization: Basic ${CIRCLECI_USER_AUTH}" -H "Content-Type: application/json" $cancel_api_url_template > /dev/null
}

if [ "${CONFIG_ONLY_ON_BRANCH}" = "*" ] || [ "${CONFIG_ONLY_ON_BRANCH}" = "${CIRCLE_BRANCH}" ]; then
    echo "${CIRCLE_BRANCH} queueable"
else
    echo "Queueing only happens on ${CONFIG_ONLY_ON_BRANCH} branch, skipping queue"
    exit 0
fi

### Set values that wont change while we wait
load_variables
max_time=${CONFIG_TIME}
echo "This build will block until all previous builds complete."
echo "Max Queue Time: ${max_time} minutes."
wait_time=0
loop_time=11
max_time_seconds=$((max_time * 60))

### Queue Loop
confidence=0
while true; do
    update_comparables
    echo "This Workflow Timestamp: $my_commit_time"
    echo "Oldest Workflow Timestamp: $oldest_commit_time"
    if [[ ! -z "$my_commit_time" ]] && [[ "$oldest_commit_time" > "$my_commit_time" || "$oldest_commit_time" = "$my_commit_time" ]] ; then
    # API returns Y-M-D HH:MM (with 24 hour clock) so alphabetical string compare is accurate to timestamp compare as well
    # Workflow API does not include pending, so it is posisble we queried in between a workfow transition, and we;re NOT really front of line.
    if [ $confidence -lt ${CONFIG_CONFIDENCE} ];then
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
        echo "This build (${CIRCLE_BUILD_NUM}) is queued, waiting for workflow (${oldest_running_workflow_id}) to complete."
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
    wait_time=$(( loop_time + wait_time ))
done
