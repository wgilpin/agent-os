#!/usr/bin/env bash
# priv/port_wrapper.sh — stdin-guard wrapper to prevent orphaned Python processes

# Duplicate stdin (fd 0) to fd 3 to prevent default /dev/null redirection for background jobs
exec 3<&0

# Read the single-line JSON input from fd 3
read -r input_line <&3

# Run the child command in the background, feeding it the input line
printf '%s\n' "$input_line" | "$@" &
child_pid=$!

# Monitor the remaining stdin on fd 3. If it closes (EOF), kill the child.
(
  cat <&3 >/dev/null
  kill -KILL "$child_pid" 2>/dev/null
) &
blocker_pid=$!

# Wait for the child process to exit naturally
wait "$child_pid"
exit_code=$?

# Clean up the blocker process and exit with child's exit status
kill -KILL "$blocker_pid" 2>/dev/null
exit $exit_code
