#!/bin/sh
# Writes PUBLIC_* environment variables to /env.js (window.__ENV__) at
# container start — only variables with that prefix, never secrets.
set -eu
out=/usr/share/nginx/html/env.js
{
    printf 'window.__ENV__ = {'
    env | grep '^PUBLIC_' | sort | while IFS='=' read -r key value; do
        esc=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '"%s":"%s",' "$key" "$esc"
    done
    printf '};\n'
} > "$out"
