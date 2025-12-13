---
title: "Goのテンプレートのメンテナンスを切り離す試み ─ tmpltype の紹介"
emoji: "📝"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["go", "codegen", "template"]
published: false
---

## はじめに

こんにちは、HRBrainの鈴木です。この記事は [HRBrain Advent Calendar 2025](https://qiita.com/advent-calendar/2025/hrbrain) の記事です。

Goのテンプレートを使った開発で「なんとかならないかな」と思っていたことに、すきま時間を使って取り組みました。生成AIが登場したことで、AST解析やコード生成といった普段あまり触らない技術も試しやすくなり、アイディアを形にするハードルがぐっと下がったと感じています。

この記事では、そのツール **tmpltype** を紹介します。

https://github.com/bellwood4486/tmpltype

## こんなことありませんか？

メール通知だったり、その他Goのテンプレートを使って文面を作りたい場面はよくあると思います。そんなとき、こんなことはないでしょうか。

### 😢テンプレートの一覧性が低い

定数などでハードコードされていると、「今どんなテンプレートがあるのか？手元にドキュメントがあるけどこれは最新なのか？」を把握したいときにコードを grep して調べる必要があります。最新のテンプレート一覧をPdMやビジネスサイドにパッと共有したいときも、ちょっと面倒だったりします。

### 😢文言修正もエンジニア頼みに

テンプレートの文面がコード内の定数として埋め込まれていると、ちょっと文言を調整したいだけでもコードをいじることになります。結果として「エンジニアに依頼する」というオペレーションになりがちです。

```go
// こんな感じでコードに埋まっていると...
const welcomeTemplate = `こんにちは、{{.Name}}さん！`
```

### 😢ボイラープレートが多い

新しいテンプレートを追加するたびに、構造体を定義して、テンプレートを登録して...という定型作業が発生します。

```go
// テンプレートを1つ増やすだけなのに...
type NewTemplateParams struct {
    Field1 string
    Field2 int
}

func RenderNewTemplate(params NewTemplateParams) (string, error) {
    // ...
}
```

## 「静的解析」と「コード生成」でメンテナンスを切り離すアプローチ

こうした実装しつつもちょっと引っかかっていた部分に対して、テンプレートはシンプルなテキストファイルとしてコミットしておき、それを使いやすい形でGoのアプリケーション側に組み込めないかと考えました。

具体的には、ディレクトリ内に置いたテンプレートファイル群を読み込んで、パラメータを渡しやすいGoの型定義を作りつつ、各テンプレートの `Render` 関数を生成するツールです。

では、そのツール **tmpltype** を紹介します。

## 基本的な使い方

1. テンプレート文面を完結した1つのファイルとして用意します

```text
templates/
└── email.tmpl
```

```html:templates/email.tmpl
<h1>Hello {{ .User.Name }}</h1>
<p>{{ .Message }}</p>
```

2. テンプレートファイルをベースに、コード生成を実行します

```bash
tmpltype -dir ./templates -pkg main -out .
```

3. パラメータ用の型とRender関数が生成されます

```go
// 自動生成された構造体
type EmailUser struct {
    Name string
}

type Email struct {
    Message string
    User    EmailUser
}

// 自動生成されたRender関数
func RenderEmail(w io.Writer, params Email) error {
    // ...
}
```

4. 生成されたコードを呼び出して利用します。

```go:main.go
package main

import (
    "bytes"
    "fmt"
)

func main() {
    InitTemplates()

    var buf bytes.Buffer
    _ = RenderEmail(&buf, Email{
        User:    EmailUser{Name: "Bob"},
        Message: "Hello from type-safe params!",
    })
    fmt.Println(buf.String())
}
```

基本的な使い方はこれだけです。パラメータを構造体にセットして `Render` 関数に渡すと、テンプレートと合成された結果が出力されます。

### もう少し踏み込んだ使い方

**型指定**

パラメータの型はデフォルトで `string` になりますが、数値などstring型以外を扱いたいときは呼び出し側で型変換が必要になります。`@param` ディレクティブを使うことで、生成される構造体の型を指定できるようにしています。

```html:templates/user.tmpl
{{- /* @param User.Age int */ -}}
{{- /* @param User.Email *string */ -}}
{{- /* @param Items []struct{ID int64; Title string; Price float64} */ -}}

<h2>{{ .User.Name }} (Age: {{ .User.Age }})</h2>
{{ if .User.Email }}<p>Email: {{ .User.Email }}</p>{{ end }}
{{ range .Items }}
  <p>{{ .ID }}: {{ .Title }} - {{ .Price }}</p>
{{ end }}
```

**グルーピング**

メールのように件名と本文がセットになっているケースなどでは、関連するテンプレートをまとめて管理できると便利です。
サブディレクトリでまとめられてても対応できるようにしています。

```text
templates/
├── footer.tmpl
└── 01_mail_invite/
    ├── title.tmpl
    └── content.tmpl
```

```text:templates/01_mail_invite/title.tmpl
{{ .SiteName }}: Invitation from {{ .InviterName }}
```

こうすると `RenderMailInviteTitle`、`RenderMailInviteContent` のように、テンプレートごとの関数が生成されます。

詳しくは [examples](https://github.com/bellwood4486/tmpltype/tree/main/examples) を参照してください。

### これで何が嬉しいか

**😄コードとテンプレートを分離できる**

テンプレートファイルは純粋なテキストファイルなので、エンジニアでなくても編集しやすくなります。文言をちょっと直したいときも、コードを触る必要がありません。

**😄テンプレートの一覧性が向上する**

最新のテンプレート一覧を把握したい場合も、ディレクトリ内のファイルをリストアップするだけで、今どんなテンプレートがあるのかがわかり、把握しやすくなります。

```text
templates/
├── email/
│   ├── welcome.tmpl
│   ├── reset_password.tmpl
│   └── notification.tmpl
└── sms/
    ├── verification.tmpl
    └── alert.tmpl
```

**😄ボイラープレートが減る**

新しいテンプレートを追加しようとした場合も、型定義や `Render` 関数は自動で生成されるので、自前で書くボイラープレートも少なく済みます。

## 内部構造

このようなコード生成を実現する tmpltype の内部構造についてご紹介します。

### 4段構成のパイプライン

コード生成までの流れを、大きく4段階の構成にしています。

```text
┌─────────────┐    ┌─────────────┐    ┌─────────────────┐    ┌─────────────┐
│    cmd/     │    │  internal/  │    │    internal/    │    │  internal/  │
│  tmpltype   │───▶│    scan     │───▶│     typing      │───▶│     gen     │
│             │    │             │    │                 │    │             │
│ - flags解析  │    │ - AST解析    │    │ - Kind→Go型変換  │    │ - 構造体生成  │
│ - ファイル走査│    │ - スコープ追跡│    │ - @paramオーバー │    │ - Render関数 │
│             │    │ - 種別(Kind) │    │   ライド適用     │    │ - テンプレート │
│             │    │   推論      │    │ - 名前付き型抽出 │    │   ソース出力  │
└─────────────┘    └─────────────┘    └─────────────────┘    └─────────────┘
```

1. **cmd/tmpltype**: CLIのフラグ解析とファイルの走査
2. **internal/scan**: テンプレートのAST解析と型の種別（Kind）推論
3. **internal/typing**: KindからGo型への変換、マジックコメント含め型を決定
4. **internal/gen**: その結果をもとに構造体とRender関数のコード生成

このように段階を分けることで、マジックコメントによる独自ディレクティブの追加なども柔軟に行えるようにしています。
また、生成AIを使って実装する際、意図しない変更を入れられても、パッケージが分かれていると差分から気付きやすかったです。

### 型推論の仕組み

scan パッケージでは、Go の `text/template` が提供する AST（抽象構文木）を使ってテンプレートを解析しています。

テンプレート内のフィールド参照（`{{ .User.Name }}` など）を追跡しながら、どんな構造のデータが必要かを組み立てていきます。型の推論ルールは：

- 基本は `string`
- `range` で使われ、かつ子フィールドへのアクセスがあれば `[]struct{...}`
- `range` で使われているが子フィールドへのアクセスがなければ `[]string`
- `index` で使われ、かつ値に子フィールドへのアクセスがあれば `map[string]struct{...}`
- `index` で使われているが値に子フィールドへのアクセスがなければ `map[string]string`

この推論結果に対して、`@param` ディレクティブで上書きできる仕組みを typing パッケージで実装しています。

### 出力ファイル

- `template_gen.go`: 型定義、`InitTemplates()`、`Render*()`関数
- `template_sources_gen.go`: テンプレート文字列リテラル

## まとめ

テンプレートのメンテナンスをコードから切り離しやすくするアイディアを、tmpltype として形にしました。

AST解析やコード生成など、私の場合日々の開発ではそれほど使う頻度が高くない技術ですが、生成AIを使うことでアイディアを実現しやすくなったと感じています。

また、生成されたコードを写経しながら調べることで学び安くなったとも感じます。

OSSでよく見る examples ディレクトリの例示も、AIの助けを借りて作りやすかったです。

興味があればぜひ試してみてください。

https://github.com/bellwood4486/tmpltype
