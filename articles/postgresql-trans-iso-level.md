---
title: "PostgreSQLのトランザクション分離レベルを試す"
emoji: "🔖"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["postgresql"]
published: false
---

## はじめに

本記事は、PostgreSQLにおけるトランザクション分離レベルの挙動の違いを試してみた記録です。  

『 [データ指向アプリケーションデザイン](https://www.oreilly.co.jp/books/9784873118703/) 』という本を読み終え、トランザクション分離レベルの理解が深まってきたときにこちらの記事と出会い、理解の確認としてPostgreSQLで試してみました。

https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels

## 環境

* macOS 10.15.7
* Docker Desktop for Mac 4.3.2
* PostgreSQL 11.14

## トランザクション分離レベル

PostgreSQLにおける「トランザクション分離レベル」と「各レベルで禁止する現象」とは何かについて簡単に整理します。

PostgreSQLでトランザクション分離レベルについて書かれているマニュアルはこちらです。  
https://www.postgresql.jp/docs/11/transaction-iso.html

2つのトランザクションが同じデータにアクセスする場合、並行性の問題(レースコンディション)が生じる場合があります。  
具体的には次のようなケースです。
* 1つのトランザクションが、他のトランザクションが並行で変更しているデータを読み取る場合
* 2つのトランザクションが同じデータを同時に変更する場合

データベースでは、「トランザクションの分離性」を提供することでこれら問題をアプリケーション開発者から隠しています。  
トランザクションがすべて直列に実行されれば、並行性の問題は回避できすます。しかしそれだと一つずつしか処理していけないためパフォーマンスを落とすことになります。 並行性のすべての問題を回避するのではなく、「一部の問題からは保護する」といったように保護の度合いを段階的に分けています。段階的に分けたものをトランザクション分離レベルと呼んでいます。

トランザクション分離レベルは、SQL標準(ANSI/ISO SQL-92)で4つのレベルが定義されています。
* リードアンコミッティド(Read uncommitted)
* リードコミッティド(Read committed)
* リピータブルリード(Repeatable read)
* シリアライザブル(Serializable)

:::message
PostgreSQLのマニュアル(日本語版)ではカタカナで表記になっているため、本記事もそれに合わせています。
:::

設定の変更をしていなければ、PostgreSQLのデフォルトのトランザクション分離レベルは「リードミコッティド」です。トランザクション分離レベルを指定せずにトランザクションを開始した場合はこのレベルになります。

PostgreSQLのマニュアルでは、並行性の問題となる現象として次の4つが挙げられています。
* ダーティリード(Dirty Read)
* 反復不可能読み取り(Nonrepeatable Read)
* ファントムリード(Phantom Read)
* 直列化異常(Serialization Anomaly)

各現象の詳細は、挙動を確認する後述部分で触れます。
 
これらは、各レベルで禁止されてたり許容されてたりします。表にすると以下の通りです。  

| 分離レベル       | ダーティリード                  | 反復不可能読み取り | ファントムリード                 | 直列化異常 |
|-------------|--------------------------|-----------|--------------------------|-------|
| リードアンコミッティド | 許容されるが、PostgreSQLでは発生しない | 可能性あり     | 可能性あり                    | 可能性あり |
| リードコミッティド   | 安全                       | 可能性あり     | 可能性あり                    | 可能性あり |
| リピータブルリード   | 安全                       | 安全        | 許容されるが、PostgreSQLでは発生しない | 可能性あり |
| シリアライザブル    | 安全                       | 安全        | 安全                       | 安全    |

「安全」は禁止を意味し、「可能性あり」は許容を意味します。
また「許容されるが、PostgreSQLでは発生しない」というのもあります。これは「SQL標準では発生してもよいとされているが、PostgreSQLでは実装上発生しない」という意味です。

ここで、「許容されるが、PostgreSQLでは発生しない」を「安全」と読み替えてみると、リードアンコミッティドとリードコミッティドの保護内容には差がなくなります。
マニュアルでも次のように書かれており、トランザクション分離レベルとしては4種類あるものの、PostgreSQLでは3つしか実装されていないようです。
> PostgreSQLでは、4つの標準トランザクション分離レベルを全て要求することができます。 しかし、内部的には3つの分離レベルしか実装されていません。 つまり、PostgreSQLのリードアンコミッティドモードは、リードコミッティドのように動作します。

「[13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)」より

## セットアップ

それでは各現象を確認するために、環境をセットアップしていきます。

PostgreSQLとクライアント(psql)は、Dockerコンテナとして立ち上げました。  
その手順はこちらを参照してください。
https://zenn.dev/bellwood4486/articles/postgresql-psql-docker

データベースとテーブルは、 [参考にさせていただいた記事](https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels) と合わせて作っていきます。

psqlで接続し、最初に`example`というデータベースを作ります。
```
postgres=# CREATE DATABASE example;
CREATE DATABASE
```
メタコマンド`\c`で、作成したデータベースに接続し直します。
```
postgres=# \c example
You are now connected to database "example" as user "postgres".
```
(メタコマンドの詳細は [マニュアル](https://www.postgresql.jp/document/11/html/app-psql.html) を参照ください)

次に`users`テーブルを作ります。
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
無事作れました。
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Alice
(1 row)
```

## トランザクション分離レベルの確認および変更する方法

テストを始める前に、トランザクション分離レベルの確認および、それを変更する方法を調べておきます。

### 確認方法

[`SHOW`コマンド](https://www.postgresql.jp/docs/11/sql-show.html) を使うと、現在のトランザクション分離レベルを確認できます。このコマンドは、指定されたパラメータの現在の設定を表示します。
[こちらの記事](https://oss-db.jp/dojo/dojo_info_07) を見る限り、パラメータは`TRANSACTION ISOLATION LEVEL`を指定するようです。

さっそく確認してみましょう。設定は変えていないのでデフォルトの分離レベルである`リードコミッティド(Read committed)`が出るはずです。  
無事確認できました。
```
example=# SHOW TRANSACTION ISOLATION LEVEL;
transaction_isolation
-----------------------
read committed
(1 row)
```

### 変更方法

次にトランザクション分離レベルを変更する方法です。  
**トランザクションを開始してから**次のコマンドを実行することで変えられます。
```
SET TRANSACTION ISOLATION LEVEL {変更したい分離レベル}
```

`{変更したい分離レベル}`には次の4つが指定可能です。
* `READ UNCOMMITTED`
* `READ COMMITTED`
* `REPEATABLE READ`
* `SERIALIZABLE`

なお、トランザクションの開始とトランザクション分離レベルの指定は、一つのコマンドにまとめることもできます。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN
```

:::details 上記方法に至るまでの経緯(調べたこと)

変更は、 [`SET TRANSACTION`コマンド](https://www.postgresql.jp/docs/11/sql-set-transaction.html) を使い、次のように指定するとできるようです。
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

まずトランザクションを開始します。([`START TRANSACTION`コマンド](https://www.postgresql.jp/docs/11/sql-start-transaction.html) でもよいですが、今回は短く書ける [`BEGIN`コマンド](https://www.postgresql.jp/docs/11/sql-begin.html) の方を使います)
```
example=# BEGIN;
BEGIN
```

ここで再度`SET TRANSACTION`コマンドを実行してみます。今度は警告が出ませんでした。
```
example=# SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET
```

分離レベルを確認すると、`repeatable read`に変わっています。
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

準備もできたので、4つの現象を一つずつ確認していきます。

まず始めはダーティリードです。  
マニュアルには次のように書かれています。
> ダーティリード
> 同時に実行されている他のトランザクションが書き込んで未だコミットしていないデータを読み込んでしまう。

前述した通り、PostgreSQLではこの現象は起きません。(リードアンコミッティド分離レベルでも許容しない方向に倒して実装されているため)  
なのでここでは「起きないこと」を確認します。

まず、psqlからセッションを2つ作ります。本記事では便宜上`client1`、`client2`と呼ぶことにします。  
セッションを作ったら、リードアンコミッティド(`READ UNCOMMITTED`)分離レベルで、どちらもトランザクションを開始します。 分離レベルを確認すると期待した状態になっていることがわかります。

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

次に、反復不可能読み取りを見ていきます。

マニュアルには次のように書かれています。
> 反復不能読み取り
トランザクションが、以前読み込んだデータを再度読み込み、そのデータが(最初の読み込みの後にコミットした)別のトランザクションによって更新されたことを見出す。 

「 [13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html) 」より

あるトランザクション内で同じ行を2回読み取ります。他のトランザクションによる変更で、1回目と2回目の読み取り結果が変わってしまうことを確認してみます。
client1, client2ともに、リードコミッティド分離レベルでトランザクションを開始します。前述の表では反復不可能読み取りが「可能性あり」となっているため現象を起こせるはずです。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN
```

client1で名前を変更します(`Alice`->`Carol`)。まだコミットはしません。
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

### リピータブルリード分離レベルでは本当に起きないか？

トランザクション分離レベルを一段階厳密なリピータブルリードにしてトランザクションを開始した場合、本当の起きないかを確認します。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN
```

(最後の結果以外は同じなので実施例は割愛します)

client1の変更は反映されず、client2は常にトランザクションを開始時点が値が見えました。
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Alice
(1 row)
```

たしかにリピータブルリード分離レベルであれば、反復不可能読み取りは起こらないようです。

## ファントムリード

次はファントムリードです。

マニュアルには次のように書かれています。
> ファントムリード
トランザクションが、複数行のある集合を返す検索条件で問い合わせを再実行した時、別のトランザクションがコミットしてしまったために、同じ検索条件で問い合わせを実行しても異なる結果を得てしまう。

「 [13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html) 」より

PostgreSQLの場合リピータブルリード分離レベルではファントムリードは起きません。そのため一つ弱いリードコミッティドでこの現象を確認します。

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

このあと使うので、消してしまった行はデータを戻しておきます。

### リピータブルリード分離レベルでは本当に起きないか？

リピータブルリード分離レベルの場合、ファントムリードは「許容されるが、PostgreSQLでは発生しない」となっています。  
なので、このトランザクション分離レベルでファントムリードが起きないことを確認してみます。

まず、client1, client2ともに、リピータブルリード分離レベルでトランザクションを開始します。
```
example=# BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN
```

**(client1のコミットまでの操作は、前述と同じなので割愛します)**

最後にclient2で、client1が削除したid=1の行を確認してみます。  
行が残っています。たしかにリピータブルリード分離レベルではファントムリードが起こりませんでした。  
(client2はトランザクション開始時の状態が見えています)
```
example=# SELECT * FROM users;
 id | name
----+-------
  1 | Alice
(1 row)
```

では、実際は既に消されているこの行を変更しようとするとどうなるのでしょうか？  
結果はエラーになります。
```
example=# UPDATE users SET name = 'Bob' WHERE id = 1;
ERROR:  could not serialize access due to concurrent update
```

マニュアルには次のように書かれており、これは期待通りの動作です。
> 最初の更新処理がコミット（かつ、単にロックされるだけでなく、実際に行が更新または削除）されると、リピータブルリードトランザクションでは、以下のようなメッセージを出力してロールバックを行います。  
ERROR: could not serialize access due to concurrent update  
これは、リピータブルリードトランザクションでは、トランザクションが開始された後に別のトランザクションによって更新されたデータは変更またはロックすることができないためです。

「 [13.2.2. リピータブルリード分離レベル](https://www.postgresql.jp/docs/11/transaction-iso.html) 」より

リピータブル分離レベルではファントムリードが起こらないことを確認できました。

## 直列化異常

最後は直列化異常です。

マニュアルには次のように書かれています。
> 直列化異常
複数のトランザクションを正常にコミットした結果が、それらのトランザクションを1つずつあらゆる可能な順序で実行する場合とは一貫性がない。

前述の表だとこの現象はシリアライザブル分離レベル以外では「可能性あり」となっています。そのためリピータブルリード分離レベルでこの現象は起きるはずです。

今回はマニュアルに載っている例を使って確認していきます。まずテーブルを作成します。
```
example=# CREATE TABLE mytab (
example(# class INTEGER NOT NULL,
example(# value INTEGER NOT NULL
example(# );
CREATE TABLE
```

次にテスト用のデータを入れます。
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

client1で、まずclass=**1**の総和を計算します。
```
example=# SELECT SUM(value) FROM mytab WHERE class = 1;
 sum
-----
  30
(1 row)
```
さらにその結果(`30`)を、class=**2**の行として追加します。(もう一つのclassの値として追加しているのがポイントです)
```
example=# INSERT INTO mytab VALUES (2, 30);
INSERT 0 1
```

ここでclient2へ切り替えます。
client2では、class=**2**の総和を計算します。
```
example=# SELECT SUM(value) FROM mytab WHERE class = 2;
 sum
-----
 300
(1 row)
```
さらにこの結果(`300`)をclass=**1**の行として追加します。(もう一つのclassの値として追加しているのがポイントです)
```
example=# INSERT INTO mytab VALUES (1, 300);
INSERT 0 1
```

では、client1とclient2を順にコミットしていきます。
どちらも成功しました。
```
example=# COMMIT;
COMMIT
```

後からコミットした方(この場合はclient2)では、先にコミットした方(client1)が追加した値(class=2, value=30)が、総和に加味されないままコミットされてしまいました。  
もし以下のようにトランザクションを一つずつ`BEGIN`→`COMMIT`した場合なら、後のトランザクションは、先のトランザクションの追加分を必ず含めて総和を計算されるはずです。
```
client1:BEGIN → client1:COMMIT → client2:BEGIN → client2:COMMIT
```

これはclient1とclient2のコミット順を逆にしたとしても同じです。  
このようにトランザクションをどの順番で一つずつ実行したとしても、並列で実行した結果と一致しない状態を直列化異常と呼びます。
現象を確認することができました。

### シリアライザブル分離レベルでは本当に起きないか？

では、これがシリアライザブル分離レベルではどうなるのかを確認してみます。
前述の操作で新たな行が追加されてしまっているので、テストデータは元の状態(以下)に戻しておきます。
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

client1のコミット後に、client2でコミットしてみます。  
シリアライザブル分離レベルではエラーになりました。
```
example=# COMMIT;
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during commit attempt.
HINT:  The transaction might succeed if retried.
```

client1, client2どちらを先に実行しても、後から実行したほうの総和の計算が合わなくなってしまいます。そのため後からコミットしたほうは正常終了にはならずこのようにエラーとなります。  
シリアライザブル分離レベルでは、直列化異常(どちらも正常終了してしまう)が起きないことが確認できました。

## まとめ

実際に手を動かしつつ、PostgreSQLにおけるトランザクション分離レベルの違いを確認しました。  
データ指向アプリケーションデザイン(7章 トランザクション)を読んでからだと、マニュアルに書かれていることも理解しやすかったように思えます。
マニュアルを何回か読んで入るがいまいち頭に入ってこないという方は、一度この章を読んでみるとよいかもしれません。

## 参考
* [O'Reilly Japan - データ指向アプリケーションデザイン](https://www.oreilly.co.jp/books/9784873118703/)
* [MySQL の InnoDB でトランザクション分離レベルの違いを試す - CUBE SUGAR CONTAINER](https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels)
* [A Critique of ANSI SQL Isolation Levels - Microsoft](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/tr-95-51.pdf)
* [13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)
* [トランザクション分離レベル - Wikipedia](https://ja.wikipedia.org/wiki/%E3%83%88%E3%83%A9%E3%83%B3%E3%82%B6%E3%82%AF%E3%82%B7%E3%83%A7%E3%83%B3%E5%88%86%E9%9B%A2%E3%83%AC%E3%83%99%E3%83%AB)
* [第7回　トランザクション](https://oss-db.jp/dojo/dojo_info_07)
