#!/bin/bash

# Attempt to sync time from an Iranian server first
try_set_time() {
  local url="$1"
  local date_str=$(curl -fsI "$url" | grep -i '^Date:' | sed 's/Date: //I' | tr -d '\r')
  if [ -n "$date_str" ]; then
    date -s "$date_str" && echo "✅ Time synced from: $url"
    return 0
  fi
  return 1
}

success=0

# Prefer Iranian servers first
IRANIAN_SOURCES=(
  "http://time.ir"
  "http://ac.ir"
)

INTERNATIONAL_SOURCES=(
  "http://google.com"
  "http://worldtimeapi.org/api/ip"
)

for src in "${IRANIAN_SOURCES[@]}"; do
  if try_set_time "$src"; then
    success=1
    break    # Stop trying more if one worked
  fi
done

if [ $success -eq 0 ]; then
  for src in "${INTERNATIONAL_SOURCES[@]}"; do
    if try_set_time "$src"; then
      success=1
      break
    fi
  done
fi

if [ $success -eq 0 ]; then
  echo "⚠️ Time sync failed from all sources. Continuing without update."
fi
