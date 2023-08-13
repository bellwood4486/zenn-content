---
title: "Cloud Run上で一時ファイルを作るときはメモリ消費に気をつける"
emoji: "📁"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["cloudrun", "golang"]
published: false
---

## はじめに

Cloud Runのドキュメントに以下の記述があるのを見つけました。

> **ファイル システムへのアクセス**
> 
> 各コンテナ内のファイル システムは書き込み可能で、次の動作の影響を受けます。
> - これはインメモリ ファイル システムであるため、**書き込みにはインスタンスのメモリが使用されます**。
> - インスタンスが停止すると、ファイル システムに書き込まれたデータは保持されません。

出典: [コンテナ ランタイムの契約](https://cloud.google.com/run/docs/container-contract?hl=ja#filesystem)

> **HTTP 500 / HTTP 503: コンテナ インスタンスがメモリの上限を超えている**
> (...中略...)
> Cloud Run では、ローカル ファイル システムに書き込まれるファイルは**使用可能なメモリにカウントされます**。これには、/var/log/* と /dev/log 以外の場所に書き込まれるログファイルも含まれます。

出典: [Cloud Run のトラブルシューティング](https://cloud.google.com/run/docs/troubleshooting?hl=ja#memory)

この記事は、Goで書いた検証用のコードをCloud Run上で動かしつつ、一時ファイルの生成とメモリ消費の挙動を確認した記録です。

なお、本記事の内容は↓の記事で既に調査されており参考にさせていただきました🙏
https://zenn.dev/yamato_sorariku/articles/7adb5818579df7

## TL;DR

- 公式ドキュメント通り、Cloud Run上でファイルシステムにファイルを書き込みと、インスタンスに割り当てたメモリが消費される。
- 割当メモリを一気に超えるサイズのファイルを生成すると、指標「コンテナメモリ使用率」にも現れない場合もある。

## 検証環境

- Cloud Runインスタンス
  - メモリ: 128MiB
  - 最大インスタンス数: 1
  - その他はデフォルト
- Go
  - go 1.20.7

検証に使ったコードはこちらです。

https://github.com/bellwood4486/sample-go-gcp/tree/main/run/helloworld

デプロイは次のように `gcloud` で行いました。
```shell
$ gcloud run deploy helloworld --memory=128Mi --max-instances=1 --source .
```

## ファイル生成時のメモリ消費は本当か？

公式ドキュメントに書いてあるし、調査記事もあるので本当ではあるのですが、自分でも確認してみました。

ローカルファイルシステムにファイルを生成するコードは次の部分です。  
1KB分の適当なバイナリデータを、指定したサイズ分(MB)だけ書き込むだけです。
```go
func createDummyFile(dir string, sizeInMB int) error {
	f, err := os.CreateTemp(dir, dummyFilePrefix)
	if err != nil {
		return err
	}

	b := make([]byte, 1*KB)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	until := sizeInMB * MB / len(b)
	for i := 0; i < until; i++ {
		if _, err := f.Write(b); err != nil {
			return err
		}
	}
	if err := f.Close(); err != nil {
		log.Fatal(err)
	}

	return nil
}
```

GETメソッドでやるのは適切ではないですがちょっと手を抜き、次のURLにアクセスすると、指定したサイズのファイルが作られるようにしておきます。
```
GET https://{FQDN}/dummy:add?size={MB}
```

この仕組みを使って最大メモリを超えさせてみます。

### 最大メモリに徐々に近づけ超過させる

まず小さめな一時ファイルが徐々に溜まっていく想定でファイルを作ってみます。

最大メモリ128MiBのインスタンスに対して、1MB/1秒のペースで10分間ファイルを作り続けてみます。  
定期的にリクエストを送るにあたっては [nakabonne/ali](https://github.com/nakabonne/ali) というツールを使っています。送信頻度や期間など簡単に指定でき、また結果も見やすく便利です。

今回のケースでは次のコマンドで実行します。
```shell
$ ali --rate=1 --duration=10m "https://{FQDN}/dummy:add?size=1"
```
:::details 【参考】aliの画面例
![aliの画面例](https://github.com/bellwood4486/sample-go-gcp/assets/2452581/19d16d21-959d-4065-b27e-0dc6542b1b3b)
:::

実行の結果、Cloud Runのメトリクスは次のようになりました。(関連あるものを抜粋)  
実行時間は11:21〜11:31頃です。
![メモリ](https://github.com/bellwood4486/sample-go-gcp/assets/2452581/2640806d-4468-4b4f-afea-654af3b8878b)

サービス自身の消費メモリを無視したとすると、毎秒1MBのローカルファイルが作られるので、128秒後にはインスタンスの最大メモリを超えるはずです。  
10分(600秒)間実行するので 600/128≒4.7 となり、**ピークは4回は迎える**試算となります。

メトリクスもたしかに4回山があり、想定した通りの挙動をしていることがわかります。

記録上の回数は1回多いものの、次のような形で最大メモリ(128MiB)を超過したことがレポートされました。  
【概要】
![メモリ超過(概要)](https://github.com/bellwood4486/sample-go-gcp/assets/2452581/a26c8c8b-9b48-4fb6-8dd7-6bc76a156aba)
【詳細】
![メモリ超過(詳細)](https://github.com/bellwood4486/sample-go-gcp/assets/2452581/fb6a5c56-55a7-461b-87d2-a5615ddfb2a1)

最大メモリ超過時のログも見てみます。
![ログ](https://github.com/bellwood4486/sample-go-gcp/assets/2452581/edc36933-2d66-4788-b8f2-c5ef4b8b3140)
ログの流れは次の通りで、メモリ超過後インスタンスはシャットダウンされ、新しいインスタンスが起動していることがわかります
1. メモリ超過がログに記録される。
2. SIGTERMシグナルをサーバーが受け取る。
3. サーバーが停止する。
4. 次のリクエストが来る。
5. リクエストをトリガーに新しいインスタンスが起動する。

:::message
メモリ超過時のシャットダウンにおいてSIGTERMが送られることは、公式ドキュメントに書かれていません。
そのためあくまでも今回の検証での挙動です。この挙動を前提としないようお願いします。
:::

公式ドキュメントにある次の挙動は今回の検証では確認されませんでした。推測ですが今回の1rps程度ではサーバーの停止と起動が間に合ってしまうため発生しなかった可能性が高いです。
> HTTP 500 / HTTP 503: コンテナ インスタンスがメモリの上限を超えている

### 最大メモリを一気に超過させる

では次に、最大メモリを超えるファイルを1回のリクエストで作り、その際の挙動を見てみたいと思います。

最大メモリ(128MiB)を超える150MBのファイルを作るリクエストを送ってみます。
```
GET https://{FQDN}/dummy:add?size=150
```
実施時間は 12:36 付近です。

実行するとすぐ次のエラーレポートが表示されました。
![メモリ超過(概要)](https://github.com/bellwood4486/sample-go-gcp/assets/2452581/120e7d69-16a9-47bb-981d-22af48b05faa)

今回がたまたまな可能性はありますが、1回のリクエストで一気に超過するケースではコンテナメモリ使用率に記録が残らない場合もあるのかもしれません。
![メトリクス](https://github.com/bellwood4486/sample-go-gcp/assets/2452581/df9e1d73-353b-434c-b2b3-1a5c75fabd76)

ログには次のエラーが記録されており、想定通りの挙動でした。
```text
Memory limit of 128 MiB exceeded with 152 MiB used. Consider increasing the memory limit, see https://cloud.google.com/run/docs/configuring/memory-limits
```

### (おまけ)動画

情報を漁っているなかで、Cloud Run上の一時ファイルに関して語られてい動画を見つけました。
https://www.youtube.com/watch?v=L3vClxcAsnY

この動画だと[0:23](https://youtu.be/L3vClxcAsnY?t=23)あたりで、次のように話されています。
>Your Cloud Run servers can write files to a temporary file system that is reset between requests

英語が得意ではない筆者は一瞬「えっ！1リクエスト毎にリセットしているの！？」と思ってしまったのですが、上記検証結果や公式のドキュメントを見る限り「インスタンスの状況によってはリセットされている場合もあるし残っている場合もある」ぐらいの認識で良さそうです。

## ファイルシステムの容量とかはどうなっているのか？

公式ドキュメントでは、システムのファイルサイズについては次のように記載されています。

> このファイル システムにはサイズの上限を指定できないため、

出典: [コンテナ ランタイムの契約](https://cloud.google.com/run/docs/container-contract?hl=ja#filesystem)

では、実際にファイルシステムの容量を取得するとどんな値が取れるのか、次のコードで確認してみます。(これらの結果をJSONで返すようにしています)
```go
package main

import "syscall"

type diskUsage struct {
	// see: https://linuxjm.osdn.jp/html/LDP_man-pages/man2/statfs.2.html
	fs syscall.Statfs_t
}

func newDiskUsage(path string) (*diskUsage, error) {
	usage := &diskUsage{}
	err := syscall.Statfs(path, &usage.fs)
	if err != nil {
		return nil, err
	}
	return usage, nil
}

// ファイルシステムの総容量を返す
func (du *diskUsage) size() uint64 {
	return du.fs.Blocks * uint64(du.fs.Bsize)
}

// ファイルシステムの空き容量を返す
func (du *diskUsage) free() uint64 {
	return du.fs.Bfree * uint64(du.fs.Bsize)
}

// 非特権ユーザーが利用可能な空き容量を返す
func (du *diskUsage) avail() uint64 {
	return du.fs.Bavail * uint64(du.fs.Bsize)
}

// ファイルシステムの使用量を返す
func (du *diskUsage) used() uint64 {
	return du.size() - du.free()
}
```

結果は次のようになりました。インスタンスに設定した最大メモリサイズでもない極めて大きな値が取れるようです。
```json5
{
  "size": "8589934592.00GB", // ファイルシステムの総容量
  "free": "8589934592.00GB", // ファイルシステムの空き容量
  "available": "8589934592.00GB", // 非特権ユーザーが利用可能な空き容量
  "used": "0B" // ファイルシステムの使用量
}
```

設定したメモリサイズでもないので、Cloud Run上では「`n`MB以上の空き容量が残っているか？」みたいなチェックは意味をなさないことがわかります。

## まとめ

手を動かして実験しつつ、Cloud Run上でファイルを書き込むときの挙動を確認してみました。
公式ドキュメントにも書かれている通り、ローカルファイルシステムに書き込むとインスタンスのメモリが消費されました。
ファイルシステムへ書き込むサービスだと、インスタンスの最大メモリを設計する際に考慮すべき点が増えてしまいます。
歴史的経緯などもあるかもしれませんが、基本的にはファイルシステムへの書き込みは避け、外部ストレージを利用するほうが良さそうです。

## 参考

- [【Cloud Run】そのメモリ不足はコンテナ内に出力されたファイルが原因かもしれない話](https://zenn.dev/yamato_sorariku/articles/7adb5818579df7)
- [コンテナ ランタイムの契約 | Cloud Run のドキュメント | Google Cloud](https://cloud.google.com/run/docs/container-contract?hl=ja) 
- [Cloud Run のトラブルシューティング | Cloud Run のドキュメント | Google Cloud](https://cloud.google.com/run/docs/troubleshooting?hl=ja)
- [コンテナ インスタンスに送信されるトラップ終了シグナル（SIGTERM） | Cloud Run のドキュメント | Google Cloud](https://cloud.google.com/run/docs/samples/cloudrun-sigterm-handler?hl=ja)
- [Go言語: ファイルの存在をちゃんとチェックする実装? - Qiita](https://qiita.com/suin/items/b9c0f92851454dc6d461#comment-70c188ae8ad783fe57f9)
- [How to generate random bytes with Golang?| Practical Go Lessons](https://www.practical-go-lessons.com/post/how-to-generate-random-bytes-with-golang-ccc9755gflds70ubqc2g)
- [How to get the disk usage information in Golang?](https://www.includehelp.com/golang/get-the-disk-usage-information.aspx)
- [Man page of STATFS](https://linuxjm.osdn.jp/html/LDP_man-pages/man2/statfs.2.html)
- [gcloud run deploy | Google Cloud CLI Documentation](https://cloud.google.com/sdk/gcloud/reference/run/deploy)
- [nakabonne/ali: Generate HTTP load and plot the results in real-time](https://github.com/nakabonne/ali)
