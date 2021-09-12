---
title: "gRPC(Go)のキャンセルおよびHTTPサーバーと組み合わせたときの挙動はどうなってる？" # 記事のタイトル
emoji: "😸" # アイキャッチとして使われる絵文字（1文字だけ）
type: "tech" # tech: 技術記事 / idea: アイデア記事
topics: ["golang", "grpc"] # タグ。["markdown", "rust", "aws"]のように指定する
published: false # 公開設定（falseにすると下書き）
---

裏ではgRPCで別サービスと通信するようなRESTful APIサーバーをよく書くのですが、HTTPのコネクションが切れたときに、その先では何が起きているのかあまり理解できていなかったので、サンプルコードを書きつつ調べてみました。

## TL;DR
- HTTPサーバーは、HTTPコネクションが閉じられると、そのリクエストに紐づくコンテキストのキャンセルを呼ぶ。
- grpc-goのクライアントは、コンテキストがキャンセルされると、HTTP/2の`RST_STREAM`フレームをgRPCサーバー側へ送る。
- grpc-goのサーバーは、`RST_STREAM`フレームを受けると、サーバー側のコンテキストのキャンセルを呼ぶ。

## 環境

- golang: `go version go1.17 darwin/amd64`
- grpc-go: `google.golang.org/grpc v1.40.0`

## 調べる構成

今回調べたサンプルコードの構成は以下のとおりです。ソースコードは[こちら](https://github.com/bellwood4486/sample-go-grpc/tree/main/cancel_http)にあります。

```text
┌─────────────┐            ┌─────────────┐             ┌────────────┐
│cURL         │            │HTTP server  │             │gRPC server │
│             ├────────────►             ├─────────────►            │
│             │GET /sleep  │             │call Sleep   │            │
│             │    &       │             │             │            │
└─────────────┘timeout     └─────────────┘             └────────────┘
                after 2sec
```

■サーバー側：
- gRPC server
  - `Sleep`というAPIを用意します。このAPIでは5秒スリープしてレスポンスを返します。
- HTTP server
  - HTTPサーバーには`GET /sleep`というエンドポイントを用意します。
  - このエンドポイントはリクエストを受けると、gRPCサーバーの`Sleep`を呼びます。
  - gRPCのAPIを呼ぶときは、HTTPリクエストに含まれるコンテキストをそのまま渡します。

サーバー側ではコンソールにログを書くようにもしています。

■クライアント側：
- cURL
  - 5秒スリープするサーバー側に対し、cURLは2秒でタイムアウトするようなリクエストを`GET /sleep`エンドポイントへ送ります。
    ```shell
    curl -v -m 2 http://127.0.0.1:18081/sleep
    ```

2秒でクライアント(cURL)側がタイムアウトした場合に、サーバー側にはどのようなログが残るのかを見ます。

## 実行結果

実行したときのログは次のようになりました。

cURL
```
❯ curl -v -m 2 http://127.0.0.1:18081/sleep
*   Trying 127.0.0.1...
* TCP_NODELAY set
* Connected to 127.0.0.1 (127.0.0.1) port 18081 (#0)
> GET /sleep HTTP/1.1
> Host: 127.0.0.1:18081
> User-Agent: curl/7.64.1
> Accept: */*
> 
* Operation timed out after 2001 milliseconds with 0 bytes received
* Closing connection 0
curl: (28) Operation timed out after 2001 milliseconds with 0 bytes received
```

HTTP server
```
❯ go run server_http/main.go
2021/09/04 23:25:19 Received: /sleep
2021/09/04 23:25:19 sleep for 5 seconds...
2021/09/04 23:25:21 could not sleep: rpc error: code = Canceled desc = context canceled
2021/09/04 23:25:21 canceled by client
```

gRPC server
```
❯ go run server_grpc/main.go
2021/09/04 23:25:19 sleep for 5s...
2021/09/04 23:25:21 sleep canceled: context canceled
```

時間を軸に表にしてみます。

| at | cURL | HTTP server | gPRC server |
| -- | ---- | ----------- | ----------- |
|2021/09/04 23:25:19|`curl -v -m 2 http://127.0.0.1:18081/sleep`| Received: /sleep<br />sleep for 5 seconds...| sleep for 5s...|
|2021/09/04 23:25:21|curl: (28) Operation timed out after 2001 milliseconds with 0 bytes received| could not sleep: rpc error: code = Canceled desc = context canceled<br />canceled by client|sleep canceled: context canceled|

23:25:21にcurlがタイム・アウトすると、HTTP server、 gRPC serverともに`context canceled`がログに書き込まれています。
HTTPクライアントの切断により、gRPCサーバー側の処理も中断されました。

## ソースコード

では、HTTPコネクションが切れた際、gRPCサーバーがどのようにして中断されたのかをコードから追ってみます。

### HTTPサーバー側

まず、HTTPコネクションが切れたのは、HTTPサーバーの `(*connReader).backgroundRead()` 内で検知されます。

```go
func (cr *connReader) backgroundRead() {
	n, err := cr.conn.rwc.Read(cr.byteBuf[:])
	cr.lock()
	if n == 1 {
		cr.hasByte = true
		// ...略...
	}
	if ne, ok := err.(net.Error); ok && cr.aborted && ne.Timeout() {
		// Ignore this error. It's the expected error from
		// another goroutine calling abortPendingRead.
	} else if err != nil {
		// HTTPコネクションが切られるとここに来る。
		cr.handleReadError(err)
	}
	cr.aborted = false
	cr.inRead = false
	cr.unlock()
	cr.cond.Broadcast()
}
```
出典：<https://github.com/golang/go/blob/bc51e930274a5d5835ac8797978afc0864c9e30c/src/net/http/server.go#L703>

検知されると、`(*connReader).handleReadError()`メソッド内でコンテキストのキャンセルが呼ばれます。

```go
// handleReadError is called whenever a Read from the client returns a
// non-nil error.
//
// The provided non-nil err is almost always io.EOF or a "use of
// closed network connection". In any case, the error is not
// particularly interesting, except perhaps for debugging during
// development. Any error means the connection is dead and we should
// down its context.
//
// It may be called from multiple goroutines.
func (cr *connReader) handleReadError(_ error) {
	cr.conn.cancelCtx()
	cr.closeNotify()
}
```
出典：<https://github.com/golang/go/blob/bc51e930274a5d5835ac8797978afc0864c9e30c/src/net/http/server.go#L739>

### gRPCクライント側

繰り返しになりますが、このサンプルではgRPCクライアントのAPIを呼び出す際、[HTTPリクエストから取れるコンテキスト](https://pkg.go.dev/net/http#Request.Context)をそのままgRPCクライアントへ渡しています。
これにより、gRPCクライアントでは上記コンテキストのキャンセルを検知することができます。
具体的には`(*Stream).waitOnHeader()`内の`<-s.ctx.Done()`でそのメッセージを受け取ります。
メッセージを受け取ると、`ContextErr()`関数でエラーを作り、`(*http2Client).CloseStream()`メソッドでサーバーへのストリームを閉じます。
```go
func (s *Stream) waitOnHeader() {
	if s.headerChan == nil {
		// On the server headerChan is always nil since a stream originates
		// only after having received headers.
		return
	}
	select {
	case <-s.ctx.Done():
		// Close the stream to prevent headers/trailers from changing after
		// this function returns.
		s.ct.CloseStream(s, ContextErr(s.ctx.Err()))
		// headerChan could possibly not be closed yet if closeStream raced
		// with operateHeaders; wait until it is closed explicitly here.
		<-s.headerChan
	case <-s.headerChan:
	}
}
```
出典：<https://github.com/grpc/grpc-go/blob/41e044e1c82fcf6a5801d6cbd7ecf952505eecb1/internal/transport/transport.go#L326>


`ContextErr()`メソッドでは、コンテキストのエラー情報をもとにgRPCのエラーを作っています。
キャンセルされた場合(`context.Canceled`)は、`codes.Canceled`というエラーコードで作られるようです。
```go
// ContextErr converts the error from context package into a status error.
func ContextErr(err error) error {
	switch err {
	case context.DeadlineExceeded:
		return status.Error(codes.DeadlineExceeded, err.Error())
	case context.Canceled:
		return status.Error(codes.Canceled, err.Error())
	}
	return status.Errorf(codes.Internal, "Unexpected error from context packet: %v", err)
}
```
出典：<https://github.com/grpc/grpc-go/blob/41e044e1c82fcf6a5801d6cbd7ecf952505eecb1/internal/transport/transport.go#L796>


サーバーへのストリームをクローズする、`(*http2Client).CloseStream()`メソッドでは、リセットを意味する`rst`変数に`true`を指定し、さらに別メソッドを呼び出します。
```go
// CloseStream clears the footprint of a stream when the stream is not needed any more.
// This must not be executed in reader's goroutine.
func (t *http2Client) CloseStream(s *Stream, err error) {
	var (
		rst     bool
		rstCode http2.ErrCode
	)
	if err != nil {
		rst = true
		rstCode = http2.ErrCodeCancel
	}
	t.closeStream(s, err, rst, rstCode, status.Convert(err), nil, false)
}
```
出典：<https://github.com/grpc/grpc-go/blob/41e044e1c82fcf6a5801d6cbd7ecf952505eecb1/internal/transport/http2_client.go#L794>

最終的には、`(*loopyWrite).cleanupStreamHandler()`メソッドにたどり着き、HTTP/2の`RST_STREAM`を書き込んでいます。
(ここは完全にはコードを追いきれておらず推測が含まれます)

```go
func (l *loopyWriter) cleanupStreamHandler(c *cleanupStream) error {
 	// ...略...
	if c.rst { // If RST_STREAM needs to be sent.
		if err := l.framer.fr.WriteRSTStream(c.streamID, c.rstCode); err != nil {
			return err
		}
	}
	// ...略...
}
```
出典：<https://github.com/grpc/grpc-go/blob/41e044e1c82fcf6a5801d6cbd7ecf952505eecb1/internal/transport/controlbuf.go#L759-L762>

HTTP/2の通信ログも一緒に出して確認してみると、`sleep for 5 seconds...`の2秒後に、
`wrote RST_STREAM stream=1 len=4 ErrCode=CANCEL`
とあり、`RST_STREAM`が書き込まれていることがわかります。

```text
❯ GODEBUG=http2debug=2 go run server_http/main.go
2021/09/20 10:26:49 Received: /sleep
2021/09/20 10:26:49 sleep for 5 seconds...
# ...略...
2021/09/20 10:26:51 http2: Framer 0xc00011e000: wrote RST_STREAM stream=1 len=4 ErrCode=CANCEL
2021/09/20 10:26:51 could not sleep: rpc error: code = Canceled desc = context canceled
2021/09/20 10:26:51 canceled by client
```

:::details コンソール出力の完全版はこちら。
```text
❯ GODEBUG=http2debug=2 go run server_http/main.go
2021/09/20 10:26:49 Received: /sleep
2021/09/20 10:26:49 sleep for 5 seconds...
2021/09/20 10:26:49 http2: Framer 0xc00011e000: wrote SETTINGS len=0
2021/09/20 10:26:49 http2: Framer 0xc00011e000: read SETTINGS len=6, settings: MAX_FRAME_SIZE=16384
2021/09/20 10:26:49 http2: Framer 0xc00011e000: wrote SETTINGS flags=ACK len=0
2021/09/20 10:26:49 http2: Framer 0xc00011e000: read SETTINGS flags=ACK len=0
2021/09/20 10:26:49 http2: Framer 0xc00011e000: wrote HEADERS flags=END_HEADERS stream=1 len=71
2021/09/20 10:26:49 http2: Framer 0xc00011e000: wrote DATA flags=END_STREAM stream=1 len=9 data="\x00\x00\x00\x00\x04\b\x05\x10\x01"
2021/09/20 10:26:49 http2: Framer 0xc00011e000: read WINDOW_UPDATE len=4 (conn) incr=9
2021/09/20 10:26:49 http2: Framer 0xc00011e000: read PING len=8 ping="\x02\x04\x10\x10\t\x0e\a\a"
2021/09/20 10:26:49 http2: Framer 0xc00011e000: wrote PING flags=ACK len=8 ping="\x02\x04\x10\x10\t\x0e\a\a"
2021/09/20 10:26:51 http2: Framer 0xc00011e000: wrote RST_STREAM stream=1 len=4 ErrCode=CANCEL
2021/09/20 10:26:51 could not sleep: rpc error: code = Canceled desc = context canceled
2021/09/20 10:26:51 canceled by client
```
:::

### gRPCサーバー側

gRPCのサーバー側では、まず`(*http2Server) operateHeaders()`メソッドで、サーバー側のコンテキストをキャンセルするための`cancel`関数オブジェクトが作られます。
`grpc-timeout`ヘッダーの有無で、`context.WithTimeout()`か`context.WithCancel()`を切り替えているようです。
作られた関数オブジェクトは、`transport.Stream`構造体にセットされます。

```go
// operateHeader takes action on the decoded headers.
func (t *http2Server) operateHeaders(frame *http2.MetaHeadersFrame, handle func(*Stream), traceCtx func(context.Context, string) context.Context) (fatal bool) {
...
	for _, hf := range frame.Fields {
		switch hf.Name {
		...
		case "grpc-timeout":
			timeoutSet = true
			var err error
			if timeout, err = decodeTimeout(hf.Value); err != nil {
				headerError = true
			}
			...
	}

	...
	if timeoutSet {
		s.ctx, s.cancel = context.WithTimeout(t.ctx, timeout)
	} else {
		s.ctx, s.cancel = context.WithCancel(t.ctx)
	}
```
出典：<https://github.com/grpc/grpc-go/blob/41e044e1c82fcf6a5801d6cbd7ecf952505eecb1/internal/transport/http2_server.go#L407>

セットされる`Stream`構造体のフィールドはこちらです。

```go
// Stream represents an RPC in the transport layer.
type Stream struct {
	...
	cancel       context.CancelFunc // always nil for client side Stream
	...
```
出典：<https://github.com/grpc/grpc-go/blob/41e044e1c82fcf6a5801d6cbd7ecf952505eecb1/internal/transport/transport.go#L242>

前述の繰り返しになりましが、キャンセルするとgRPCクライアントは`RST_STREAM`フレームを、gRPCサーバーへ送ります。

gRPCサーバー側のログにHTTP/2の通信ログも出してみると、10:26:51に`RST_STREAM`を読み込んでいるのがわかります。
```text
❯ GODEBUG=http2debug=2 go run server_grpc/main.go
# ...略...
2021/09/20 10:26:49 sleep for 5s...
2021/09/20 10:26:51 http2: Framer 0xc0001fe000: read RST_STREAM stream=1 len=4 ErrCode=CANCEL
2021/09/20 10:26:51 could not sleep: context canceled
```

:::details コンソール出力の完全版はこちら。
```text
❯ GODEBUG=http2debug=2 go run server_grpc/main.go
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: wrote SETTINGS len=6, settings: MAX_FRAME_SIZE=16384
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: read SETTINGS len=0
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: wrote SETTINGS flags=ACK len=0
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: read SETTINGS flags=ACK len=0
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: read HEADERS flags=END_HEADERS stream=1 len=71
2021/09/20 10:26:49 http2: decoded hpack field header field ":method" = "POST"
2021/09/20 10:26:49 http2: decoded hpack field header field ":scheme" = "http"
2021/09/20 10:26:49 http2: decoded hpack field header field ":path" = "/helloworld.Greeter/Sleep"
2021/09/20 10:26:49 http2: decoded hpack field header field ":authority" = "localhost:18080"
2021/09/20 10:26:49 http2: decoded hpack field header field "content-type" = "application/grpc"
2021/09/20 10:26:49 http2: decoded hpack field header field "user-agent" = "grpc-go/1.40.0"
2021/09/20 10:26:49 http2: decoded hpack field header field "te" = "trailers"
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: read DATA flags=END_STREAM stream=1 len=9 data="\x00\x00\x00\x00\x04\b\x05\x10\x01"
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: wrote WINDOW_UPDATE len=4 (conn) incr=9
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: wrote PING len=8 ping="\x02\x04\x10\x10\t\x0e\a\a"
2021/09/20 10:26:49 http2: Framer 0xc0001fe000: read PING flags=ACK len=8 ping="\x02\x04\x10\x10\t\x0e\a\a"
2021/09/20 10:26:49 sleep for 5s...
2021/09/20 10:26:51 http2: Framer 0xc0001fe000: read RST_STREAM stream=1 len=4 ErrCode=CANCEL
2021/09/20 10:26:51 could not sleep: context canceled
```
:::


送られてくるフレームは、`(*http2Server).HandleStreams()`メソッド内で、その種類に応じて処理されます。
`RST_STREAM`フレームの場合は、`(*http2Server).handleRSTStream()`メソッドが呼び出されます。

```go
// HandleStreams receives incoming streams using the given handler. This is
// typically run in a separate goroutine.
// traceCtx attaches trace to ctx and returns the new context.
func (t *http2Server) HandleStreams(handle func(*Stream), traceCtx func(context.Context, string) context.Context) {
		...
		switch frame := frame.(type) {
		...
		case *http2.RSTStreamFrame:
			t.handleRSTStream(frame)
```
出典：<https://github.com/grpc/grpc-go/blob/41e044e1c82fcf6a5801d6cbd7ecf952505eecb1/internal/transport/http2_server.go#L581-L582>

その後は、
`(*http2Server).handleRSTStream()`
↓
`(*http2Server).closeStream()`
↓
`(*http2Server).deleteStream()`
の順に呼ばれていきます。
最後に、`deleteStream()`内で、上記で`Stream`構造体にセットしていた`cancel()`関数が呼ばれ、サーバー側のコンテキストがキャンセルされます。

```go
// deleteStream deletes the stream s from transport's active streams.
func (t *http2Server) deleteStream(s *Stream, eosReceived bool) {
	// In case stream sending and receiving are invoked in separate
	// goroutines (e.g., bi-directional streaming), cancel needs to be
	// called to interrupt the potential blocking on other goroutines.
	s.cancel()

	...
```
出典：<https://github.com/grpc/grpc-go/blob/41e044e1c82fcf6a5801d6cbd7ecf952505eecb1/internal/transport/http2_server.go#L1167>

## まとめ

今回の調査により、HTTPクライアントが切断されてしまっても、以下の2つを行っておくことで裏のgRPC通信をキャンセルできることがわかりました。
- HTTPリクエストのコンテキストをgRPCクライアントへ渡しておく。
- gRPCサーバーの実装では、コンテキストがキャンセルされたときの処理を書いておく。

## 参考

- [gRPC and Deadlines | gRPC](https://grpc.io/blog/deadlines/)
- [http package - net/http - pkg.go.dev](https://pkg.go.dev/net/http@go1.17.1#Request.Context) (Request.Context)
- [rfc7540](https://datatracker.ietf.org/doc/html/rfc7540#page-36) (RST_STREAM)
