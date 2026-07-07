#!/bin/sh
state=$(nmcli -t -f type,state dev 2>/dev/null | awk -F: '/^ethernet/{print $2; exit}')
if [ "$state" = "connected" ]; then
    ip=$(nmcli -t -f type,ip4.address dev show 2>/dev/null | awk -F: '/^ethernet/{found=1} found && /^IP4\.ADDRESS/{print $2; exit}' | cut -d/ -f1)
    echo "󰈀 ${ip:-ETH}"
fi
