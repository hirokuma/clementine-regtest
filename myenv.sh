# Emergency Stop Encryption Key
EMERGENCY_PRIVKEY=emergency_stop_private.pem
EMERGENCY_PUBKEY=emergency_stop_public.pem

CLEMENTINE_CLI="./target/clementine-cli"

DEPOSIT_WALLET_NAME=depwallet
WITHDRAW_WALLET_NAME=witwallet

BCLI="./bcli.sh"
WITHDRAW_UTXO_FILE="./withdraw-utxo.env"
WITHDRAW_SIGN_FILE="./withdraw-sign.env"

if [[ -f .myenv ]]; then
    source .myenv
fi
