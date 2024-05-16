#!/usr/bin/env bash
#
# Args
# 1: Wireguard Network Interface Name
# 2: Destination service port number

set -e

IFNAME=$1
DPORT=$2

COUNTER_FILE="/tmp/peridio_counter_${DPORT}"

if [[ ! -f "$COUNTER_FILE" ]]; then
  COUNTER=1
fi

# Read the current counter value
COUNTER=$(cat "$COUNTER_FILE")

# Decrement the counter
COUNTER=$((COUNTER + -1))

# Write the updated counter back to the file
echo "$COUNTER" > "$COUNTER_FILE"

echo "Current counter value: $COUNTER"

# If its the last connection, stop the ssh service
if [ "$COUNTER" -le 0 ]; then
  case $DPORT in
    22)
      service ssh stop
      ;;
    *)
      ;;
  esac
fi
