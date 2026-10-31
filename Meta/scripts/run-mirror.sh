#!/bin/bash
# run-mirror.sh — coach-tone reflection on the person (wraps run-thinker.sh --mirror).
exec /bin/bash "$(dirname "$0")/run-thinker.sh" --mirror
