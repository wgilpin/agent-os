#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -e

# If running on macOS with Orbstack, auto-resolve the correct socket path.
if [ -S "$HOME/.orbstack/run/docker.sock" ]; then
  export DOCKER_HOST="unix://$HOME/.orbstack/run/docker.sock"
  echo "Using OrbStack Docker socket: $DOCKER_HOST"
fi

echo "Building agent-discovery:dev container image..."
# Build the image from repository root pointing to discovery/Dockerfile
docker build -t agent-discovery:dev -f agents/discovery/Dockerfile .
echo "Image built successfully!"
