---
title: "PostgreSQLとpsqlの使い捨て環境を立ち上げる"
emoji: "🐳"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["postgresql", "docker"]
published: true
---

使い捨ての実験環境として、PostgreSQLとpsqlをDockerコンテナ上で動かしたときの記録です。
仕事だと便利な環境がすでに用意されており、いざ自分で作ろうとしたらちゃんとわかってないことも多く、思いのほか手こずってしまったためメモしておきます。

## 環境

* macOS 10.15.7
* Docker Desktop for Mac 4.3.2
* PostgreSQL 11.14

## 結論

### PostgreSQLをコンテナ上に立ち上げる

PostgreSQL 11であれば、以下の流れで立ち上げることができます。

Dockerのイメージを取得する。
```shell
docker pull postgres:11
```

Dockerのネットワークを作成する。
```shell
docker network create some-network
```

PostgreSQL 11のコンテナを起動する。
```shell
docker run --rm --name some-postgres -h some-postgres --network some-network -e POSTGRES_PASSWORD=mysecretpassword -d postgres:11
```

このコマンドで起動するPostgreSQLは次の設定を持ちます。
* コンテナ名: `some-postgres` (`--name`オプションの値)
* ホスト名: `some-postgres` (`-h`オプションの値)
* Dockerのネットワーク: `some-network` (`--network`オプションの値)
* PostgreSQLのパスワード: `mysecretpassword` (`POSTGRES_PASSWORD`環境変数の値)

### psqlをコンテナ上で起動する

前述の方式で起動したPostgreSQLであれば、以下のコマンドでpsqlを起動し接続することができます。

```shell
docker run -it --rm --network some-network postgres:11 psql -h some-postgres -U postgres
```

## 経緯メモ

以下は、最終的な結果に至るまでの調査の流れや、自分の理解が曖昧だった箇所のメモです。読み飛ばしてもらって構いません。

まず、コンテナイメージを取ってきます。  
PostgreSQLのオフィシャルイメージはこちらにあります。
https://hub.docker.com/_/postgres

一通り起動できたらイメージの軽量化は検討していけばよいので、いったんはツールの豊富なDebianベースのイメージを選んでいます。
```shell
docker pull postgres:11
```

上記公式サイトに「How to use this image」があるので、それに沿って試していきます。  
何も考えずに実行してみると、`some-network`がない旨のエラーになりますね。
```shell
❯ docker run -it --rm --network some-network postgres psql -h some-postgres -U postgres
docker: Error response from daemon: network some-network not found.
```

そもそもDockerのネットワークをよくわかってないので、マニュアルを読んでいきます。
http://docs.docker.jp/v19.03/engine/userguide/networking/dockernetworks.html

`ls`ができるようなので、これで既存のネットワークを確認します。3つでてきました。 たしかに`some-network`という名前のものはないですね。
```shell
❯ docker network ls
NETWORK ID     NAME      DRIVER    SCOPE
c9d19e1f3143   bridge    bridge    local
4586fb082355   host      host      local
e27d19bd233f   none      null      local
```

ちなみに、`--network`オプションを指定しない場合、デフォルトで`bridge`というネットワークに接続するようです。

じゃあ、`--network`オプションはべつに指定せず、`bridge`ネットワークを使えばよいのでは？ ということで、このオプションを外して再度実行してみます。  
起動はしたようです。
```shell
❯ docker run --rm --name some-postgres -h some-postgres -e POSTGRES_PASSWORD=mysecretpassword -d postgres:11

960c2f13845b115ebf5b9264a8ba9e40fd2ef87191b36c1d4739b432f0041009
```

psqlから繋いでみます。  
ホスト名(`some-postgres`)が見つからないエラーになりました…。
```shell
❯ docker run -it --rm postgres psql -h some-postgres -U postgres
psql: error: could not translate host name "some-postgres" to address: Name or service not known
```

Dockerがどうやって名前を解決しているかがそもそもわかってないので、またマニュアルを読んでいきます。
http://docs.docker.jp/v19.03/engine/userguide/networking/dockernetworks.html#docker-dns

このように書かれていました。
> Docker デーモンは内蔵 DNS サーバを動かし、ユーザ定義ネットワーク上でコンテナがサービス・ディスカバリを自動的に行えるようにします。

「ユーザー定義ネットワーク」とあるので、ホスト名で解決したければDockerのネットワークを自分で作っておく必要がありそうな雰囲気。
ググって見つけた以下の記事でもネットワークを作っているので、この理解は間違ってなさそうです。(参考にさせていただきました！ありがとうございます！)
https://qiita.com/yackrru/items/fe5294e9dd74ea0c4ce3

ということでネットワークを作っていきます。ネットワーク関連のコマンドは [こちら](http://docs.docker.jp/v19.03/engine/userguide/networking/work-with-networks.html) に載っています。
```shell
❯ docker network create some-network
16bdc928a8fcc027447b1ed6ad630b8a13cead57ed7306cccfc1925789d374da
```

ちなみに`docker network inspect {ネットワーク名}`で、作成したネットワークの詳細を確認できます。
```json
❯ docker network inspect some-network
[
    {
        "Name": "some-network",
        "Id": "16bdc928a8fcc027447b1ed6ad630b8a13cead57ed7306cccfc1925789d374da",
        "Created": "2022-01-26T14:09:09.9730416Z",
        "Scope": "local",
        "Driver": "bridge",
        "EnableIPv6": false,
        "IPAM": {
            "Driver": "default",
            "Options": {},
            "Config": [
                {
                    "Subnet": "172.24.0.0/16",
                    "Gateway": "172.24.0.1"
                }
            ]
        },
        "Internal": false,
        "Attachable": false,
        "Ingress": false,
        "ConfigFrom": {
            "Network": ""
        },
        "ConfigOnly": false,
        "Containers": {},
        "Options": {},
        "Labels": {}
    }
]
```

このネットワークを使い、再度PostgreSQLとpsqlを立ち上げてみます。
ネットワークの指定は`-h`オプションでできます。
```
  -h, --hostname string                Container host name
```

PostgreSQL
```shell
❯ docker run --rm --name some-postgres -h some-postgres --network some-network -e POSTGRES_PASSWORD=mysecretpassword -d postgres:11

54f76df1e9e5442914addc16656063fbb1a89c105611e32496e9c6a3748cdbc4
```

psql
```shell
❯ docker run -it --rm --network some-network postgres:11 psql -h some-postgres -U postgres

Password for user postgres: 
psql (11.14 (Debian 11.14-1.pgdg90+1))
Type "help" for help.

postgres=# 
```

無事繋がりました🎉

## 参考資料

* [Postgres - Official Image | Docker Hub](https://hub.docker.com/_/postgres)
* [Docker コンテナ・ネットワークの理解 — Docker-docs-ja 19.03 ドキュメント](http://docs.docker.jp/v19.03/engine/userguide/networking/dockernetworks.html)
* [network コマンドを使う — Docker-docs-ja 19.03 ドキュメント](http://docs.docker.jp/v19.03/engine/userguide/networking/work-with-networks.html)
* [psqlクライアントを使い捨てのDockerコンテナで代用する方法 - Qiita](https://qiita.com/yackrru/items/fe5294e9dd74ea0c4ce3)
