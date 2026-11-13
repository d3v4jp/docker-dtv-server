# docker-dtv-server

![docker-dtv-serverを立ち上げた時のスクリーンショット](./screenshot.webp)

Dockerで構築するMirakurun + EPGStation + KonomiTVなTV視聴・録画環境

## 技術スタック

- [Mirakurun](https://github.com/Chinachu/Mirakurun)
- [kazuki0824/recisdb-rs](https://github.com/kazuki0824/recisdb-rs)
- [EPGStation](https://github.com/l3tnun/EPGStation)
- [MariaDB](https://mariadb.org/)
- [rigaya/tsreplace](https://github.com/rigaya/tsreplace)
- [KonomiTV](https://github.com/tsukumijima/KonomiTV)
- [Docker](https://www.docker.com/)

## Getting Started

### 前提条件

- ホストPC上に以下のものが必要です：
  - Docker
  - px4_drvなどのチューナードライバ
- ホストOSはUbuntu 24.04 LTSを想定しています。

### インストール

#### リポジトリの取得

KonomiTVはサブモジュールとして取り込んでいるので、サブモジュールごとクローンしてください。

```bash
git clone --recurse-submodules https://github.com/d3v4jp/docker-dtv-server.git
cd docker-dtv-server
```

サブモジュールなしでクローンした場合は、以下のコマンドでKonomiTVを取得できます。

```bash
git submodule update --init --recursive
```

#### Mirakurun

`mirakurun/conf`ディレクトリ以下にchannels.yml、tuners.ymlを作成してください。

- [ISDBScanner](https://github.com/tsukumijima/ISDBScanner)などで自動生成できます。
- channels.ymlは、後述のMirakurunのチャンネルスキャンで作成することもできます。
- tuners.ymlの`command`にはrecisdbを指定します（`mirakurun/conf/tuners.yml.example`を参照）。

#### EPGStation

`EPGStation/config/config.yml.example`をコピーして`EPGStation/config/config.yml`を作成してください。

```bash
cp EPGStation/config/config.yml.example EPGStation/config/config.yml
```

録画した元のTSは`EPGStation/recorded/ts`に、tsreplaceで映像だけを圧縮したTSは`EPGStation/recorded/encoded`に保存されます。

エンコードは既定でIntel iGPU (QSV) を使います。

- H.264やNVENCを使う場合は、config.ymlの`encode`の項目でコメントを外してください。
- NVENCを使う場合は、ホストにNVIDIAドライバとNVIDIA Container Toolkitを入れ、compose.yamlの`deploy`のコメントも外してください。

##### エンコードしない時間帯の設定について

EPGStationのエンコードは、KonomiTVでリアルタイム視聴する時間帯を避けて、17:30〜翌2:00には開始しないように設定しています。
この時間帯にもエンコードしたい場合は、この設定を入れたコミットをリバートしてください。

```bash
git revert $(git log --format=%H -1 --grep='リアルタイム視聴する時間帯はエンコードを始めない')
```

リバートで元に戻るのは`config.yml.example`だけです。
`config.yml`を作成済みの場合は、もう一度コピーし直すか、`config.yml`から`encodeSuspendTimes`の項目を削除してください。
その後、EPGStationを再起動すると反映されます。

```bash
docker compose restart epgstation
```

時間帯だけを変えたい場合は、リバートせずに`config.yml`の`start`と`end`を書き換えてください。

#### ユーザーとGPUの設定

EPGStationとMariaDBは、録画ファイルやDBのファイルがrootの所有にならないよう、ホストのユーザーとして動かします。
compose.yamlの`user`と`group_add`を、お使いの環境に合わせて書き換えてください。

```bash
id -u                # ユーザーのUID (compose.yaml の user: "UID:GID" の左側)
id -g                # ユーザーのGID (compose.yaml の user: "UID:GID" の右側)
getent group render  # renderグループのGID (例: render:x:991: なら 991。epgstation の group_add に書く)
```

EPGStationはiGPUのレンダーノード (`/dev/dri/renderD128`) を使うため、ホストのrenderグループのGIDが必要です。

compose.yamlでは`/dev/dri/by-path/pci-0000:00:02.0-render`を渡しています。
iGPUのPCIアドレスが異なる場合は、`ls -l /dev/dri/by-path/`で確認して書き換えてください。

#### KonomiTV

`KonomiTV`ディレクトリ以下にconfig.yamlを作成してください。

- バックエンドはMirakurun (`http://127.0.0.1:40772/`) を指定します。
- 録画フォルダの指定方法は「EPGStationとKonomiTVの録画フォルダ」を参照してください。

### チャンネルスキャン

channels.ymlを手で書く代わりに、Mirakurunのチャンネルスキャンでも作成できます。

先にMirakurunだけを起動し、受信したい種別ごとに以下のコマンドを実行してください。スキャンには数分〜十数分かかります。
EPGStationやKonomiTVを起動する前にスキャンしておくと、チューナーの取り合いがなく、EPGStationも最初から正しいチャンネル一覧で起動します。

```bash
# Mirakurunだけを起動
docker compose up -d mirakurun

# 地上波 (13〜62ch)
curl -X PUT "http://localhost:40772/api/config/channels/scan"

# BS (BS01_0〜BS23_3)
curl -X PUT "http://localhost:40772/api/config/channels/scan?type=BS&setDisabledOnAdd=false"

# CS (CS2〜CS24)
curl -X PUT "http://localhost:40772/api/config/channels/scan?type=CS&setDisabledOnAdd=false"
```

- BSとCSは、`setDisabledOnAdd=false`を付けないと見つかったチャンネルが無効の状態で追加されます。
- すでに有効なチャンネルはスキャンされません。スキャンし直す場合は`refresh=true`を付けてください。
- `dryRun=true`を付けると、channels.ymlを書き換えずに結果だけを確認できます。
- 地上波は取得漏れが出る場合があるので、スキャン後にchannels.ymlを確認してください。
- MirakurunのWeb画面 (`http://<ホストのIP>:40772/`) のチャンネル設定からもスキャンできます。

### 起動

設定が完了したら、以下のコマンドでDockerイメージをビルドし、コンテナを起動します：

```bash
docker compose up -d
```

起動したら、以下のURLでアクセスできます。

- Mirakurun: `http://<ホストのIP>:40772/`
- EPGStation: `http://<ホストのIP>:8888/`
- KonomiTV: `https://<ホストのIPの.を-に置き換えたもの>.local.konomi.tv:7000/`

例えばホストのIPが`192.168.0.100`の場合は、以下のようになります。

- Mirakurun: `http://192.168.0.100:40772/`
- EPGStation: `http://192.168.0.100:8888/`
- KonomiTV: `https://192-168-0-100.local.konomi.tv:7000/`

KonomiTVのURLの仕組みについては、[KonomiTVのREADME](https://github.com/tsukumijima/KonomiTV#httpsaa-bb-cc-ddlocalkonomitv7000-%E3%81%AE-url-%E3%81%AB%E3%81%A4%E3%81%84%E3%81%A6)を参照してください。

チャンネルスキャンをした場合は、MirakurunのEPG更新を待ってからEPGStationにアクセスしてください。

#### EPGStationとKonomiTVの録画フォルダ

EPGStationの録画フォルダは以下のとおりです。

- `ts`：録画した元のTS。ホストの`EPGStation/recorded/ts`（コンテナ内は`/recorded/ts`）に保存されます。
- `encoded`：tsreplaceで圧縮したTS。ホストの`EPGStation/recorded/encoded`（コンテナ内は`/recorded/encoded`）に保存されます。

KonomiTVでは、`KonomiTV/config.yaml`の`video`→`recorded_folders`に`encoded`フォルダを指定します。
パスはホスト側の絶対パスをそのまま書いてください。Docker上ではKonomiTVが自動で`/host-rootfs`を付けて読み込みます。

例えばリポジトリを`/home/user/docker-dtv-server`に置いている場合は、以下のようになります。

```yaml
video:
    recorded_folders: [
        '/home/user/docker-dtv-server/EPGStation/recorded/encoded',
    ]
```

#### エンコード予約の注意(課題点)

エンコードの保存先を指定しないと、圧縮後のファイルも`ts`フォルダに保存されます。
この場合、KonomiTVの録画番組一覧には表示されません。

エンコードする番組は、以下のように予約してください。

- ルールで録画する場合は、「エンコード1」でモードを選び、保存先（directory1）に`encoded`を指定します。
- 単発で録画する場合は、番組詳細予約から予約し、同じく保存先に`encoded`を指定します。
- 番組表からの簡易予約では保存先を選べないので、TSのまま録画する番組に使ってください。

保存先を指定し忘れた場合は、EPGStationの録画詳細から保存先を`encoded`にしてエンコードし直してください。

## 紹介記事

[Dockerで構築！ミニPC + PX-W3U4でお手軽自宅録画サーバー](https://zenn.dev/nunawa/articles/ecb9ef2e237532)

## ライセンス

docker-dtv-serverは、MITライセンスのもとで公開されています。
