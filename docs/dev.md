Update peridio.json with the following for local dev

```
  "device_api": {
    "url": "device.test.peridio.com:4001",
    "certificate_path": "/etc/peridiod/ca-cert.pem"
  },
```

Peridio.Cloud

```
      PeridioSDK.Client.new(
        # device_api_host: "https://#{config.device_api_host}",
        device_api_host: "https://#{config.device_api_host}:#{config.device_api_port}",
        adapter: adapter,
        user_agent: user_agent()
      )
```

example shell script for local dev

```
#!/usr/bin/env bash

set -e

# Default values
BUILD=true
RUN=true
SHELL=false
KILL=false
CLEAN=false
SEED_CACHE=false

LOCAL_IP=192.168.4.44
SERVER_ROOT_CA_PATH=/Users/jwong/code/certificates/device.test.peridio.com.pem
DEVICE_PRIVATE_KEY_PATH=/Users/jwong/code/certificates/end-entity-private-key.pem
DEVICE_CERTIFICATE_PATH=/Users/jwong/code/certificates/end-entity-certificate.pem

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --build|-b)
      BUILD=true
      shift
      ;;
    --run|-r)
      RUN=true
      shift
      ;;
    --shell|-s)
      SHELL=true
      shift
      ;;
    --kill|-k)
      KILL=true
      shift
      ;;
    --clean|-c)
      CLEAN=true
      shift
      ;;
    --seed|-p)
      SEED_CACHE=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --build, -b    Build the Docker image"
      echo "  --run, -r      Run the container with peridiod (persistent)"
      echo "  --shell, -s    Run the container with shell access"
      echo "  --kill, -k     Kill the running peridiod container"
      echo "  --clean, -c    Remove the peridiod container and cache volume"
      echo "  --seed, -p     Pre-seed cache with 50% of fw.bin for resume testing"
      echo "  --help, -h     Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0 --build --run    # Build and run persistently"
      echo "  $0 --build          # Build only"
      echo "  $0 --run            # Run only (persistent)"
      echo "  $0 --shell          # Run with shell for debugging"
      echo "  $0 --kill           # Kill running container"
      echo "  $0 --clean          # Clean up container and volumes"
      echo "  $0 --seed --run     # Seed cache with partial file and run"
      exit 0
      ;;
    *)
      echo "Unknown option $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Container and volume names
CONTAINER_NAME="peridiod-dev"
VOLUME_NAME="peridiod-cache"
FIRMWARE_UUID="test-firmware-uuid-2d41414b-df0a-4828-b340-338f3f224c75"

# Handle kill command
if [[ "$KILL" == true ]]; then
  echo "Killing peridiod container..."
  docker kill "$CONTAINER_NAME" 2>/dev/null || echo "Container not running"
  exit 0
fi

# Handle clean command
if [[ "$CLEAN" == true ]]; then
  echo "Cleaning up peridiod container and cache volume..."
  docker kill "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "$VOLUME_NAME" 2>/dev/null || true
  echo "Cleanup complete!"
  exit 0
fi

# Function to seed cache with partial file
seed_cache() {
  echo "Seeding cache with 50% of fw.bin for resume testing..."

  # Check if fw.bin exists
  if [[ ! -f "fw.bin" ]]; then
    echo "Error: fw.bin not found in current directory"
    exit 1
  fi

  # Get file size and calculate 50%
  FILE_SIZE=$(wc -c < fw.bin)
  HALF_SIZE=$((FILE_SIZE / 2))

  echo "Original file size: $FILE_SIZE bytes"
  echo "Creating partial file: $HALF_SIZE bytes (50%)"

  # Create partial file
  head -c $HALF_SIZE fw.bin > fw.bin.partial

  # Create volume if it doesn't exist
  docker volume create "$VOLUME_NAME" >/dev/null 2>&1 || true

  # Copy partial file into volume using temporary container
  echo "Copying partial file to cache volume..."
  docker run --rm \
    -v "$VOLUME_NAME:/var/lib/peridiod" \
    -v "$(pwd)/fw.bin.partial:/tmp/fw.bin.partial" \
    alpine sh -c "
      mkdir -p /var/lib/peridiod/downloads/$FIRMWARE_UUID &&
      cp /tmp/fw.bin.partial /var/lib/peridiod/downloads/$FIRMWARE_UUID/firmware.bin &&
      ls -la /var/lib/peridiod/downloads/$FIRMWARE_UUID/
    "

  # Clean up temporary file
  rm fw.bin.partial

  echo "Cache seeded successfully!"
}

# Handle seed command
if [[ "$SEED_CACHE" == true ]]; then
  seed_cache
fi

# If no flags provided, default to build and run
if [[ "$BUILD" == false && "$RUN" == false && "$SHELL" == false ]]; then
  BUILD=true
  RUN=true
fi

# Build if requested
if [[ "$BUILD" == true ]]; then
  echo "Building Docker image..."
  docker build -f Containerfile -t peridiod .
  echo "Build complete!"
fi

# Run if requested
if [[ "$RUN" == true ]]; then
  echo "Creating cache volume if it doesn't exist..."
  docker volume create "$VOLUME_NAME" >/dev/null 2>&1 || true

  # Seed cache if requested and not already done
  if [[ "$SEED_CACHE" == true ]]; then
    seed_cache
  fi

  echo "Stopping and removing existing container if running..."
  docker kill "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true

  echo "Running peridiod container (persistent)..."
  docker run -it \
    --name "$CONTAINER_NAME" \
    --network host \
    --add-host="device.test.peridio.com:$LOCAL_IP" \
    -v "$(pwd)/support/peridio.json:/etc/peridiod/peridio.json" \
    -v "$(pwd)/support/shadow.sh:/etc/peridiod/shadow.sh" \
    -v "$SERVER_ROOT_CA_PATH:/etc/peridiod/ca-cert.pem:ro" \
    -v "$VOLUME_NAME:/var/lib/peridiod" \
    -e PERIDIO_PRIVATE_KEY="$(base64 < $DEVICE_PRIVATE_KEY_PATH)" \
    -e PERIDIO_CERTIFICATE="$(base64 < $DEVICE_CERTIFICATE_PATH)" \
    peridiod
fi
```
