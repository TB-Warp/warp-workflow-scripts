#!/usr/bin/env bash
# Generic runner that executes a command and aborts if there's been no output for N seconds.
# Usage: _runner.sh <idle_timeout_seconds> -- <command> [args...]
# Default idle timeout: 20 seconds
set -euo pipefail

IDLE_TIMEOUT=${1:-20}
shift || true
if [[ "${1:-}" == "--" ]]; then shift; fi
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <idle_timeout_seconds> -- <command> [args...]" >&2
  exit 2
fi

cmd=("$@")

# Create a pipe to watch output
tmpfifo=$(mktemp -u)
mkfifo "$tmpfifo"
last_out=$(date +%s)

# Reader to update last_out whenever there's output
{
  while IFS= read -r line; do
    echo "$line"
    last_out=$(date +%s)
  done <"$tmpfifo"
} &
reader_pid=$!

# Run the command, redirecting stdout to fifo, stderr merged
{ "${cmd[@]}" 2>&1; echo "__RUNNER_EOF__"; } >"$tmpfifo" &
cmd_pid=$!

# Monitor loop
while kill -0 "$cmd_pid" >/dev/null 2>&1; do
  now=$(date +%s)
  if (( now - last_out > IDLE_TIMEOUT )); then
    echo "⚠️  No output for ${IDLE_TIMEOUT}s. Terminating stalled command: ${cmd[*]}" >&2
    kill "$cmd_pid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$cmd_pid" >/dev/null 2>&1 || true
    wait "$cmd_pid" >/dev/null 2>&1 || true
    kill "$reader_pid" >/dev/null 2>&1 || true
    rm -f "$tmpfifo"
    exit 124
  fi
  sleep 1
done

# Collect exit code
wait "$cmd_pid"
rc=$?
kill "$reader_pid" >/dev/null 2>&1 || true
rm -f "$tmpfifo"
exit "$rc"

