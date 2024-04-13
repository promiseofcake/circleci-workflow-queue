#!/usr/bin/env bash
# shellcheck disable=all

# This script is used to test the scripts in the src/scripts directory
TMP_DIR=`mktemp -d`

# job config
CONFIG_DEBUG_ENABLED=1
CONFIG_TIME=10
CONFIG_DONT_QUIT=1
CONFIG_ONLY_ON_BRANCH=*
CONFIG_CONFIDENCE=1

# test values
CIRCLE_PIPELINE_ID=4e1ffd3b-c260-43db-a66c-8766eaf7fc88
CIRCLE_WORKFLOW_ID=476fa7ff-7534-440f-9a65-a2779170d344
CIRCLE_PROJECT_USERNAME=promiseofcake
CIRCLE_PROJECT_REPONAME=circleci-workflow-queue
CIRCLECI_API_TOKEN=${CIRCLECI_USER_TOKEN}

source ./internal-queue.sh
