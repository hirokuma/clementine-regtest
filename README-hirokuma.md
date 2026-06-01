# Docker Compose版

初回は環境変数`EVM_ADDR`と`DEST_ADDR`を設定してから`prepare.sh`を実行する。  
どちらも"clementine-cli"リポジトリの`clementine-cli`で使用する。
RegTestの場合はBTCがなくなっても困らないので`DEST_ADDR`は適当でもよい。

## 準備

* [foundry](https://www.getfoundry.sh/introduction/installation)
  * EVMアクセス用

## 準備

* `.myenv` : このファイルはgit対象外
  * `.myenv-example`は編集しなくても動作確認には使用できる
  * `EVM_ADDR`: depositするCitrea EVMアカウント(0xあり)
    * withdrawで使うので秘密鍵も把握しておくこと(0xなし)。
    * `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`と`0x70997970C51812dc3A010C7d01b50e0d17dc79C8`
  * `DEST_ADDR`: withdrawして送金するBTCアドレス(bech32mのみ)

## 手順

[現時点の使い方](#現時点の使い方)参照。

`prepare.sh`は途中で入力を求められる。  
※実験中はパスフレーズの保存はしないので、ひたすらEnter押下でよい※

```shell
$ cp .myenv-example .myenv
$ vi .myenv
......
EVM_ADDR=0x.... (cBTCをデポジットするEVMアカウント)
DEST_ADDR=bcrt1... (cBTCをウィズドローするBTCアカウント)
......

$ ./clean.sh all
$ ./prepare.sh
```

* 初回は`./target/`の下に`clementine-cli`がないのでGitHubからダウンロードする
  * `clementine-cli-v0.1.0`
* ウォレット未作成で環境変数`EVM_ADDR`が未設定の場合は終了
  * `export EVM_ADDR="0x181Bd70A1Bc17319630a7a182f48b869b21eb309"` などとしてから実行し直すと良い
* 初回はEmergency Stop Encryption Keyがないので作成する。
  * `./x25519_private.pem`と`./x25519_public.pem`の2ファイル
* 初回は`./bitvm_cache.bin`がないので作成するコマンドを実行
  * 非常に時間がかかる
  * [usage](https://github.com/chainwayxyz/clementine/blob/v0.6.5/docs/usage.md)にあるURLで取得したファイルではダメだった
* 初回は`./core/certs/`がないので作成するコマンドを実行
* 初回は`~/.clementine/`がないので作成するコマンドが実行される。Enterを押しておけば良い
  * `~/.clementine/bridge_cli_config.toml`にregtestの項目を追加
* `./scripts/docker/configs/regtest/.env.regtest-hirokuam`を作成
  * `EMERGENCY_STOP_ENCRYPTION_PUBLIC_KEY`の更新
* `clementine-cli`のウォレット状況を確認して案内を出力
  * まだウォレットがない場合
    * ウォレットの作成: ニモニックの出力があるのでユーザ操作が必要
    * RECOVERY_TAPROOT_ADDRESSとEVM_ADDRを紐づけ

### 自作スクリプトファイル

#### ノード立ち上げ

RegtestのDocker Compose環境に必要なノードが立ち上がる。

```bash
./run-docker.sh up
```

停止は`up`の代わりに`down`を使う。
他のデータも削除して良いなら`clean.sh all`でも停止する。

#### withdraw関連

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

今は動作確認中なのでこういう感じで進める。

1. 必要があればclementineのコードを編集
1. `./run-docker.sh build`  (時間がかかる)

以下は実行する手順。  
実行手順のログを残したいならば `run-docker.sh up` は別ターミナルで実行するのが良い。

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

### Withdraw(first time)

1. `./scripts/run-withdraw.sh sendtosigner`
   * 330 satsを送金
1. `./scripts/run-withdraw.sh gensigs`
1. (ウォレットへのパスフレーズを設定していないならEnterだけ押す)
1. `./scripts/run-withdraw.sh withdraw`
1. (Citrea EVMアカウントの秘密鍵 64文字HEXを打ち込む。不可視。)
1. いろいろ実行
   * EVM上でburnコントラクト実行
   * DB withdrawsテーブルに330sats送金が載るのを待つ
   * `aggregator new-withdrawal`を実行
     * 成功すればOperatorがユーザ(`DEST_ADDR`)に立て替えて払い戻すトランザクション展開まで行われる
1. `./scripts/run-withdraw.sh reimbursement_sequence`
  * Operatorが立て替えた支払いをClementineから払い戻すリクエストを reimbursement と呼んでいる
    * BitVM2のKickOff以降の処理で、ClementineはwithdrawごとにKickOffを開始せずまとめて行うようになっている。
  * `get-reimbursement-txs`を繰り返し呼ぶことで次に必要なトランザクションを実行する
  * よくわからず失敗したときは再度`reimbursement_sequence`を実行すれば良い
  * "Reimbursement done."のログが出たら払い戻しが終わっている
1. コンソールのログを適当にコピー＆ペーストしてテキストファイルに残す
1. `./run-docker.sh logs > dockerのログ` などとして別のファイルにログを残す
   * ログの時間はdocker compose service単位で前後するので見るときには注意

### 後始末

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

