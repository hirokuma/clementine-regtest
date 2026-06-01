#!/bin/bash -u

CLI="bitcoin-cli -regtest -rpcport=20443 -rpcuser=admin -rpcpassword=admin -rpcwallet=admin"

function utc_time() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

if [[ $# -eq 1 ]] && [[ $1 == "generate" ]]; then
    addr=$($CLI getnewaddress)
    $CLI generatetoaddress 1 $addr
    $CLI getblockcount
elif [[ $# -eq 2 ]] && [[ $1 == "generate" ]]; then
    addr=$($CLI getnewaddress)
    if [[ $2 == "auto" ]]; then
        REPEAT=30
        echo "ブロック自動生成: $REPEAT 秒"
        while :
        do
            $CLI generatetoaddress 1 $addr > /dev/null
            cnt=$($CLI getblockcount)
            echo "$(utc_time): block count=$cnt"
            sleep $REPEAT
        done
    else
        $CLI generatetoaddress $2 $addr
        $CLI getblockcount
    fi
else
    $CLI $@
fi
