---
title: "Goテンプレートの型安全なコード生成ツール tmpltype を作った"
emoji: "📝"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["go", "codegen", "template"]
published: false
---

## はじめに

Goのテンプレートを使った実装をするなかで、やってみたかったアイディアを形にしてみました。生成AIが登場して、腰が重くなかなか手が出せなかったところもとても実装しやすくなったなと感じています。

この記事では、そのアイディアを実現したツール **tmpltype** を紹介します。

https://github.com/bellwood4486/tmpltype

## こんなことありませんか？

Goでテンプレートを扱っていると、こんな課題に遭遇することはないでしょうか。

### コードとテンプレートが密結合している

テンプレートがコード内の定数として定義されていたり、埋め込まれていたりすると、ちょっとした文言を変えたいだけでもエンジニアしか触れません。

```go
// こんな感じでコードに埋まっていると...
const welcomeTemplate = `こんにちは、{{.Name}}さん！`
```

### テンプレートの一覧性が低い

定数やembedで分散して定義されていると、「今どんなテンプレートがあるのか」を把握するのが大変です。コードを grep して回る必要があります。

### ボイラープレートが多い

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

## tmpltype でできること

tmpltype は、テンプレートファイルから型安全なGoコードを自動生成するツールです。

### 基本的な使い方

1. `.tmpl` ファイルを作成します

```text
// templates/welcome.tmpl
こんにちは、{{.Name}}さん！
本日は{{.Date}}です。
```

2. コード生成を実行します

```bash
tmpltype -dir ./templates -pkg mytemplate -out ./mytemplate
```

3. 型安全なコードが生成されます

```go
// 自動生成された構造体
type WelcomeParams struct {
    Name string
    Date string
}

// 自動生成されたRender関数
func RenderWelcome(params WelcomeParams) (string, error) {
    // ...
}
```

### 主な機能

- **型指定**: `@param` ディレクティブで型を明示的に指定できます
- **グルーピング**: ディレクトリ構造でテンプレートをグルーピングできます
- **型推論**: テンプレートの使われ方から型を推論します

詳しい使い方は [examples](https://github.com/bellwood4486/tmpltype/tree/main/examples) を参照してください。

### これで何が嬉しいか

**コードとテンプレートを分離できる**

テンプレートファイルは純粋なテキストファイルなので、エンジニア以外のメンバーでも文言の修正が可能になります。

**テンプレートの一覧性が向上する**

ディレクトリを見れば、どんなテンプレートがあるか一目でわかります。コードを読む必要がありません。

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

**ボイラープレートが不要になる**

構造体の定義やRender関数の実装は自動生成されるので、テンプレートファイルを追加するだけで済みます。

## 内部構造

tmpltype は、テンプレートファイルを読み込んでGoコードを生成するアプローチを取っています。

### 4段構成のパイプライン

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
3. **internal/typing**: KindからGo型への変換、`@param`ディレクティブの適用
4. **internal/gen**: 構造体とRender関数のコード生成

このように段階を分けることで、マジックコメントによる独自ディレクティブの追加なども柔軟に行えるようにしています。

### 出力ファイル

- `template_gen.go`: 型定義、`InitTemplates()`、`Render*()`関数
- `template_sources_gen.go`: テンプレート文字列リテラル

### go:embed から複製方式への変更

当初は `go:embed` でテンプレートを埋め込む方式を検討していましたが、ビルドされたバイナリにどのテンプレートが含まれているかを明確にするため、テンプレート内容をソースコードとして複製する方針にしました。

## まとめ

テンプレートのメンテナンスをコードから切り離しやすくするアイディアを、tmpltype として形にしてみました。

生成AIの登場で、アイディアを形にするハードルがとても下がったと感じています。コード生成のような「やってみたいけど腰が重い」実装も、ずいぶん取り組みやすくなりました。

また、生成されたコードを写経しながら調べることで学びも得られました。自分の場合はAST解析の部分が特に勉強になりました。

OSSでよく見る examples ディレクトリの例示も、AIの助けを借りて作りやすかったのもよかったです。

興味があればぜひ試してみてください。

https://github.com/bellwood4486/tmpltype
