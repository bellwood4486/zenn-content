---
title: "Goで大きなJSONからExcelファイルをメモリに優しく作る"
emoji: "🗂"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["golang"]
published: false
---

## はじめに

JSONで表現されたデータをExcelファイルに変換したい場合に、ストリームで行うことでメモリ消費量を抑えることができます。
本記事ではサンプルコードを用いてその方法を紹介します。なおサンプルはGoで実装しています。

## アプローチ

JSONファイルからExcelファイルを作る際、以下のようなアプローチが考えられます。

1. JSONファイルを構造体としてメモリ上に読み込む
2. 構造体をExcelファイルとして書き出す

### JSONをストリームで読み込む

JSONファイルを読み込む際、JSON全体を一括で読み込むとそれだけのメモリを必要としてしまいます。一括ではなく部分的にストリームで読み込むことができれば、メモリ消費量を抑えられそうです。

[`json.Decoder.Decode`](https://pkg.go.dev/encoding/json#Decoder)のドキュメントには次のように書かれています。

> Decode reads the next JSON-encoded value from its input and stores it in the value pointed to by v.

"reads the **next** JSON-encoded value" なので、位置をずらしながら読み込めば少しずつ読み込むことができそうです。  
公式ドキュメントには[ストリームでデコードする例](https://pkg.go.dev/encoding/json#example-Decoder.Decode-Stream)も載っており参考になります。この例ではオブジェクトの配列をオブジェクトごとに読み込んでいます。

### Excelファイルをストリームで書き出す

次はExcelファイルにストリームで書き出す方法です。

[excelize](https://github.com/qax-os/excelize)というライブラリがあります。

https://github.com/qax-os/excelize

このライブラリではストリームの書き込みをサポートしているので、ストリームでExcelへの書き込みもできそうです。
ストリームでの書き込みに関するドキュメントは[こちら](https://xuri.me/excelize/ja/stream.html)です。ストリームでない書き込みと行の挿入などできないこともあるのでそこは注意が必要です。

このライブラリでは[パフォーマンスの比較](https://xuri.me/excelize/ja/performance.html)も公開しています。
パフォーマンスデータの表内に、「50カラムの1つの行」をExcelとして書き込むケースのメモリ消費量が載っています。
非ストリーム(`SetSheetRow`)での書き込みと、ストリーム(`StreamWriter`)での書き込みのどちらも載っているのでグラフにしてみました。横軸は書き込む行数です。
書き込む行数が増えるほど消費量の差が大きくなることがわかるかと思います。

![image](https://user-images.githubusercontent.com/2452581/232276906-63e4a569-5b3b-4795-be68-fb2da128d24d.png)

道具は揃ったので、上記アプローチを組み合わせて実装してみます。

## サンプル実装

サンプル実装のライブラリはこちらにあります。  
https://github.com/bellwood4486/sample-go-json2excel

環境は以下の通りです。
* go1.20.3 darwin/arm64
* excelize v2.7.0
* macOS 13.2.1

データは、ユーザー情報っぽいものを100万人分用意します。JSONファイルのサイズは183MBになりました。

```json
{
  "users": [
    {
      "name": "user1",
      "age": 20,
      "profile": "Lorem ipsum dolor...(省略)"
    },
    {
      "name": "user2",
      "age": 20,
      "profile": "Lorem ipsum dolor...(省略)"
    },
    {
      "name": "user3",
      "age": 20,
      "profile": "Lorem ipsum dolor...(省略)"
    },
    ...
    {
      "name": "user1000000",
      "age": 20,
      "profile": "Lorem ipsum dolor...(省略)"
    }
  ]
}
```

このデータをストリームで読みながらさらにExcelとして書き出すサンプル実装はこちらです。

https://github.com/bellwood4486/sample-go-json2excel/blob/cf9f106ea7bd71cc646826ab39206da5ce50ef16/excel.go#L104-L168

138行目で、`uses`というJSONのトークンを見つけたら、各ユーザーごと処理する`parseUsers`という関数にデコーダーごと渡しています。

`parseUsers`の実装はこちらです。

https://github.com/bellwood4486/sample-go-json2excel/blob/cf9f106ea7bd71cc646826ab39206da5ce50ef16/excel.go#L170-L192

ユーザー一人ずつデコードし処理してます。

読み取りと書き込みを同時にやる都合上、全体的にこの2つの実装が密結合した感じになりました。パフォーマンスを優先したためこれは致し方ないかなと思います。

## メモリ消費量の比較

どれぐらいメモリ消費量を抑えられるのか、次の2パターンを実装してメモリ消費量を比較してみます。

| Case#  | JSONの読み込み | Excelの書き込み | 中間オブジェクトの生成 |
|--------|-----------|------------|-------------|
| Case 1 | 	batch    | 	stream    | 	yes        |
| Case 3 | 	stream   | 	stream    | 	no         |

(サンプルコードのリポジトリ内には`Case2`が存在しますが、あまり有用なパターンではないので割愛します)

この2つのケースにおけるメモリ消費量(`Used memory`)、実行時間(`Time`)、pprofの結果は次のようになりました。  
(この表の数値は、複数回実施した平均値などではなく適当な1回のデータです。ちょっと手を抜いてます)

| -           | Case 1                                                                                                             |  Case 3                                                                                                             |
|-------------|--------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| Used memory | 238.05MB                                                                                                           |  20MB                                                                                                               |
| Time        | 4.005241083s                                                                                                       |  3.859536417s                                                                                                       |
| pprof       | ![mem1 prof](https://user-images.githubusercontent.com/2452581/229333094-922bc58e-4578-4e85-b105-70a8ff07aaf2.png) |  ![mem3 prof](https://user-images.githubusercontent.com/2452581/229333099-3a4e067d-9154-41e0-b7a4-5938286f3218.png) |

Case1とCase3を比較すると、実行時間にそれほど差はないものの、メモリ消費量は約10分の1で済んでいることがわかります。

## JSONのフィールド順序との兼ね合い

今回のアプローチの場合、JSONファイルは上から順に読まれます。また、excelizeのストリーム書き込みでは挿入はできないので上から順に書いていく必要があります。  
つまり、JSONフィールドの登場順序がExcelの行の順序でないと、正しく書き込むことができません。

具体的な例で考えてみます。

今回のサンプルではハードコードでしたが、Excelのヘッダー情報もJSONのデータをもとに作りたいとします。例えば次のように`header`と`users`の2つのフィールドがあるイメージです。
```json
{
  "header": ["name", "age", "profile"],
  "users": [
    ...前述の例と同じ...
  ]
}
```

もし次のようにフィールドの登場順序が逆だと、Excelには`users`から書いていくことなり、ヘッダーとコンテンツの順序が逆になってしまいます。
```json
{
  "users": [
    ...前述の例と同じ...
  ],
  "header": ["name", "age", "profile"]
}
```

そのため、複数のJSONフィールドからExcelファイルを生成する場合は、例えば以下のような方法などで何かしら対策する必要があります。
* 何かしらの方法でJSONのフィールドの順序をコントロールできるようにする。
* フィールドの順序を保証できない場合は、あとから書くコンテンツ部分はストリーム読み出し可能な形式(例JSON)で中間ファイルに一旦シリアライズしておき、ヘッダーを書き込んだ後に再度ストリームでそこからコンテンツを書き込む。

## まとめ

Goの標準ライブラリとexcelizeを使うことで、読み書きの処理は密結合してしまうものの、比較的簡単に大規模なJSONデータでもメモリ消費量を抑えつつExcelファイルに書き出すことができました。
ただその副作用としてJSONフィールドの順序保証という新しい複雑さを取り込むことになるので、そこは注意が必要そうです。

## 参考

* [【golang】大きめなJSONのパース（pprof使って使用メモリもチェック） - Qiita](https://qiita.com/sky0621/items/5f4f38b261e2fd050ece)
* [json package - encoding/json - Go Packages](https://pkg.go.dev/encoding/json)
* [Excelize Official Docs](https://xuri.me/excelize/)
* [pprof package - runtime/pprof - Go Packages](https://pkg.go.dev/runtime/pprof#hdr-Profiling_a_Go_program)
