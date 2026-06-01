#!/bin/bash

source myenv.sh

rm -rf ~/.clementine
rm -f  ./scripts/docker/configs/regtest/.env.regtest-hirokuma \
    $WITHDRAW_UTXO_FILE $WITHDRAW_UTXO_FILE $WITHDRAW_SIGN_FILE

# "run-docker.sh down"した状態で実行しよう
if [[ $# -eq 1 ]] && [[ $1 == "all" ]]; then
    ./run-docker.sh down
    rm -rf ./core/certs
    rm -f $EMERGENCY_PRIVKEY $EMERGENCY_PUBKEY
    #rm -f $CLEMENTINE_CLI
    #rm -f bitvm_cache.bin 
fi
