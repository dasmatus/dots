#!/bin/sh
output=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)
if echo "$output" | grep -q MUTED; then
    echo "󰓄"
else
    vol=$(echo "$output" | awk '{printf "%.0f", $2 * 100}')
    echo "󰓃 ${vol}%"
fi
