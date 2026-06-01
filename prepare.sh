#!/bin/bash

source myenv.sh

# clementine-core image
cnt=$(docker images | grep -c "clementine:latest" || true)
if [[ $cnt -eq 0 ]]; then
  echo "❌️ You don't have clementine docker image."
  echo "    ./run-docker.sh build"
  exit 1
else
  echo "🌞Has clementine docker image"
fi

# CLEMENTINE-CLI
CLEMENTINE_CLI_URL="https://github.com/hirokuma/clementine-cli-regtest/releases/download/v0.1.0-hirokuma-withdraw2/clementine-cli"
if [[ -f $CLEMENTINE_CLI ]]; then
  sha=$(sha256sum $CLEMENTINE_CLI)
  cnt=$(echo $sha | grep -c "5d38733d615a5506082ce1e4d4e9e4d2b998fe1f3c31f63a8449587adfc9faca" || true)
  if [[ $cnt -eq 0 ]]; then
    echo "CLEMENTINE_CLI checksum not same. Remove file."
    rm -f $CLEMENTINE_CLI
  fi
fi
if [[ ! -f $CLEMENTINE_CLI ]]; then
  echo "🌞Download clementine-cli: $CLEMENTINE_CLI_URL"
  mkdir -p target
  wget -q -O $CLEMENTINE_CLI $CLEMENTINE_CLI_URL
  chmod u+x $CLEMENTINE_CLI
else
  echo "🌞Has clementine-cli"
fi

# Emergency Stop Encryption Key
if [[ ! -f $EMERGENCY_PRIVKEY ]]; then
  echo "🌞Generate Emergency Stop Encryption Private Key"
  openssl genpkey -algorithm X25519 -out $EMERGENCY_PRIVKEY
else
  echo "🌞Has Emergency Stop Encryption Private Key"
fi
if [[ ! -f $EMERGENCY_PUBKEY ]]; then
  echo "🌞Generate Emergency Stop Encryption Public Key"
  openssl pkey -in $EMERGENCY_PRIVKEY -pubout -out $EMERGENCY_PUBKEY
else
  echo "🌞Has Emergency Stop Encryption Public Key"
fi
EMERGENCY_STOP_ENCRYPTION_PUBLIC_KEY=$(openssl pkey -pubin -in $EMERGENCY_PUBKEY -outform DER | tail -c 32 | xxd -p -c 32)

FILE_ORG="./scripts/docker/configs/regtest/.env.regtest"
FILE="./scripts/docker/configs/regtest/.env.regtest-hirokuma"
VAR_NAME="EMERGENCY_STOP_ENCRYPTION_PUBLIC_KEY"
VAR_VALUE="$EMERGENCY_STOP_ENCRYPTION_PUBLIC_KEY"
cat $FILE_ORG | sed "s|^${VAR_NAME}=.*|${VAR_NAME}=${VAR_VALUE}|" > $FILE

## BitVM bin
if [[ ! -f bitvm_cache.bin ]]; then
  echo "🌞Generate BitVM cache file(takes many time...)"
  #RUSTFLAGS="-Awarnings" cargo run --bin clementine-core -- generate-bitvm-cache
  touch bitvm_cache.bin bitvm_cache_dev.bin
  docker run --name clementine-bitvm -v ./bitvm_cache.bin:/bitvm_cache.bin -t chainwayxyz/clementine generate-bitvm-cache
else
  echo "🌞Has BitVM cache file"
fi

# Certs
if [[ ! -d ./core/certs ]]; then
  echo "🌞Generate Cert files"
  scripts/generate_certs.sh
else
  echo "🌞Has Cert files"
fi

$($CLEMENTINE_CLI show-config --network regtest > /dev/null)
if [[ $? -ne 0 ]]; then
  if [[ -f $HOME/.clementine/bridge_cli_config.toml ]]; then
    mv $HOME/.clementine/bridge_cli_config.toml $HOME/.clementine/bridge_cli_config.toml.bak
  fi
  echo "🌞CCLI init"
  $CLEMENTINE_CLI init
  cat << EOS >> $HOME/.clementine/bridge_cli_config.toml

[regtest]
network = "regtest"
aggregated_public_key = "30ff95ec2726938072a2009f3276cd8fba2363d9284a7eb01217b2f302eb8577"
citrea_chain_id = 5655
citrea_rpc_url = "http://127.0.0.1:12345"
citrea_backend_endpoint = "http://127.0.0.1:33333"
withdrawal_sign_url = "http://127.0.0.1:12345/"
user_takes_after = 200
bridge_amount = 1000000000
optimistic_withdrawal_amount = 999999760
operator_withdrawal_amount = 997000000
operator_withdrawal_fee_sats = 0
dust_utxo_amount = 330
bridge_contract_address = "0x3100000000000000000000000000000000000002"
move_tx_finalization_blocks = 5

[regtest.bitcoin_config]
url = "http://127.0.0.1:20443/wallet/admin"
user = "admin"
password = "admin"
EOS
else
  echo "🌞Has $HOME/.clementine/bridge_cli_config.toml"
fi

CNT=$($CLEMENTINE_CLI wallet list | grep -c regtest || true)
if [[ $CNT -eq 0 ]]; then
  # echo "🌞CCLI wallet create $DEPOSIT_WALLET_NAME deposit"
  # $CLEMENTINE_CLI wallet create --network regtest $DEPOSIT_WALLET_NAME deposit
  # RECOVERY_ADDR=$($CLEMENTINE_CLI wallet list | grep $DEPOSIT_WALLET_NAME | sed -e "s/Label:.*\(dep[^ ]*\),.*/\1/")
  # echo "🌞CCLI deposit start $RECOVERY_ADDR $EVM_ADDR
  # $CLEMENTINE_CLI deposit start --network regtest $RECOVERY_ADDR $EVM_ADDR

  echo "🌞CCLI wallet create $WITHDRAW_WALLET_NAME withdrawal"
  $CLEMENTINE_CLI wallet create --network regtest $WITHDRAW_WALLET_NAME withdrawal
  SIGNER_ADDR=$($CLEMENTINE_CLI wallet list | grep $WITHDRAW_WALLET_NAME | sed -e "s/Label:.*\(wit[^ ]*\),.*/\1/")
  echo "🌞CCLI withdraw start $SIGNER_ADDR $DEST_ADDR"
  $CLEMENTINE_CLI withdraw start --network regtest $SIGNER_ADDR $DEST_ADDR
else
  echo "🌞Has local withdrawal wallet"
fi
