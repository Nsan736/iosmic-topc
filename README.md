# iosmic-topc

iPad のマイク音声を同一 LAN 上の Windows PC へ UDP でリアルタイム送信し、PC 側で仮想マイクとして使えるようにする一式。

- `ios/` — 送信側 iOS アプリ (SwiftUI / AVAudioEngine / Network.framework)
- `windows/` — 受信側 Python スクリプト
- `.github/workflows/build-ipa.yml` — 署名なし IPA を GitHub Actions でビルド

## 仕組み

iPad のマイク入力を 48 kHz / モノラル / 16 bit リニア PCM に変換し、10 ms (480 サンプル = 960 バイト) ごとに UDP で送信する。PC 側はジッタバッファを挟んで指定した出力デバイスへ流す。出力先を VB-CABLE の入力にすれば、Discord や Zoom からは普通のマイクとして見える。

パケット構造 (リトルエンディアン、ヘッダ 16 バイト):

| オフセット | サイズ | 内容 |
|---|---|---|
| 0 | 4 | マジック `IMIC` |
| 4 | 1 | バージョン (1) |
| 5 | 1 | チャンネル数 |
| 6 | 2 | 1 パケットのサンプル数 |
| 8 | 4 | サンプルレート |
| 12 | 4 | シーケンス番号 |
| 16 | 960 | Int16 PCM |

シーケンス番号はパケットロス検出にだけ使う。再送はしない。

## PC 側の準備

### 1. 仮想オーディオデバイスを入れる

[VB-CABLE](https://vb-audio.com/Cable/) をインストールする。インストール後、Windows のサウンド設定に `CABLE Input` (再生) と `CABLE Output` (録音) が増える。

構成はこうなる。

```
iPad マイク --UDP--> receiver.py --> CABLE Input --> CABLE Output --> Discord / Zoom / OBS
```

自分の耳でも聞きたい場合は VoiceMeeter を使うか、サウンド設定の `CABLE Output` のプロパティで「このデバイスを聴く」を有効にする。

### 2. 依存ライブラリ

```bash
pip install -r windows/requirements.txt
```

### 3. 出力デバイスを確認

```bash
python windows/receiver.py --list-devices
```

### 4. 受信開始

```bash
python windows/receiver.py --device "CABLE Input"
```

デバイスを指定しなければ既定の再生デバイス (スピーカー) から鳴る。まずはこれで疎通確認するとよい。

初回は Windows ファイアウォールの許可ダイアログが出るので、プライベートネットワークを許可する。出ない場合は管理者 PowerShell で以下を実行する。

```bash
netsh advfirewall firewall add rule name="MicSender UDP 50005" dir=in action=allow protocol=UDP localport=50005
```

主なオプション。

| オプション | 既定値 | 説明 |
|---|---|---|
| `--port` | 50005 | 待ち受けポート |
| `--device` | 既定の再生デバイス | 出力デバイス名の一部かインデックス |
| `--jitter` | 4 | 再生開始までに貯めるパケット数。1 = 10 ms |
| `--frames` | 480 | 1 パケットのサンプル数。送信側と必ず揃える |
| `--gain` | 1.0 | 再生前に掛ける倍率。2.0 で約 +6 dB |

音が途切れる (`underrun` が増える) 場合は `--jitter` を 8 や 12 に上げる。遅延と引き換えに安定する。

## iOS 側

### GitHub Actions でビルド

このリポジトリを GitHub に push すると `build-ipa.yml` が走り、署名なしの `MicSender.ipa` が Artifacts に上がる。`v1.0` のようなタグを push した場合は Release にも添付される。

手動で走らせる場合は Actions タブから `Build unsigned IPA` を `Run workflow`。

ビルドは macOS ランナー上で XcodeGen が `ios/project.yml` から `.xcodeproj` を生成し、`CODE_SIGNING_ALLOWED=NO` でビルドして `Payload/` に詰めて zip するだけ。`.xcodeproj` はリポジトリに置かない。

### 端末へ入れる

AltStore に IPA を渡せば AltStore 側が署名してインストールする (iPad 9 / iPadOS 26)。LiveContainer で動かす場合も同じ IPA をそのまま読み込ませる。

StikDebug は JIT が要る場合にだけ使う。このアプリは JIT を必要としないので通常は不要。

### 使い方

1. PC 側で `receiver.py` を起動しておく
2. アプリを開き、PC の IPv4 アドレス (`ipconfig` で確認) とポート 50005 を入力
3. 「送信開始」をタップ。初回はマイクの許可を求められる
4. 状態が「送信中」になり、レベルメーターが振れれば送れている

音量が足りなければ「入力」セクションのゲインスライダーを上げる。送信中でも即座に反映されるので、PC の音を聞きながら合わせられる。レベルメーターが赤く振り切る手前がちょうどよい。

「マイク処理を使う」は iOS の自動音量調整とノイズ抑制の切り替え。既定は有効で、こちらのほうが実用的な音量になる。切ると加工のない生の音になるかわりにかなり小さくなるので、楽器の録音など素の波形が欲しいときだけ切る。切り替えは次に送信を開始したときに効く。

バックグラウンドモードに `audio` を宣言しているので、ホーム画面に戻っても送信は続く。ただし LiveContainer 経由の場合はホストアプリの扱い次第で切られることがあるため、確実に送り続けたいときはアプリを前面に置いておく。

## バンドル ID を変える

`ios/project.yml` の `PRODUCT_BUNDLE_IDENTIFIER` を書き換える。

LiveContainer で動かす場合はホストアプリの中で動くため、AltStore の無料デベロッパーアカウントにある「同時 3 アプリまで」の制限を消費しない。ID もそのままで問題ない。AltStore で直接サイドロードする場合だけ、既存アプリと衝突しない ID にしておく。

## トラブルシュート

| 症状 | 対処 |
|---|---|
| アプリは「送信中」だが PC に何も届かない | ファイアウォールの UDP 受信許可、IP アドレス、iPad と PC が同じサブネットにいるかを確認 |
| 音が途切れる | `--jitter` を上げる。Wi-Fi 5 GHz 帯を使う |
| 音が小さい | アプリのゲインを上げる。「マイク処理を使う」が有効かを確認する。PC 側だけで上げるなら `--gain 2.0` |
| 音が割れる | ゲインを下げる。送信側でクリップすると PC 側では直せない |
| 音がおかしい / ノイズだらけ | 送信側と `--frames` `--samplerate` `--channels` が揃っているか確認 |
| `lost` が増え続ける | 電波状況の問題。ルーターとの距離、2.4 GHz の混雑を疑う |
| アプリ起動直後に落ちる | LiveContainer のログを確認。マイク権限の説明文が Info.plist にあるかを確認 |

## 帯域

48 kHz / モノラル / 16 bit で 768 kbps、ヘッダ込みで約 845 kbps。LAN なら問題にならないが、モバイル回線を経由させたい場合は Opus 圧縮の追加が必要になる。

## 開発について

このリポジトリは Anthropic の Claude Opus 5 を [Claude Code](https://claude.com/claude-code) 経由で使って作成した。iOS アプリ、受信スクリプト、GitHub Actions ワークフロー、この README のいずれも同じセッションで生成している。

受信側は 440 Hz のテストトーンを 10 ms 刻みで 200 パケット流すループバックテストで、ロスもアンダーランもなく再生されることを確認済み。iOS 側の実機動作は各自の環境で確認すること。
