#!/bin/bash

PSQL="psql -h localhost -p 5432 -U clementine -d clementine0 -P pager=off -x"

# withdrawals
#   - idx
#   - move_to_vault_txid: デポジットしたTXID(vout indexは無し)
#   - withdrawal_utxo_txid
#   - withdrawal_utxo_vout
#   - withdrawal_batch_proof_bitcoin_block_height
#   - payout_txid
#   - payout_payer_operator_xonly_pk
#   - payout_tx_blockhash
#   - is_payout_handled: 支払い済みかどうか
#   - kickoff_txid
#   - created_at
TABLE="withdrawals"


if [[ $# -eq 1 ]]; then
  TABLE=$1
fi
$PSQL -c "SELECT * from $TABLE;"
exit 0
