---
title: "マイクロサービスの開発環境をCloud Workstationsへ移して手元のマシンを軽くする"
emoji: "✨"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: []
published: false
---

## アウトライン

* 既存の環境(通称Tilt環境)
* Cloud Workstationsとは
* 開発用のWorkstationを用意する
  * terraformで用意する
  * メアドの先頭を利用する
  * カスタムイメージを準備する
    * tiltをプリインストールする
* Tilt環境をWorkstation上で立ち上げる
* ローカルPCから繋ぐ(macOS)
  * 標準搭載の仕組み
  * CORSのプレフライトリクエスト問題
  * 回避策
    * 最終形：gcloudトンネル -> sshセッション -> ローカルポートフォワーディング
    * ボツ：gcloudで各ポートをトンネルする
      * 通信安定化施策：flow-limit-proxy
* Workstation上のファイルを編集する
  * VSCode Server
  * VSCode
  * Goland
* その他
  * ディスク容量対策：起動時クリーンナップ
* まとめ

## はじめに

## 既存の環境(通称Tilt環境)

## Cloud Workstationsとは

## 開発用のWorkstationを用意する

###  terraformで用意する
Workstationの名前はメアドの先頭を利用する

###  カスタムイメージを準備する
tiltをプリインストールする
起動時の運用スクリプト

## Tilt環境をWorkstation上で立ち上げる

## ローカルPCから繋ぐ(macOS)

### 標準の仕組みとプレフライトリクエスト問題

### 回避策
最終形：gcloudトンネルとsshポートフォワーディングとの組み合わせ
SSHローカルポートフォワーディング
トンネル用シェルスクリプトでまとめて一発起動

ボツ：gcloudで各ポートをトンネルする
通信安定化施策：flow-limit-proxy

## Workstation上のファイルを編集する

### VSCode Server / VSCode

### Goland

## その他

### ディスク容量対策：起動時クリーンナップ

## まとめ
