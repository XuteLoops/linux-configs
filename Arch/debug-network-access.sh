#!/bin/bash
set -uo pipefail

PACMAN_PATH="$(command -v pacman)"
echo "pacman path:        [$PACMAN_PATH]"

LDD_OUTPUT="$(ldd "$PACMAN_PATH" 2>&1)"
echo "--- full ldd output ---"
echo "$LDD_OUTPUT"
echo "-----------------------"

ALPM_LIB=$(echo "$LDD_OUTPUT" | awk '/libalpm\.so/ {print $3; exit}')
echo "ALPM_LIB:            [$ALPM_LIB]"

if [ -z "$ALPM_LIB" ]; then
    echo "RESULT: ALPM_LIB is empty — awk didn't match anything in ldd output."
    exit 1
fi

if [ ! -f "$ALPM_LIB" ]; then
    echo "RESULT: ALPM_LIB path does not exist as a file: $ALPM_LIB"
    exit 1
fi

echo "--- strings | grep -i networkaccess ---"
strings "$ALPM_LIB" | grep -i networkaccess
GREP_EXIT=$?
echo "grep exit code:      $GREP_EXIT"

if [ "$GREP_EXIT" -eq 0 ]; then
    echo "RESULT: DETECTED"
else
    echo "RESULT: NOT DETECTED"
fi