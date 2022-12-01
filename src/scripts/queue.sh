#!/bin/bash

debug() {
    if ["<< parameters.debug >>" == "true"]; then
        echo "DEBUG: ${@}"
    fi
}

debug "this is a test"
