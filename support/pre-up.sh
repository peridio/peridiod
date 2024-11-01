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
  echo 0 > "$COUNTER_FILE"
fi

# Read the current counter value
COUNTER=$(cat "$COUNTER_FILE")

# If its the first connection, start the ssh service
if [ "$COUNTER" -le 0 ]; then
  case $DPORT in
    22)
      /usr/sbin/sshd &
      ;;
    *)
      ;;
  esac
fi

# Increment the counter
COUNTER=$((COUNTER + 1))

# Write the updated counter back to the file
echo "$COUNTER" > "$COUNTER_FILE"
