#!/bin/bash

COMPOSE_FILE="scripts/docker/docker-compose.full.regtest.yml"

function help() {
  echo "Help:"
  echo "  $0 up   : up"
  echo "  $0 down : down"
  echo "  $0 logs : logs"
  echo "  $0 build: docker build clementine"
}

if [[ $1 == "up" ]]; then
  docker compose -f $COMPOSE_FILE up
elif [[ $1 == "down" ]]; then
  docker compose -f $COMPOSE_FILE down -v
elif [[ $1 == "logs" ]]; then
  if [[ $# -eq 2 && "$2" == "verifier" ]]; then
    docker compose -f $COMPOSE_FILE logs clementine_verifier_regtest_0 | ansifilter
  else
    docker compose -f $COMPOSE_FILE logs $2 | ansifilter
  fi
elif [[ $1 == "build" ]]; then
  echo "cargo build:"
  log=$(RUSTFLAGS="-Awarnings" cargo build --bin clementine-cli 2>&1)
  err=$?
  echo "$log"
  if [[ $err -ne 0 ]]; then
    echo "cargo build error"
    exit 1
  fi
  echo "docker build:"
  docker build -f scripts/docker/Dockerfile -t chainwayxyz/clementine:latest .
else
  help
fi
