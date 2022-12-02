#!/bin/bash

debug() {
    if [ "${DEBUG_ENABLED}" == "true" ]; then
        echo "DEBUG: ${*}"
    fi
}

debug "this is a test"
