---
title: "PostgreSQLのトランザクション分離レベルを試す"
emoji: "🔖"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["postgresql"]
published: false
---

## はじめに

しばらく積読していた「データ指向アプリケーションデザイン」を読み終え、わかったようでわかってなかった「トランザクション分離レベル」がついにわかるかも！？熱が高まってきてたときに、こちらの記事と出会い、理解の確認がてらPostgreSQLで試してみました。

## 環境
* macOS 10.15.7
* Docker Desktop for Mac 4.3.2
* PostgreSQL 11.14

セットアップはこちらを参照。
https://zenn.dev/bellwood4486/articles/postgresql-psql-docker

## トランザクション分離レベル

PostgreSQLのトランザクション分離レベルについては、公式ドキュメントのここに書かれています。
https://www.postgresql.jp/docs/11/transaction-iso.html

ANSI/ISO SQL標準では次の4つの分離レベルが定義されています。
* Read uncommitted
* Read committed
* Repeatable read
* Serializable

PostgreSQLでは、各種レベルにおける禁止される4つの現象が示されています。
* dirty Read
* nonrepeatable Read
* phantom read
* serialization anomaly




## 参考資料
* [O'Reilly Japan - データ指向アプリケーションデザイン](https://www.oreilly.co.jp/books/9784873118703/)
* [MySQL の InnoDB でトランザクション分離レベルの違いを試す - CUBE SUGAR CONTAINER](https://blog.amedama.jp/entry/mysql-innodb-tx-iso-levels)
* [13.2. トランザクションの分離](https://www.postgresql.jp/docs/11/transaction-iso.html)
* [トランザクション分離レベル - Wikipedia](https://ja.wikipedia.org/wiki/%E3%83%88%E3%83%A9%E3%83%B3%E3%82%B6%E3%82%AF%E3%82%B7%E3%83%A7%E3%83%B3%E5%88%86%E9%9B%A2%E3%83%AC%E3%83%99%E3%83%AB)
