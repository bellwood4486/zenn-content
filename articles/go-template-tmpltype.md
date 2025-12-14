---
title: "Goのテンプレートをコードから切り離す試み ─ tmpltype の紹介"
emoji: "📝"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["go", "codegen", "template"]
published: false
---

## はじめに

こんにちは、HRBrainの鈴木です。この記事は [HRBrain Advent Calendar 2025](https://qiita.com/advent-calendar/2025/hrbrain) の記事です。

Goのテンプレートを使った開発で「なんとかならないかな」と思うところがあり、
生成AIの登場で、AST解析やコード生成といった普段触らない技術も試しやすくなったのも機に、
趣味プロジェクトとして取り組んでみました。

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

## 基本的な使い方

こうした課題に対するアプローチとして、テンプレートはシンプルなテキストファイルとしてコミットしておき、そこからGoの型定義と `Render` 関数を自動生成する方法を採りました。

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

**型指定 ─ string 以外の型を使う**

パラメータの型はデフォルトで `string` になります。数値やポインタなど別の型を使いたい場合は、`@param` ディレクティブで指定できます。

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

**グルーピング ─ 関連するテンプレートをまとめる**

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

テンプレートは純粋なテキストファイルとして管理できるので、誰でも編集可能です。エンジニア以外のメンバーでも自分で文言修正をしやすくなります。

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

新しいテンプレートを追加する場合も、型定義や `Render` 関数は自動生成されるので、すぐに使い始められます。

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
│             │    │   判定      │    │ - 名前付き型抽出 │    │   ソース出力  │
└─────────────┘    └─────────────┘    └─────────────────┘    └─────────────┘
```

1. **cmd/tmpltype**: 指定されたディレクトリからテンプレートファイル（`.tmpl`）を収集し、後続の処理に渡します。
2. **internal/scan**: 各テンプレートをASTとして解析し、フィールド参照を抽出します。この段階ではまだGo型ではなく、「スライスっぽい」「構造体っぽい」といった種別（Kind）を判定します。
3. **internal/typing**: 判定されたKindをGoの具体的な型（`[]struct{...}` や `map[string]T` など）に変換します。`@param` ディレクティブによる上書きもここで適用します。
4. **internal/gen**: 最終的な型情報をもとに、パラメータ用の構造体定義と `Render` 関数のGoコードを生成します。

AST解析と型変換のロジックを分離したかったので、scan と typing の間に **Kind（種別）** という中間表現を挟む構成にしました。scan では「スライスっぽい」「構造体っぽい」といった種別だけを判定し、具体的なGo型への変換は typing に委ねています。

この構成のおかげで、`@param` のようなマジックコメントによる独自ディレクティブも typing 段階へ追加するだけで対応できました。

### 型判定の仕組み

型判定では、`text/template` が提供する AST（抽象構文木）を使ってテンプレートを解析しています。

型は、テンプレート内でのフィールドの**使われ方**と**子フィールドの有無**の組み合わせで決まります。そのため、まずフィールド間の親子関係を洗い出す必要があります。

例えば `{{ range .Items }}{{ .Title }}{{ end }}` というテンプレートがあった場合：

1. `.Items` を発見 → まずは `string` として仮登録
2. `range` ブロック内に入る → `.Items` のスコープを親として記録
3. `.Title` を発見 → 親が `.Items` であることを検出
4. `.Items` には子フィールド `.Title` が存在することが判明 → `.Items` の型を `[]struct{ Title string }` に昇格

このように、**子フィールドの存在を検出したタイミングで、親の型を `string` から `struct` へ動的に昇格させる**アルゴリズムになっています。テンプレートは文字列を扱うユースケースが多いと仮定して、デフォルトの型は `string` としています。

主な判定パターン：
- 子フィールドがあれば `struct{...}` へ昇格
- `range` で反復処理されていれば `[]T` のスライス型
- `index` でキーアクセスされていれば `map[string]T` のマップ型
- `with` や `if` などのブロック構文も同様にスコープとして追跡

これらを組み合わせることで、テンプレートが求める構造を推定しています。

ただし、ロジックだけで型を完全に特定することは難しいため、`@param` ディレクティブで明示的に上書きできる仕組みで補う構成をとっています。

## まとめ

テンプレートをコードから切り離し、ファイルとして管理しつつ、型安全に扱えるようにするアイディアを tmpltype として形にしてみました。テンプレートの一覧性やボイラープレートの削減といった課題に対する、ひとつのアプローチとしてご紹介しました。

AST解析やコード生成など、日々の開発ではあまり触れない技術でしたが、生成AIの力を借りることでアイディアを形にしやすかったです。
ただASTまわりの実装を込み入らずに書くのは難しく、まだまだ改善の余地はありそうです。

また、子育ての合間のような細切れの時間でも少しずつ進められたのは、個人的に嬉しいポイントでした。

詳しい使い方は [ドキュメント](https://github.com/bellwood4486/tmpltype/tree/main/docs) 、動くサンプルは [examples](https://github.com/bellwood4486/tmpltype/tree/main/examples) にありますので、 もし興味があればぜひ試してみてください！

https://github.com/bellwood4486/tmpltype
