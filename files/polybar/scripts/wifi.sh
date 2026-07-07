#!/bin/sh
ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '/^(yes|ja|oui|sì|sim)/{print $2}')
if [ -n "$ssid" ]; then
    echo "󰖩 $ssid"
else
    echo "󱚼"
fi
