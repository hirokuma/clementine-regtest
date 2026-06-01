# Docker Compose版

初回は環境変数`EVM_ADDR`と`DEST_ADDR`を設定してから`prepare.sh`を実行する。  
どちらも"clementine-cli"リポジトリの`clementine-cli`で使用する。
RegTestの場合はBTCがなくなっても困らないので`DEST_ADDR`は適当でもよい。

## 環境準備

* Docker
* psql

```bash
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
sudo apt install postgresql-18
```

* [foundry](https://www.getfoundry.sh/introduction/installation)
  * EVMアクセス用
* 実行環境のスペック
  * RAMが16GB、swapが16GB程度必要だった(swap 4GBだと不足した)。

## 自作スクリプトファイル

### 準備

```bash
./prepare.sh
```

* Dockerイメージがなければ終了
  * `./run-docker.sh build`でビルドする
* `./target/`の下に`clementine-cli`がない or バイナリが異なるならGitHubからダウンロードする
* Emergency Stop Encryption Keyがなければ作成する
* `./scripts/docker/configs/regtest/.env.regtest-hirokuam`を作成
* `./bitvm_cache.bin`がなければ作成するコマンドを実行
  * 非常に時間がかかる
  * [usage](https://github.com/chainwayxyz/clementine/blob/v0.6.5/docs/usage.md)にあるURLで取得したファイルではダメだった
* `./core/certs/`がなければ作成するコマンドを実行
* `~/.clementine/bridge_cli_config.toml`がなければ作成する
  * `EMERGENCY_STOP_ENCRYPTION_PUBLIC_KEY`の更新
* Withdrawal用ウォレットがなければ作成する

### ノード立ち上げ

* Dockerイメージのビルド

```bash
./run-docker.sh build
```

* RegtestのDocker Compose環境に必要なノードが立ち上がる。

```bash
./run-docker.sh up
```

* 停止は`up`の代わりに`down`を使う。他のデータも削除して良いなら`clean.sh all`でも停止する。

```bash
./run-docker.sh down
```

* Docker Composeのログ出力

```bash
./run-docker.sh logs
```

### withdraw関連

depositのように一度に実行するのではなく、順次コマンドを打ち込んでいく。

```bash
./scripts/run-withdraw.sh [COMMAND]
```

### bitcoin-cli

```bash
./bcli.sh [COMMAND]
```

### clean

`clementine-cli`で使用する範囲のファイルを削除。

```bash
./clean.sh
```

docker composeで使用する範囲も含めてファイルを削除。

```bash
./clean.sh all
```

どちらもBitVMのファイルは削除しない。

## 現時点の使い方

1. `cp .myenv-example .myenv`
1. 必要があれば`.myenv`を編集
1. `./run-docker.sh build`  (時間がかかる)

### Prepare & Nodes start

1. `./clean.sh all`
   * 鍵設定などを削除
   * 単なる`./clean.sh`だけならクライアントのウォレット情報を削除するだけなのでdockerコンテナは動いていても良い
1. `./prepare.sh`
1. (途中で入力を求められる歌唱はEnterを押していく。スクリプトが終わるまで19回くらいか。)
1. `./run-docker.sh up`

### Deposit

1. `./scripts/run-deposit_docker_no_auto.sh` (+10 cBTC)
  * `EVM_ADDR`にデポジットされる
1. もう一度 `./scripts/run-deposit_docker_no_auto.sh` (+10 cBTC = 20 cBTC)
   * 2回デポジットするのは、withdrawするのは10 cBTCだがコントラクトを呼び出すGas代も必要なため

### Withdraw

1. `./scripts/run-withdraw.sh sendtosigner`
   * 330 satsを送金
1. `./scripts/run-withdraw.sh gensigs`
1. (ウォレットへのパスフレーズを設定していないならEnterだけ押す)
1. `./scripts/run-withdraw.sh withdraw`
1. (Citrea EVMアカウントの秘密鍵 64文字HEXを打ち込む。不可視。)
   * EVM上でburnコントラクト実行
   * DB withdrawsテーブルに330sats送金が載るのを待つ
   * `aggregator new-withdrawal`を実行
     * 成功すればOperatorがユーザ(`DEST_ADDR`)に立て替えて払い戻すトランザクション展開まで行われる

### Reimbursement

1. `./scripts/run-withdraw.sh reimbursement_sequence`
  * Operatorが立て替えた支払いをClementineから払い戻すリクエストを reimbursement と呼んでいる
    * BitVM2のKickOff以降の処理で、ClementineはwithdrawごとにKickOffを開始せずまとめて行うようになっている。
  * `get-reimbursement-txs`を繰り返し呼ぶことで次に必要なトランザクションを実行する
  * よくわからず失敗したときは再度`reimbursement_sequence`を実行すれば良い
  * "Reimbursement done."のログが出たら払い戻しが終わっている

### 後始末

1. コンソールのログを適当にコピー＆ペーストしてテキストファイルに残す
1. `./run-docker.sh logs > dockerのログ` などとして別のファイルにログを残す
   * ログの時間はdocker compose service単位で前後するので見るときには注意
1. `./run-docker.sh up`したコンソールではログが出続けているので Ctrl+C を2回押して止める
1. `./run-docker.sh down` でvolumeごと削除
   * `./clean.sh all` すると `./run-docker.sh down`も一緒に実行される

## 不明点

### Citrea Backend Endpoint

[clementine-cli](https://github.com/chainwayxyz/clementine-cli)がしばしば使用する。
`$HOME/.clementine/bridge_cli_config.toml`の`citrea_backend_endpoint`に設定すると呼び出すようなのだが、
Citreaのリポジトリにはそのbackendに相当するサーバアプリが公開されていないように見える。

mainnetでは[https://api.mainnet.citrea.xyz/](https://api.mainnet.citrea.xyz/)のようなSwagger UIのページになっている。
`clementine-cli deposit status`などが失敗する。  
おそらくwithdrawもbackendがあればもっと簡単にできるのだと思う。

また、backendがないとautomation機能が使えないそうである(DeepWiki情報)。
automation機能が使えないとReimbursementでChallengeができないとのこと。

### Emergency Stop

`EMERGENCY_STOP_ENCRYPTION_PUBLIC_KEY`は何の緊急停止なのか？

### Withdrawの名称

[ドキュメント](https://docs.citrea.xyz/essentials/using-clementine/clementine-cli/withdraw#step-5-generate-withdrawal-signatures)を見ると、Optimistic withdrawal と Operator-Paid withdrawal があるように見える。
通常は Optimistic withdrawal で、12時間以内に完了しなかったら Operator-Paid withdrawal を実行するように読める。

[clementine.proto](https://github.com/chainwayxyz/clementine/blob/v0.6.5/core/src/rpc/clementine.proto)を見ると`Withdraw`と`OptimisticPayout`があり、
CLIコマンドとしては[new-withdrawal](https://github.com/chainwayxyz/clementine/blob/v0.6.5/core/src/bin/cli.rs#L173)と[new-optimistic-withdrawal](https://github.com/chainwayxyz/clementine/blob/v0.6.5/core/src/bin/cli.rs#L191)があるように見える。

おそらく、ドキュメントでいう "Optimistic withdrawal" は Clementineでいうところの "new-withdrawal"で、
"Operator-Paid withdrawal" は "new-optimistic-withdrawal" である。  
Citrea Backendがないためつながりははっきりしない。

### Withdrawのoperator報酬

"new-withdrawal"でoperatorからユーザへwithdrawする場合、operatorが利益として`OPERATOR_WITHDRAWAL_FEE_SATS`以上を確保することを確認している。
withdrawでユーザがいくら払い戻してほしいのかは"new-withdrawal"のオプションで示し、
トランザクションに署名までするのでoperatorで変更することはできない。  

[ドキュメント](https://docs.citrea.xyz/essentials/using-clementine/clementine-cli/withdraw#step-3-send-required-bitcoin-transaction)ではユーザが330sats支払うことを想定している。
しかし 330sats で"new-withdrawal"を実行すると"Not enough fee for operator"エラーになる。
`--output-amount`を減らしてoperatorの利益を増やすとよいのだが、
そうするとトランザクションが変わって`--input-signature`の署名が`OPTIMISTIC_SIGNATURE`と不一致になる。

当初はコマンドを改造して`--output-amount`を減らした署名を返すようにしていたのだが、
今は`OPERATOR_WITHDRAWAL_FEE_SATS=0`と変数を変更して`OPTIMISTIC_SIGNATURE`を使用できるようにしている。
その方向性で正しいのかは判断できない。
