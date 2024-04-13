---
title: "マイクロサービスの開発環境をCloud Workstationsへ移して手元のマシンを軽くする"
emoji: "✨"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: []
published: false
---

## はじめに

## メモ

* 既存の環境(Tilt環境)
* Cloud Workstationsとは
* Tilt環境をCloud Workstationsを用意する
  * terraformで用意する
  * メアドの先頭を利用する
  * カスタムイメージを準備する
    * tiltをプリインストールする
* Tilt環境をCloud Workstationsで立ち上げる
* Macから繋ぐ
  * 標準搭載の仕組み
  * CORSのプレフライトリクエスト問題
  * 回避策
    * 最終形：gcloudトンネル -> sshセッション -> ローカルポートフォワーディング
    * ボツ：gcloudで各ポートをトンネルする
      * 通信安定化施策：flow-limit-proxy
* その他
  * ディスク容量対策：起動時クリーンナップ
  * Golandを使う
* まとめ
