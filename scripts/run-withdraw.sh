#!/bin/bash

source myenv.sh

# not $CLEMENTINE_CLI
export RUSTFLAGS="-Awarnings"
CLI="cargo run --bin clementine-cli --"

AGGREGATOR_NODE_URL=https://127.0.0.1:17000
OPT_RPCURL="--rpc-url http://127.0.0.1:12345"
PSQL="psql -h localhost -p 5432 -U clementine -d clementine0 -A -t -F ,"
PSQL_SHOW="psql -h localhost -p 5432 -U clementine -d clementine0 -P pager=off -x"
WATCH_PERIOD=60

BITCOIN_RPC_URL="http://127.0.0.1:20443/wallet/admin"
BITCOIN_RPC_USER="admin"
BITCOIN_RPC_PASSWORD="admin"

# scripts/docker/docker-compose.full.regtest.ymlとscripts/docker/configs/regtest/.env.regtestより
declare -A OPERATOR_URL
OPERATOR_URL["4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa"]="https://127.0.0.1:17005" # 0x0101...0101のxonly pubkey
OPERATOR_URL["466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27"]="https://127.0.0.1:17006" # 0x0202...0202のxonly pubkey

function help() {
    echo "Help:"
    echo "  cbtc         : Get cBTC balance"
    echo "  params       : Show parameters"
    echo "  sendtosigner : Send dust BTC to Signer Address"
    echo "  gensigs      : Generate signatures"
    echo "  withdraw     : Start withdraw after 'gensigs' (type 64 hex string for EVM_ADDR private key)"
    echo "  reimbursement_sequence"
    echo "               : Reimbursement withdrawal BTC to operator"
    echo "  optimistic   : Start optimistic withdraw after 'gensigs' (type 64 hex string for EVM_ADDR private key)"
}

if [[ $# == 0 ]]; then
    help
    exit 1
fi

SIGNER_ADDR=$($CLEMENTINE_CLI wallet list | grep $WITHDRAW_WALLET_NAME | sed -e "s/Label:.*\(wit[^ ]*\),.*/\1/")

if [[ -z $EVM_ADDR ]]; then
  echo "no EVM_ADDR environment."
  exit 1
fi
if [[ -z $DEST_ADDR ]]; then
  echo "no DEST_ADDR environment."
  exit 1
fi
if [[ -z $SIGNER_ADDR ]]; then
  echo "no SIGNER_ADDR environment."
  exit 1
fi
if [[ ${SIGNER_ADDR:0:3} != "wit" ]]; then
  SIGNER_ADDR=wit$SIGNER_ADDR
fi

function utc_time() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

function parameters() {
    source "scripts/docker/configs/regtest/.env.regtest-hirokuma"
    echo
    echo "withdraw:"
    echo "  EVM Address:         $EVM_ADDR"
    echo "  Destination Address: $DEST_ADDR"
    echo "  Signer Address:      $SIGNER_ADDR"
    echo
    echo "reimbursement:"
    echo "  Operator Address: $OPERATOR_REIMBURSEMENT_ADDRESS"
    echo
    echo "blockchain:"
    echo "Bitcoin block count:   $($BCLI getblockcount)"
    echo "L2 block number:       $(cast block-number $OPT_RPCURL)"
}

function cbtc_balance() {
    cast balance $EVM_ADDR $OPT_RPCURL
}

function calls() {
    CONT_ADDR="0x3100000000000000000000000000000000000002"

    # get withdrawal count
    cast call $CONT_ADDR "getWithdrawalCount()" $OPT_RPCURL

    # 特定インデックスのwithdrawal UTXOを確認  
    cast call $CONT_ADDR "withdrawalUTXOs(uint256)" 0 $OPT_RPCURL
}

function l2height() {
    # light client proverにlightClientProver_getLightClientProofByL1Height
    # L1ブロック高に対するL2 proofの取得
    height=$($BCLI getblockcount)
    height=$((height - 4)) # よくわからないが4ブロックくらい前じゃないと成功しない
    curl -s -X POST http://127.0.0.1:12349 -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"lightClientProver_getLightClientProofByL1Height","params":['$height'],"id":1}' | jq .
}

# CCLIで決めたSigner Addressに330sats送金する。
# これは WITHDRAW_UTXO と呼ばれ、withdrawするトランザクションのinputの1つになる。
# Step 3: Send Required Bitcoin Transaction
# https://docs.citrea.xyz/essentials/using-clementine/clementine-cli/withdraw#step-3-send-required-bitcoin-transaction
function sendto_signer() {
    echo "🌞bitcoin-cli sendtoaddress ${SIGNER_ADDR:3} 330sats"
    TXID=$($BCLI sendtoaddress ${SIGNER_ADDR:3} 0.0000033)

    # なんとなく5ブロック？
    echo "🌞Generate 5 block"
    $BCLI -generate 5
    sleep 2

    RAW_TX_JSON=$($BCLI getrawtransaction $TXID 1)
    VOUT_INDEX=$(echo "$RAW_TX_JSON" | jq -r --arg addr "${SIGNER_ADDR:3}" '.vout[] | select(.scriptPubKey.address == $addr) | .n')
    echo "🌞Save WITHDRAW_UTXO to $WITHDRAW_UTXO_FILE"
    echo "WITHDRAW_UTXO=$TXID:$VOUT_INDEX" > $WITHDRAW_UTXO_FILE
    cat $WITHDRAW_UTXO_FILE
    echo
    echo "Next: $0 gensigs"
}

# 署名作成。
# WITHDRAW_SIGNATUREの取得のためCLEMENTINE_CLIは改造されている必要がある
#  https://github.com/hirokuma/clementine-cli-regtest/commit/c4029fb41a754a9e80bd6231247474a955049328
# Step 5: Generate Withdrawal Signatures
function generate_sigs() {
    if [[ ! -f $WITHDRAW_UTXO_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_UTXO_FILE"
        exit 1
    fi
    source $WITHDRAW_UTXO_FILE

    echo "🌞CCLI withdraw generate-withdrawal-signatures $SIGNER_ADDR $DEST_ADDR $WITHDRAW_UTXO"
    result=$($CLEMENTINE_CLI withdraw generate-withdrawal-signatures --network regtest \
        $SIGNER_ADDR $DEST_ADDR $WITHDRAW_UTXO)
    OPTIMISTIC_SIGNATURE=$(echo "$result" | grep "Optimistic withdrawal signature hex: " | sed -e "s/Optimistic withdrawal signature hex: \([^ ]*\)/\1/g")
    OPERATOR_PAID_SIGNATURE=$(echo "$result" | grep "Operator-paid withdrawal signature hex: " | sed -e "s/Operator-paid withdrawal signature hex: \([^ ]*\)/\1/g")
    WITHDRAW_SIGNATURE=$(echo "$result" | grep "Normal withdrawal signature hex: " | sed -e "s/Normal withdrawal signature hex: \([^ ]*\)/\1/g")
    echo "$result"
    echo
    echo "🌞Generated Signatures"
    echo "OPTIMISTIC_SIGNATURE=$OPTIMISTIC_SIGNATURE" > $WITHDRAW_SIGN_FILE
    echo "OPERATOR_PAID_SIGNATURE=$OPERATOR_PAID_SIGNATURE" >> $WITHDRAW_SIGN_FILE
    echo "WITHDRAW_SIGNATURE=$WITHDRAW_SIGNATURE" >> $WITHDRAW_SIGN_FILE
    cat $WITHDRAW_SIGN_FILE
    echo
    echo "Next: $0 withdraw"
}

# Safe Withdraw
# https://docs.citrea.xyz/essentials/using-clementine/clementine-cli/advanced#safe-withdraw
function safe_withdraw() {
    if [[ ! -f $WITHDRAW_UTXO_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_UTXO_FILE"
        exit 1
    fi
    source $WITHDRAW_UTXO_FILE

    if [[ ! -f $WITHDRAW_SIGN_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_SIGN_FILE"
        exit 1
    fi
    source $WITHDRAW_SIGN_FILE
    echo "Before cBTC=$(cbtc_balance)"
    echo

    echo "🌞Call Burn contract on Citrea: $(utc_time)"
    echo "🌞CCLI withdraw send-safe-withdraw $SIGNER_ADDR $DEST_ADDR $WITHDRAW_UTXO OPTIMISTIC_SIGNATURE"
    result=$(RUST_LOG=info $CLEMENTINE_CLI withdraw send-safe-withdraw --network regtest --verbose \
        $SIGNER_ADDR $DEST_ADDR $WITHDRAW_UTXO $OPTIMISTIC_SIGNATURE)
    echo "$result"

    sleep 2
    txhash=$(echo "$result" | grep "Transaction Hash: " | sed -e "s/Transaction Hash: \(0x[^ ]*\)/\1/g")
    echo
    echo "After cBTC=$(cbtc_balance)"
    echo

    result=$(cast receipt $txhash $OPT_RPCURL)
    echo "🌞cast receipt $txhash"
    echo "$result"
    echo
    blocknum=$(echo "$result" | grep "^blockNumber" | sed -e "s/^blockNumber *\([^0-9]*\)/\1/g")

    result=$(cast logs --from-block $blocknum --to-block $blocknum $OPT_RPCURL)
    echo "🌞cast logs from $blocknum"
    echo "$result"
    echo
    echo "🌞transaction hash: $txhash"
    echo "🌞    block number: $blocknum"
    echo
    parameters
}

# WITHDRAW_UTXOがwithdrawalsテーブルに現れるのを待つ
function wait_withdraw_utxo() {
    echo "🌞Watch withdrawal_utxo_txid ($WATCH_PERIOD sec)"

    if [[ ! -f $WITHDRAW_UTXO_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_UTXO_FILE"
        exit 1
    fi
    source $WITHDRAW_UTXO_FILE
    echo "    WITHDRAW_UTXO=$WITHDRAW_UTXO"

    PSQL_TXID="\\x$(echo "${WITHDRAW_UTXO:0:64}" | fold -w 2 | tac | tr -d '\n')"
    PSQL_VOUT=$(echo "${WITHDRAW_UTXO:65}")

    while true; do
        echo "$(utc_time)"
        # withdrawal_utxo_txidが一致するidx取得
        idx=$($PSQL -c "SELECT idx FROM withdrawals WHERE withdrawal_utxo_txid='$PSQL_TXID' AND withdrawal_utxo_vout=$PSQL_VOUT;")
        if [[ -n "$idx" ]]; then
            break
        fi
        $PSQL -c "SELECT idx,withdrawal_utxo_txid FROM withdrawals;"

        $BCLI -generate > /dev/null
        $BCLI getblockcount
        sleep $WATCH_PERIOD
    done

    payout_txid=$($PSQL -c "SELECT payout_txid FROM withdrawals WHERE idx=$idx;")
    if [[ -n $payout_txid ]]; then
        echo "❌️ idx $idx already used."
        $PSQL_SHOW -c "SELECT * FROM withdrawals WHERE idx=$idx;"
        exit 1
    fi

    $PSQL_SHOW -c "SELECT * FROM withdrawals WHERE idx=$idx;"
    echo "🌞Detect withdraw UTXO on Database: $(utc_time)"
}


# Operatorからユーザへのwithdraw立て替え払い
function withdraw_payout() {
    if [[ ! -f $WITHDRAW_UTXO_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_UTXO_FILE"
        exit 1
    fi
    source $WITHDRAW_UTXO_FILE

    if [[ ! -f $WITHDRAW_SIGN_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_SIGN_FILE"
        exit 1
    fi
    source $WITHDRAW_SIGN_FILE

    # optimistic_withdrawal_amount = 999999760 = 10 BTC - 240 sats(Non-Ephemeral anchor amount)
    # さらにoperatorの利益を引く
    NON_EPHEMERAL_ANCHOR_AMOUNT=240
    source "scripts/docker/configs/regtest/.env.regtest-hirokuma"
    WITHDRAWAL_AMOUNT=$(($BRIDGE_AMOUNT - $NON_EPHEMERAL_ANCHOR_AMOUNT - OPERATOR_WITHDRAWAL_FEE_SATS))
    echo "WITHDRAWAL_AMOUNT=$WITHDRAWAL_AMOUNT"

    # .myenv
    output_script_pubkey=$($BCLI getaddressinfo $DEST_ADDR | jq -cr .scriptPubKey)
    if [[ -z $output_script_pubkey ]]; then
        echo "❌️ Fail get DEST_ADDR scriptPubKey"
        exit 1
    fi

    # scripts/docker/configs/regtest/.env.regtest
    OPERATOR_XONLY_PKS="--operator-xonly-pks 4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa --operator-xonly-pks 466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27"

    # DB withdrawalsテーブルのwithdrawal_utxo_txidが埋まったほう。
    # auto_generate_btc_block()の実行が終わるまで待てば良い。
    PSQL_TXID="\\x$(echo "${WITHDRAW_UTXO:0:64}" | fold -w 2 | tac | tr -d '\n')"
    PSQL_VOUT=$(echo "${WITHDRAW_UTXO:65}")
    withdrawal_id=$($PSQL -c "SELECT idx FROM withdrawals WHERE withdrawal_utxo_txid='$PSQL_TXID' AND withdrawal_utxo_vout=$PSQL_VOUT;")
    if [[ -z $withdrawal_id ]]; then
        echo "❌️ Fail SELECT idx FROM withdrawals(withdrawal_utxo_txid='$PSQL_TXID')"
        exit 1
    fi

    # AGGREGATOR_VERIFICATION_ADDRESS未定義の場合は不要
    # SIGTYPE_SINGLE + ANYONECANPAYらしい
    # verification_signature="<HEX>"

    echo "🌞CLI aggregator new-withdrawal"
    echo
    echo -n "$CLI --node-url $AGGREGATOR_NODE_URL aggregator new-withdrawal"
    echo -n " --input-signature $WITHDRAW_SIGNATURE"
    echo -n " --input-outpoint-txid ${WITHDRAW_UTXO:0:64}"
    echo -n " --input-outpoint-vout ${WITHDRAW_UTXO:65}"
    echo -n " --output-script-pubkey $output_script_pubkey"
    echo -n " --output-amount $WITHDRAWAL_AMOUNT"
    echo -n " $OPERATOR_XONLY_PKS"
    echo -n " --withdrawal-id $withdrawal_id"
    # echo -n " --verification-signature $verification_signature"
    echo

    result=$($CLI --node-url $AGGREGATOR_NODE_URL aggregator new-withdrawal \
        --input-signature $WITHDRAW_SIGNATURE \
        --input-outpoint-txid ${WITHDRAW_UTXO:0:64} \
        --input-outpoint-vout ${WITHDRAW_UTXO:65} \
        --output-script-pubkey $output_script_pubkey \
        --output-amount $WITHDRAWAL_AMOUNT \
        $OPERATOR_XONLY_PKS \
        --withdrawal-id $withdrawal_id)
    echo "$result"
    tx=$(echo "$result" | grep "raw_tx=" | sed -e "s/.*raw_tx=\([^ ]\)/\1/")
    txid=$(echo "$result" | grep "txid=" | sed -e "s/.*txid=\(.*\),.*$/\1/")
    errs=$(echo "$result" | grep -c "error=" || true)
    if [[ $errs -eq 2 ]]; then
        echo "❌ Error: both operators failed to withdraw."
        exit 1
    fi
    echo "Decode raw transaction:"
    $BCLI decoderawtransaction $tx
    echo "txid=$txid"
}


# CLI aggregator new-withdrawal
# Operatorからユーザへのwithdraw立て替え払い
# ドキュメントの通り 330sats支払うのだが、これはfee不足でエラーになってしまう。
function withdraw_payout_original() {
    if [[ ! -f $WITHDRAW_UTXO_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_UTXO_FILE"
        exit 1
    fi
    source $WITHDRAW_UTXO_FILE

    if [[ ! -f $WITHDRAW_SIGN_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_SIGN_FILE"
        exit 1
    fi
    source $WITHDRAW_SIGN_FILE

    WITHDRAWAL_AMOUNT=999999760

    # .myenv
    output_script_pubkey=$($BCLI getaddressinfo $DEST_ADDR | jq -cr .scriptPubKey)
    if [[ -z $output_script_pubkey ]]; then
        echo "❌️ Fail get DEST_ADDR scriptPubKey"
        exit 1
    fi

    # scripts/docker/configs/regtest/.env.regtest
    OPERATOR_XONLY_PKS="--operator-xonly-pks 4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa --operator-xonly-pks 466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27"

    # DB withdrawalsテーブルのwithdrawal_utxo_txidが埋まったほう。
    # auto_generate_btc_block()の実行が終わるまで待てば良い。
    PSQL_TXID="\\x$(echo "${WITHDRAW_UTXO:0:64}" | fold -w 2 | tac | tr -d '\n')"
    PSQL_VOUT=$(echo "${WITHDRAW_UTXO:65}")
    withdrawal_id=$($PSQL -c "SELECT idx FROM withdrawals WHERE withdrawal_utxo_txid='$PSQL_TXID' AND withdrawal_utxo_vout=$PSQL_VOUT;")
    if [[ -z $withdrawal_id ]]; then
        echo "❌️ Fail SELECT idx FROM withdrawals(withdrawal_utxo_txid='$PSQL_TXID')"
        exit 1
    fi

    # AGGREGATOR_VERIFICATION_ADDRESS未定義の場合は不要
    # SIGTYPE_SINGLE + ANYONECANPAYらしい
    # verification_signature="<HEX>"

    echo "🌞CLI aggregator new-withdrawal"
    echo
    echo -n "$CLI --node-url $AGGREGATOR_NODE_URL aggregator new-withdrawal"
    echo -n " --input-signature $OPTIMISTIC_SIGNATURE"
    echo -n " --input-outpoint-txid ${WITHDRAW_UTXO:0:64}"
    echo -n " --input-outpoint-vout ${WITHDRAW_UTXO:65}"
    echo -n " --output-script-pubkey $output_script_pubkey"
    echo -n " --output-amount $WITHDRAWAL_AMOUNT"
    echo -n " $OPERATOR_XONLY_PKS"
    echo -n " --withdrawal-id $withdrawal_id"
    # echo -n " --verification-signature $verification_signature"
    echo

    result=$($CLI --node-url $AGGREGATOR_NODE_URL aggregator new-withdrawal \
        --input-signature $OPTIMISTIC_SIGNATURE \
        --input-outpoint-txid ${WITHDRAW_UTXO:0:64} \
        --input-outpoint-vout ${WITHDRAW_UTXO:65} \
        --output-script-pubkey $output_script_pubkey \
        --output-amount $WITHDRAWAL_AMOUNT \
        $OPERATOR_XONLY_PKS \
        --withdrawal-id $withdrawal_id)
    echo "$result"
    tx=$(echo "$result" | grep "raw_tx=" | sed -e "s/.*raw_tx=\([^ ]\)/\1/")
    txid=$(echo "$result" | grep "txid=" | sed -e "s/.*txid=\(.*\),.*$/\1/")
    errs=$(echo "$result" | grep -c "error=" || true)
    if [[ $errs -eq 2 ]]; then
        echo "❌️ Error: both operators failed to create withdrawal transaction."
        exit 1
    fi
    echo "Decode raw transaction:"
    $BCLI decoderawtransaction $tx
    echo "txid=$txid"
}

# withdrawしたTXIDがwithdrawalsテーブルに現れるのを待つ
function wait_payout_txid() {
    echo "🌞Watch payout_txid ($WATCH_PERIOD sec)"

    # withdrawに成功したテーブルを参照するようにしたい
    if [[ ! -f $WITHDRAW_UTXO_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_UTXO_FILE"
        exit 1
    fi
    source $WITHDRAW_UTXO_FILE
    # withdrawalsテーブルの withdrawal_utxo_txid, withdrawal_utxo_vout が一致するidx
    PSQL_TXID="\\x$(echo "${WITHDRAW_UTXO:0:64}" | fold -w 2 | tac | tr -d '\n')"
    PSQL_VOUT=$(echo "${WITHDRAW_UTXO:65}")
    idx=$($PSQL -c "SELECT idx FROM withdrawals WHERE withdrawal_utxo_txid='$PSQL_TXID' AND withdrawal_utxo_vout=$PSQL_VOUT;")
    echo "🌞 Watch idx==$idx in withdrawals(WITHDRAW_UTXO=$WITHDRAW_UTXO)"

    while true; do
        echo "$(utc_time)"
        result=$($PSQL -c "SELECT idx,payout_txid FROM withdrawals WHERE idx=$idx AND payout_tx_blockhash<>'';")
        if [[ -n "$result" ]]; then
            break
        fi
        result=$($PSQL -c "SELECT idx,payout_txid,payout_payer_operator_xonly_pk,payout_tx_blockhash FROM withdrawals WHERE idx=$idx;")
        echo "$result"

        $BCLI -generate > /dev/null
        $BCLI getblockcount
        sleep $WATCH_PERIOD
    done
    $PSQL_SHOW -c "SELECT * FROM withdrawals WHERE idx=$idx;"
    echo "🌞Detect withdrawn transaction to User on Database: $(utc_time)"
}

# operatorがユーザへの支払いを立て替える
function start_withdraw() {
    echo "🌞Start withdrawal"
    safe_withdraw
    wait_withdraw_utxo
    withdraw_payout
    wait_payout_txid

    echo "withdraw done!"
    echo
    echo "Next: $0 reimbursement_sequence"
}

# Operatorの立て替えを払い戻す一連のトランザクション作成と展開
# 戻り値はREIMBURSE_RESULTを使う
REIMBURSE_RESULT=""
function reimbursement() {
    echo "🌞Get reimbursement transaction"
    if [[ ! -f $WITHDRAW_UTXO_FILE ]]; then
        echo "❌️ File not found: $WITHDRAW_UTXO_FILE"
        exit 1
    fi
    source $WITHDRAW_UTXO_FILE

    # WITHDRAW_UTXO_FILEからwithdrawalsのidxを抽出
    PSQL_TXID="\\x$(echo "${WITHDRAW_UTXO:0:64}" | fold -w 2 | tac | tr -d '\n')"
    PSQL_VOUT=$(echo "${WITHDRAW_UTXO:65}")
    idx=$($PSQL -c "SELECT idx FROM withdrawals WHERE withdrawal_utxo_txid='$PSQL_TXID' AND withdrawal_utxo_vout=$PSQL_VOUT;")

    payout_payer_operator_xonly_pk=$($PSQL -c "SELECT payout_payer_operator_xonly_pk FROM withdrawals WHERE idx=$idx;")
    # echo "payout_payer_operator_xonly_pk: $payout_payer_operator_xonly_pk"
    echo "operator url: ${OPERATOR_URL[$payout_payer_operator_xonly_pk]}"

    # move_to_vault_txidが一致するdeposit_outpoint取得
    outpoint=$($PSQL -c "SELECT dd.deposit_outpoint FROM deposits dd INNER JOIN withdrawals ww ON ww.move_to_vault_txid = dd.move_to_vault_txid WHERE ww.idx=$idx;")
    
    # get-reimbursement-txs
    echo "$CLI --node-url ${OPERATOR_URL[$payout_payer_operator_xonly_pk]} operator get-reimbursement-txs --deposit-outpoint-txid ${outpoint:0:64} --deposit-outpoint-vout ${outpoint:65}"
    result=$($CLI --node-url ${OPERATOR_URL[$payout_payer_operator_xonly_pk]} operator get-reimbursement-txs --deposit-outpoint-txid ${outpoint:0:64} --deposit-outpoint-vout ${outpoint:65})
    read -r type tx <<< "$(echo "$result" | grep "Tx type: .*, Tx hex:" | sed -e 's/^Tx type: \([^,]*\), Tx hex: "\([^"]*\)"/\1 \2/')"
    echo "$result"

    if [[ -z $type ]]; then
        echo "😢 CPFP type not found"
        REIMBURSE_RESULT="retry"
        return
    fi

    # Send reimbursement tx with CPFP
    echo "CPFP: type=$type"
    bitcoin_cpfp $tx $type
    REIMBURSE_RESULT=$type
}

# CPFPトランザクションを展開
# おそらくbitcoin-cli submitpackageを使っている
function bitcoin_cpfp() {
    tx=$1
    type=$2
    echo "🌞bitcoin_cpfp begin($type): $(utc_time)"

    # 参考スクリプト
    # scripts/run-deposit_docker_no_auto.sh
    FEE_PAYER_AMOUNT="1"

    echo "🧾 Create TX(type=$type) (CPFP step 1)"
    FEE_PAYER_ADDRESS=$($CLI --node-url $BITCOIN_RPC_URL bitcoin send-tx-with-cpfp \
        --bitcoin-rpc-user $BITCOIN_RPC_USER \
        --bitcoin-rpc-password $BITCOIN_RPC_PASSWORD \
        --raw-tx $tx | grep -o 'bcrt1[a-zA-Z0-9]*')
    echo "Fee payer address: $FEE_PAYER_ADDRESS"

    echo "💸 Send fee to fee payer address"
    $BCLI sendtoaddress $FEE_PAYER_ADDRESS $FEE_PAYER_AMOUNT
    $BCLI generate

    echo "🧾 Finalize CPFP TX(type=$type)"
    TX_DETAILS=$($CLI --node-url $BITCOIN_RPC_URL bitcoin send-tx-with-cpfp \
        --bitcoin-rpc-user $BITCOIN_RPC_USER \
        --bitcoin-rpc-password $BITCOIN_RPC_PASSWORD \
        --fee-payer-address $FEE_PAYER_ADDRESS \
        --raw-tx $tx)

    for i in {1..2}; do
        $BCLI generate 5
        sleep 2
    done

    echo "✅ CPFP TX(type=$type) sent and confirmed."
    echo "  - TX Details: $TX_DETAILS"

    submit=$(echo "$TX_DETAILS" | sed -n '/@@@ SUBMIT_RESULT_BEGIN/,/@@@ SUBMIT_RESULT_END/p' | sed -e '/@@@ SUBMIT_RESULT_BEGIN/d' -e '/@@@ SUBMIT_RESULT_END/d')
    echo $submit | jq .
    cnt_err=$(echo $submit | grep -c "error" || true)
    if [[ $cnt_err -ne 0 ]]; then
        echo "❌ Failed to submit package($type)!"
        exit 1
    fi

    PARENT_TXID=$(echo "$TX_DETAILS" | grep -oP 'Parent transaction TXID: \K[a-f0-9]{64}')

    if [ -z "$PARENT_TXID" ]; then
        echo "❌ Failed to extract parent transaction TXID($type)!"
        exit 1
    fi
    echo "🌞bitcoin_cpfp end($type): $(utc_time)"
}

function reimbursement_sequence() {
    echo "🌞Start reimbursement to operator"

    while :; do
        sleep 10
        echo "begin------------------------------------------------"
        reimbursement
        $BCLI generate
        echo "🌞Processed tx type: $REIMBURSE_RESULT"
        echo "end------------------------------------------------"
        case $REIMBURSE_RESULT in
            "Round" | "ChallengeTimeout" | "BurnUnusedKickoffConnectors")
                continue;;
            "Kickoff" | "ReadyToReimburse")
                $BCLI generate 216
                continue;;
            "Reimburse")
                break;;
            "retry")
                echo "Retry......"
                continue;;
            *)
                echo "Exit while loop: $REIMBURSE_RESULT"
                ;;
        esac
    done

    echo
    echo "Reimbursement done: $(utc_time)"
}

# # Vault UTXOからユーザへの支払い
# function emergency_withdraw_cli() {
#     if [[ ! -f $WITHDRAW_UTXO_FILE ]]; then
#         echo "❌️ File not found: $WITHDRAW_UTXO_FILE"
#         exit 1
#     fi
#     source $WITHDRAW_UTXO_FILE

#     if [[ ! -f $WITHDRAW_SIGN_FILE ]]; then
#         echo "❌️ File not found: $WITHDRAW_SIGN_FILE"
#         exit 1
#     fi
#     source $WITHDRAW_SIGN_FILE

#     # ~/.clementine/bridge_clementine_config.toml ?
#     OPTIMISTIC_WITHDRAWAL_AMOUNT=999999760

#     # .myenv
#     output_script_pubkey=$($BCLI getaddressinfo $DEST_ADDR | jq -cr .scriptPubKey)
#     if [[ -z $output_script_pubkey ]]; then
#         echo "❌️ Fail get DEST_ADDR scriptPubKey"
#         exit 1
#     fi

#     # scripts/docker/configs/regtest/.env.regtest
#     OPERATOR_XONLY_PKS="--operator-xonly-pks 4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa --operator-xonly-pks 466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27"

#     # DB withdrawalsテーブルのwithdrawal_utxo_txidが埋まったほう。
#     # auto_generate_btc_block()の実行が終わるまで待てば良い。
#     PSQL_TXID="\\x$(echo "${WITHDRAW_UTXO:0:64}" | fold -w 2 | tac | tr -d '\n')"
#     PSQL_VOUT=$(echo "${WITHDRAW_UTXO:65}")
#     withdrawal_id=$($PSQL -c "SELECT idx FROM withdrawals WHERE withdrawal_utxo_txid='$PSQL_TXID' AND withdrawal_utxo_vout=$PSQL_VOUT;")

#     # AGGREGATOR_VERIFICATION_ADDRESS未定義の場合は不要
#     # SIGTYPE_SINGLE + ANYONECANPAYらしい
#     # verification_signature="<HEX>"

#     echo "🌞CLI aggregator new-optimistic-withdrawal"
#     echo
#     echo -n "$CLI --node-url $AGGREGATOR_NODE_URL aggregator new-optimistic-withdrawal"
#     echo -n " --input-signature $OPTIMISTIC_SIGNATURE"
#     echo -n " --input-outpoint-txid ${WITHDRAW_UTXO:0:64}"
#     echo -n " --input-outpoint-vout ${WITHDRAW_UTXO:65}"
#     echo -n " --output-script-pubkey $output_script_pubkey"
#     echo -n " --output-amount $OPTIMISTIC_WITHDRAWAL_AMOUNT"
#     echo -n " --withdrawal-id $withdrawal_id"
#     echo

#     result=$($CLI --node-url $AGGREGATOR_NODE_URL aggregator new-optimistic-withdrawal \
#         --input-signature $OPTIMISTIC_SIGNATURE \
#         --input-outpoint-txid ${WITHDRAW_UTXO:0:64} \
#         --input-outpoint-vout ${WITHDRAW_UTXO:65} \
#         --output-script-pubkey $output_script_pubkey \
#         --output-amount $OPTIMISTIC_WITHDRAWAL_AMOUNT \
#         --withdrawal-id $withdrawal_id)
#     # echo "$result"
#     tx=$(echo "$result" | grep "Tx: " | sed -e "s/Tx: //")
#     $BCLI decoderawtransaction $tx
#     $BCLI sendrawtransaction $tx
# }

# # Vault UTXOからユーザに支払う
# function start_emergency_withdraw() {
#     echo "🌞Start optimistic withdrawal"
#     safe_withdraw
#     wait_withdraw_utxo
#     optimistic_withdraw_cli
# }

CMD=$1

case $CMD in
    "help")
        help;;
    "cbtc")
        cbtc_balance;;
    "params")
        parameters;;
    "calls")
        calls;;
    "l2height")
        l2height;;
    "wait_vault")
        wait_moveto_vault;;

    "sendtosigner")
        sendto_signer;;
    "gensigs")
        generate_sigs;;
    "withdraw")
        start_withdraw;;

    "safe_withdraw")
        safe_withdraw;;
    "wait_withdraw_utxo")
        wait_withdraw_utxo;;
    "withdraw_payout")
        withdraw_payout;;
    "wait_payout_txid")
        wait_payout_txid;;

    "reimbursement")
        reimbursement;;
    "reimbursement_sequence")
        reimbursement_sequence;;

    *)
        help;;
esac
