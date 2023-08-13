---
title: "Cloud Run上で一時ファイルを作るときはメモリ消費に気をつける"
emoji: "📁"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: []
published: false
---

## はじめに

Cloud Runのドキュメントに以下の記述があるのを見つけました。

> HTTP 500 / HTTP 503: コンテナ インスタンスがメモリの上限を超えている
> (...中略...)
> Cloud Run では、ローカル ファイル システムに書き込まれるファイルは**使用可能なメモリにカウントされます**。これには、/var/log/* と /dev/log 以外の場所に書き込まれるログファイルも含まれます。

出典: [Cloud Run のトラブルシューティング](https://cloud.google.com/run/docs/troubleshooting?hl=ja#memory)

この記事は、Goで書いた検証用のコードをCloud Run上で動かしつつ、一時ファイルの生成とメモリ消費の挙動を確認した記録です。

なお、本記事の内容は↓の記事で既にほぼ調査済みであり、調査の際は参考にさせていただきました🙏
https://zenn.dev/yamato_sorariku/articles/7adb5818579df7
本記事の差分は、メモリ超過時のシャットダウンの部分ぐらいです。

## TL;DR

- 公式ドキュメント通り、ローカルファイルシステムにファイルを生成すると、インスタンスに割り当てたメモリが消費される。
- 割当メモリを一気に超えるサイズのファイルを生成すると、指標「コンテナメモリ使用率」にも現れない場合もある。
- (公式ドキュメント非記載なので未保証だが)、メモリ超過時もSIGTERMが送られるような挙動をしている。

## 検証環境

- Cloud Runインスタンス
  - CPU: 1000m
  - メモリ: 128MiB
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

最大メモリ128MiBのインスタンスに対して、1MiB/1秒のペースでファイルを作り続けてみます。

```shell

```

### 最大メモリを一気に超過させる

## メモリ超過時のシャットダウン

## まとめ

## 参考

- https://zenn.dev/yamato_sorariku/articles/7adb5818579df7

