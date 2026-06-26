#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# 1. Configuration
TASK_DIR="/ctx/tasks"

echo "--- Starting Task Runner ---"

# 2. Validation
if [ ! -d "$TASK_DIR" ]; then
    echo "Error: Directory '$TASK_DIR' not found."
    exit 1
fi

# 3. The Execution Loop
# We use a 'for' loop which naturally sorts 01, 02, 03...
for script in "$TASK_DIR"/[0-9]*.sh; do

    # Handle case where no files match the pattern
    [ -e "$script" ] || { echo "No task scripts found."; exit 0; }

    echo "[RUNNING] $(basename "$script")"

    # Run the script.
    # Because 'set -e' is active in THIS script, if the command below
    # returns a non-zero exit code, the runner will stop immediately.
    bash "$script"

    echo "[SUCCESS] $(basename "$script") completed."
    echo "----------------------------"
done

echo "All tasks finished successfully."
