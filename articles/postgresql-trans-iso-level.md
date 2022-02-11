---
title: "PostgreSQLのトランザクション分離レベルを試す"
emoji: "🔖"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["postgresql"]
published: false
---

## はじめに

本記事は、PostgreSQLにおけるトランザクション分離レベルを違いを試してみた記録です。  

『 [データ指向アプリケーションデザイン](https://www.oreilly.co.jp/books/9784873118703/) 』という本を読み終え、トランザクション分離レベルの理解が深まってきたときにこちらの記事と出会い、理解の確認としてPostgreSQLで試してみました。

https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels

## 環境

* macOS 10.15.7
* Docker Desktop for Mac 4.3.2
* PostgreSQL 11.14

## トランザクション分離レベル

マニュアルを抜粋しつつ、PostgreSQLにおけるトランザクション分離レベル(以下「分離レベル」)と、各分離レベルで禁止している現象について、簡単に説明します。
マニュアルはこちらです。
https://www.postgresql.jp/docs/11/transaction-iso.html

2つのトランザクションが同じデータにアクセスする場合、並行性の問題(レースコンディション)が生じることがあります。具体的には、1つのトランザクションが、他のトランザクションが並行で変更しているデータを読み取る場合や、2つのトランザクションが同じデータを同時に変更する場合です。  

データベースは、トランザクションの分離性を提供することでこれら問題をアプリケーション開発者から隠しています。  
トランザクションがすべて直列に実行されれば、並行性の問題は回避できすます。しかしそれだとパフォーマンス面で負担が上がります。すべての並行性の問題ではなくある種の問題のみ保護するといったように、保護にも段階的なレベルがあります。この段階的なレベルのことをトランザクション分離レベルと呼びます。

トランザクション分離レベルは、SQL標準(ANSI/ISO SQL-92)で4つのレベルが定義されています。
* リードアンコミッティド(Read uncommitted)
* リードコミッティド(Read committed)
* リピータブルリード(Repeatable read)
* シリアライザブル(Serializable)

PostgreSQLのデフォルトのトランザクション分離レベルは、設定の変更をしていなければリードミコッティドです。トランザクションを開始する際に分離レベルを指定しなかった場合はこのレベルになります。

PostgreSQLのマニュアルでは、並行性の問題として次の4つが挙げられています。
* ダーティリード(Dirty Read)
* 反復不可能読み取り(Nonrepeatable Read)
* ファントムリード(Phantom Read)
* 直列化異常(Serialization Anomaly)
 
それぞれは、各レベルで禁止されてたり許容されてたりします。表にすると次のようになります。  
「安全」と書かれている分離レベルでは現象が発生しません。一方、「可能性あり」ものは発生します。  

| 分離レベル       | ダーティリード                  | 反復不可能読み取り | ファントムリード                 | 直列化異常 |
|-------------|--------------------------|-----------|--------------------------|-------|
| リードアンコミッティド | 許容されるが、PostgreSQLでは発生しない | 可能性あり     | 可能性あり                    | 可能性あり |
| リードコミッティド   | 安全                       | 可能性あり     | 可能性あり                    | 可能性あり |
| リピータブルリード   | 安全                       | 安全        | 許容されるが、PostgreSQLでは発生しない | 可能性あり |
| シリアライザブル    | 安全                       | 安全        | 安全                       | 安全    |

また、この表の2箇所に「許容されるが、PostgreSQLでは発生しない」とあります。これは「SQL標準としては発生してもよいとされているが、PostgreSQLの実装上は発生しない」というものです。  
「許容されるが、PostgreSQLでは発生しない」を「安全」と読み替えてみると、リードアンコミッティドとリードコミッティドは保護する内容に差がありません。
マニュアルでも次のように書かれており、PostgreSQLでは3つの分離レベルしか実装されていないようです。
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

### リピータブルリードでの挙動

以下のように、 リピータブルリード分離レベルでトランザクションを開始した場合は、反復不可能読み取りは起こりません。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN
```

(実行するクエリ等は前述と同じため割愛します)

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

### リピータブルリードでの挙動

リピータブルリード分離レベルでは、ファントムリードは「許容されるが、PostgreSQLでは発生しない」となっています。
これを確認してみます。

まず、client1, client2ともに、リピータブルリード分離レベルでトランザクションを開始します。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN
```

**(client1のコミットまでの操作は、前述と同じなので割愛します)**

最後に、client1で削除したid=1の行をclient2から確認してみます。
リードコミッティド分離レベルだと、client1の影響を受けid=1の行が消えていました。
しかしリードコミッティドの場合は残っており、ファントムリードが発生していません。
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Alice
(1 row)
```

では、既にclient1で削除されているこの行を更新しようとするとどうなるでしょうか？
結果はエラーになります。
```
example=# UPDATE users SET name = 'Bob' WHERE id = 1;
ERROR:  could not serialize access due to concurrent update
```

マニュアルには次のように書かれており、これは期待通りの動作です。
> 最初の更新処理がコミット（かつ、単にロックされるだけでなく、実際に行が更新または削除）されると、リピータブルリードトランザクションでは、以下のようなメッセージを出力してロールバックを行います。
ERROR: could not serialize access due to concurrent update
これは、リピータブルリードトランザクションでは、トランザクションが開始された後に別のトランザクションによって更新されたデータは変更またはロックすることができないためです。

「[13.2.2. リピータブルリード分離レベル](https://www.postgresql.jp/docs/11/transaction-iso.html)」より

リピータブルリード分離レベル内で更新する場合は、このようなエラーになる可能性があるため、再実行を前提とした設計をしておく必要があるようです。

## 直列化異常

最後に直列化異常を確認します。
マニュアルの定義は以下のとおりです。
> 直列化異常
複数のトランザクションを正常にコミットした結果が、それらのトランザクションを1つずつあらゆる可能な順序で実行する場合とは一貫性がない。

まずは、リピータブルリード分離レベルでこの現象の起きることを確認します。
マニュアルに載っている例に合わせ、別のテーブルを作ります。
```
example=# CREATE TABLE mytab (
example(# class INTEGER NOT NULL,
example(# value INTEGER NOT NULL
example(# );
CREATE TABLE
```

テスト用のデータを入れます。
```
example=# INSERT INTO mytab VALUES (1, 10), (1, 20), (2, 100), (2, 200);
INSERT 0 4
example=# SELECT * FROM mytab;
class | value
-------+-------
1 |    10
1 |    20
2 |   100
2 |   200
```

準備ができたので、client1とclient2で、リピータブルリード分離レベルのトランザクションを2つ用意します。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN
```

client1で、まずclass=**1**の値を計算します。
```
example=# SELECT SUM(value) FROM mytab WHERE class = 1;
 sum
-----
  30
(1 row)
```
さらにその結果(`30`)を、class=**2**の行として追加します。
```
example=# INSERT INTO mytab VALUES (2, 30);
INSERT 0 1
```

ここでclient2へ切り替えます。
client2では、class=**2**の値を計算します。
```
example=# SELECT SUM(value) FROM mytab WHERE class = 2;
 sum
-----
 300
(1 row)
```
さらにこの結果(`300`)をclass=**1**の行として追加します。
```
example=# INSERT INTO mytab VALUES (1, 300);
INSERT 0 1
```

ここまでできたらclient1とclient2を順にコミットします。
どちらも成功しました。
```
example=# COMMIT;
COMMIT
```

後からコミットした方(この場合はclient2)では、先にコミットした方(client1)が追加した値(class=2, value=30)が、SUMに加味されないままコミットされてしまいました。

### シリアライザブルでの挙動

では、この直列化異常に安全なシリアライザブル分離レベルではどうなるのか確認してみます。
前述の操作で新たな行が追加されてしまったので、テストデータは元の状態(以下)に戻しておいてください。
```
example=# SELECT * FROM mytab;
class | value
-------+-------
1 |    10
1 |    20
2 |   100
2 |   200
```

client1, client2ともに、シリアライザブル分離レベルでトランザクションを開始します。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN
```

**(client1のコミットまでの操作は、前述と同じなので割愛します)**

client1をコミットした後、リピータブルリード分離レベルでは成功したclient2のコミットを実行してみます。
エラーになりました。
```
example=# COMMIT;
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during commit attempt.
HINT:  The transaction might succeed if retried.
```

client1, client2どちらを先に実行しても、後から実行したほうの総和の計算が合わなくなってしまうので、このようにエラーとなります。
ファントムリードの例と同様に、シリアライザブル分離レベルを使う場合はリトライを前提として設計しておく必要がありそうです。

## まとめ

PostgreSQLにおけるトランザクション分離レベルの違いを、実際に手を動かしながら確認しました。
データ指向アプリケーションデザインの「7章 トランザクション」では、 トランザクションの説明が丁寧に書かれているので、ここを読んでからだとマニュアルで言っていることもだいぶ理解しやすかったです。
マニュアルは見てるがいまいち頭に入ってこないという方は、一度この章を読んでみてもよいかもしれません。

## 参考
* [O'Reilly Japan - データ指向アプリケーションデザイン](https://www.oreilly.co.jp/books/9784873118703/)
* [MySQL の InnoDB でトランザクション分離レベルの違いを試す - CUBE SUGAR CONTAINER](https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels)
* [A Critique of ANSI SQL Isolation Levels - Microsoft](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/tr-95-51.pdf)
* [13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)
* [トランザクション分離レベル - Wikipedia](https://ja.wikipedia.org/wiki/%E3%83%88%E3%83%A9%E3%83%B3%E3%82%B6%E3%82%AF%E3%82%B7%E3%83%A7%E3%83%B3%E5%88%86%E9%9B%A2%E3%83%AC%E3%83%99%E3%83%AB)
* [第7回　トランザクション](https://oss-db.jp/dojo/dojo_info_07)
