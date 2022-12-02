#!/bin/bash

debug() {
    if [ -n "${DEBUG_ENABLED}" ]; then
        echo "DEBUG: ${*}"
    fi
}

debug "this is a test"
echo "this is a test"
