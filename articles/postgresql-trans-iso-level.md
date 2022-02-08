---
title: "PostgreSQLのトランザクション分離レベルを試す"
emoji: "🔖"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["postgresql"]
published: false
---

## はじめに

しばらく積読していた「データ指向アプリケーションデザイン」を読み終え、わかったようでわかってなかった「トランザクション分離レベル」がついにわかるかも！？熱が高まってきてたときに、こちらの記事と出会い、理解の確認がてらPostgreSQLで試してみました。

https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels

## 環境
* macOS 10.15.7
* Docker Desktop for Mac 4.3.2
* PostgreSQL 11.14

## トランザクション分離レベル

PostgreSQLのトランザクション分離レベル(以下「分離レベル」)については、マニュアルのここに書かれています。
https://www.postgresql.jp/docs/11/transaction-iso.html

ANSI/ISO SQL標準では次の4つの分離レベルが定義されています。
* リードアンコミッティド(Read uncommitted)
* リードコミッティド(Read committed)
* リピータブルリード(Repeatable read)
* シリアライザブル(Serializable)

[PostgreSQLのマニュアル 13.2.1](https://www.postgresql.jp/docs/11/transaction-iso.html)には以下のようにかかれており、デフォルトの分離レベルはリードミコッティドです。
> PostgreSQLではリードコミッティドがデフォルトの分離レベルです。

PostgreSQLでは、各種レベルにおける禁止される4つの現象が示されています。
* ダーティリード(Dirty Read)
* 反復不可能読み取り(Nonrepeatable Read)
* ファントムリード(Phantom Read)
* 直列化異常(Serialization Anomaly)

表にするとこうなります。

| 分離レベル       | ダーティリード                  | 反復不可能読み取り | ファントムリード                 | 直列化異常 |
|-------------|--------------------------|-----------|--------------------------|-------|
| リードアンコミッティド | 許容されるが、PostgreSQLでは発生しない | 可能性あり     | 可能性あり                    | 可能性あり |
| リードコミッティド   | 安全                       | 可能性あり     | 可能性あり                    | 可能性あり |
| リピータブルリード   | 安全                       | 安全        | 許容されるが、PostgreSQLでは発生しない | 可能性あり |
| シリアライザブル    | 安全                       | 安全        | 安全                       | 安全    |

この表の2箇所に「許容されるが、PostgreSQLでは発生しない」とあります。
これについて、マニュアルでは次のように書かれています。
> より厳密な動作をすることは標準SQLでも許されています。 つまり、この4つの分離レベルでは、発生してはならない事象のみが定義され、発生しなければならない事象は定義されていません。

「[13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)」より

つまりここで言う「許容される」は「ANSI/ISO SQL標準としては発生してもよいとされている」という意味です。
PostgreSQLでは、この2箇所は厳密に働く(発生しない)方向に倒して実装されているようです。
リードアンコミッティドにおいてダーティリードが発生しないとなると、それは実質、リードコミッティドと同じ分離レベルということになります。
マニュアルでも以下のように書いてあります。PostgreSQLでは3つの分離レベルしか実装されていないようです。
> PostgreSQLでは、4つの標準トランザクション分離レベルを全て要求することができます。 しかし、内部的には3つの分離レベルしか実装されていません。 つまり、PostgreSQLのリードアンコミッティドモードは、リードコミッティドのように動作します。

「[13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)」より

## セットアップ

今回、PostgreSQLとそのクライアントのpsqlはDockerコンテナとして立ち上げました。
その手順はこちらを参照してください。
https://zenn.dev/bellwood4486/articles/postgresql-psql-docker

[参考にさせていただいた記事](https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels)と合わせてデータベースとテーブルを作っていきます。

psqlで接続し、最初に`example`というデータベースを作ります。
```
postgres=# CREATE DATABASE example;
CREATE DATABASE
```
メタコマンドの`\c`(または`\connect`)で、作成したデータベースに接続します。
```
postgres=# \c example
You are now connected to database "example" as user "postgres".
```
(メタコマンドの詳細は [マニュアル](https://www.postgresql.jp/document/11/html/app-psql.html) を参照ください)

次に`users`テーブルを作っていきます。
```
example=# CREATE TABLE users (
example(# id INTEGER PRIMARY KEY,
example(# name VARCHAR(32) NOT NULL
example(# );
CREATE TABLE
```

メタコマンド`\dt`でテーブル一覧を見てみます。無事できているようです。
```
example=# \dt
         List of relations
 Schema | Name  | Type  |  Owner
--------+-------+-------+----------
 public | users | table | postgres
(1 row)
```

テスト用のデータを1つ作っておきます。
```
example=# INSERT INTO users VALUES (1, 'Alice');
INSERT 0 1
```
ちゃんとできてますね。
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Alice
(1 row)
```

## トランザクション分離レベルの確認および変更方法

テストを始める前に、分離レベルの確認および、それを変更する方法を調べておきます。

### 確認方法

[`SHOW`コマンド](https://www.postgresql.jp/docs/11/sql-show.html) を使うと、現在の分離レベルを確認できるようです。このコマンドは、実行時のパラメータの現在の設定を表示してくれます。  
[こちら](https://oss-db.jp/dojo/dojo_info_07) を見る限り、`SHOW`コマンドには`TRANSACTION ISOLATION LEVEL`を指定します。

さっそく確認してみましょう。デフォルトの分離レベルである`リードコミッティド(Read committed)`になっていました。
```
example=# SHOW TRANSACTION ISOLATION LEVEL;
transaction_isolation
-----------------------
read committed
(1 row)
```

### 変更方法

では、次に分離レベルを変更する方法です。  
**トランザクションを開始してから**次のコマンドを実行すると変更できます。
```
SET TRANSACTION ISOLATION LEVEL {変更したい分離レベル}
```

分離レベルには次の4つが指定できます。
* `SERIALIZABLE`
* `REPEATABLE READ`
* `READ COMMITTED`
* `READ UNCOMMITTED`

なお、トランザクションの開始と分離レベルの指定は、次のように一つのコマンドにすることもできます。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN
example=# SHOW TRANSACTION ISOLATION LEVEL;
 transaction_isolation
-----------------------
 repeatable read
(1 row)
```

:::details 上記方法に至るまでの経緯(調べたこと)

変更は、 [`SET TRANSACTION`コマンド](https://www.postgresql.jp/docs/11/sql-set-transaction.html) を使い、次のようにしていするとできるようです。
```
SET TRANSACTION ISOLATION LEVEL {変更したい分離レベル}
```
(指定できる分離レベルは前述)

試してみます。(`REPEATABLE READ`に変える)
```
example=# SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
WARNING:  SET TRANSACTION can only be used in transaction blocks
SET
```

警告が出ました(`WARNING: `の部分)。  
どうやらトランザクション内でないと、このコマンドは使えないようです。たしかに`SHOW`コマンドで確認してみても変わっていませんでした。

では、トランザクション内なら変更できるかを確認してみます。

まずトランザクションを開始します。([`START TRANSACTION`コマンド](https://www.postgresql.jp/docs/11/sql-start-transaction.html) でもよいですが、今回はタイプの少ない [`BEGIN`コマンド](https://www.postgresql.jp/docs/11/sql-begin.html) の方を使います)
```
example=# BEGIN;
BEGIN
```

ここで再度`SET TRANSACTION`コマンドを実行してみます。今度は警告は出ず終わりました。
```
example=# SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET
```

分離レベルを確認すると、今度は`repeatable read`に変わっています。
```
example=# SHOW TRANSACTION ISOLATION LEVEL;
transaction_isolation
-----------------------
repeatable read
(1 row)
```

もろもろ確認できたのでロールバックしておきます。
```
example=# ROLLBACK;
ROLLBACK
```

:::

## ダーティリード

分離レベルの確認と変更方法もわかったので、各現象を確認していきます。

ダーティリードは、マニュアルでは次のように書かれています。
> ダーティリード
> 同時に実行されている他のトランザクションが書き込んで未だコミットしていないデータを読み込んでしまう。

前述した通り、PostgreSQLではこの現象は起きません。(リードアンコミッティド分離レベルでも許容しない方向に実装されているから)
なのでここでは「起きないこと」を確認します。

まず、psqlから2つのセッションを作ります。本記事では便宜上`client1`、`client2`と呼ぶことにします。
そして、 リードアンコミッティド(`READ UNCOMMITTED`)分離レベルのトランザクションをそれぞれのセッションで開始します。 分離レベルを確認すると、期待した状態になっていることがわかります。
client1, client2:
```
example=# BEGIN TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
BEGIN
example=# SHOW TRANSACTION ISOLATION LEVEL;
 transaction_isolation
-----------------------
 read uncommitted
(1 row)
```

client1で名前を変えます(`Alice`->`Bob`)。ただしコミットはまだしません。
```
example=# UPDATE users SET name = 'Bob' WHERE id = 1;
UPDATE 1
```

client2でテーブルを見てみます。名前には`Alice`のままで変わっていません。分離レベルはリードアンコミッティドであるものの、ダーティリードは起きていないことがわかります。
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Alice
(1 row)
```

client1とclient2はロールバックしておきます。
```
example=# ROLLBACK;
ROLLBACK
```

## 反復不可能読み取り

次に、反復不可能読み取り(Nonrepeatable Read)を見ていきます。
マニュアルの定義は以下のとおりです。
> 反復不能読み取り
トランザクションが、以前読み込んだデータを再度読み込み、そのデータが(最初の読み込みの後にコミットした)別のトランザクションによって更新されたことを見出す。 

「[13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)」より

前述の表で「可能性あり」となっているリードコミッティド分離レベルで起きることをまず確認してみます。
client1, client2ともに、リードコミッティド分離レベルでトランザクションを開始します。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN
```

clinet1で名前を変更します(`Alice`->`Carol`)。まだコミットはしません。
```
example=# UPDATE users SET name = 'Carol' WHERE id = 1;
UPDATE 1
```

この時点ではまだclient2からは`Alice`が見えています。
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Alice
(1 row)
```

client1でコミットしてみます。
```
example=# COMMIT;
COMMIT
```

client2で再度名前を確認すると`Carol`に変わっています。他のトランザクションのコミットが反映されたことがわかります。
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Carol
(1 row)
```
リードコミッティド分離レベルでは反復不可能読み取りが起きることを確認できました。この分離レベルでは同じ行を取るクエリを2回実行しても、同じ結果になるとは限らないということです。

## ファントムリード

次に、ファントムリードを見ていきます。
マニュアルの定義は以下のとおりです。
> ファントムリード
トランザクションが、複数行のある集合を返す検索条件で問い合わせを再実行した時、別のトランザクションがコミットしてしまったために、同じ検索条件で問い合わせを実行しても異なる結果を得てしまう。

「[13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)」より

標準SQLの定義上はリピータブルリード分離レベル以下で起きうることになっています。ただ前述の通り、PostgreSQLでは実装上リピータブルリードで起きないため、そのひとつ下のレベルのリードコミッティドでこの現象を確認します。

client1, client2ともに、リードコミッティド分離レベルでトランザクションを開始します。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN
```

client1から、id=1の行を削除します。まだコミットはしません。
```
example=# DELETE FROM users WHERE id = 1;
DELETE 1
```

この時点ではclient2からはまだid=1の行が見えています。
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Alice
(1 row)
```

client1でコミットします。
```
example=# COMMIT;
COMMIT
```

client2で再度確認するとid=1の行が消えており、別トランザクションの変更が反映されたことがわかります。
```
example=# SELECT * FROM users;
 id | name
----+------
(0 rows)
```

## 直列化異常

## 参考資料
* [O'Reilly Japan - データ指向アプリケーションデザイン](https://www.oreilly.co.jp/books/9784873118703/)
* [MySQL の InnoDB でトランザクション分離レベルの違いを試す - CUBE SUGAR CONTAINER](https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels)
* [13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)
* [トランザクション分離レベル - Wikipedia](https://ja.wikipedia.org/wiki/%E3%83%88%E3%83%A9%E3%83%B3%E3%82%B6%E3%82%AF%E3%82%B7%E3%83%A7%E3%83%B3%E5%88%86%E9%9B%A2%E3%83%AC%E3%83%99%E3%83%AB)
* [第7回　トランザクション](https://oss-db.jp/dojo/dojo_info_07)
