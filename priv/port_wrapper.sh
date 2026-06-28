#!/usr/bin/env bash
# priv/port_wrapper.sh — stdin-guard wrapper to prevent orphaned Python/Docker processes

# Parse command line arguments to detect the --cidfile flag (if present)
cidfile=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--cidfile" ]; then
    next_idx=$((i+1))
    cidfile="${!next_idx}"
  fi
done

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

# Cleanup function to run on shell exit (ensures no orphaned container on daemon)
cleanup() {
  # Clean up the background blocker process
  kill -KILL "$blocker_pid" 2>/dev/null
  
  # Terminate the local command process
  kill -KILL "$child_pid" 2>/dev/null
  
  # If a cidfile was supplied and exists, read it and terminate the container on the daemon
  if [ -n "$cidfile" ] && [ -f "$cidfile" ]; then
    container_id=$(cat "$cidfile" 2>/dev/null)
    if [ -n "$container_id" ]; then
      # Stop the container gracefully
      docker stop "$container_id" >/dev/null 2>&1
      # Force kill the container if still running
      docker kill "$container_id" >/dev/null 2>&1
    fi
    # Clean up the cidfile
    rm -f "$cidfile" 2>/dev/null
  fi
}

# Register the cleanup trap on shell EXIT
trap cleanup EXIT

# Wait for the child process to exit naturally
wait "$child_pid"
exit_code=$?

exit $exit_code
