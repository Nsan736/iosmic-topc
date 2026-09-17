# iosmic-topc

iPad のマイク音声とカメラ映像を同一 LAN 上の Windows PC へリアルタイム送信し、PC 側で仮想マイク・仮想カメラとして使えるようにする一式。

- `ios/` — 送信側 iOS アプリ (SwiftUI / AVAudioEngine / Network.framework)
- `windows/receiver.py` — 音声の受信側
- `windows/video_receiver.py` — 映像の受信側
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

### 映像

カメラ映像は 1 フレームずつ JPEG に圧縮し、TCP (既定 50006) で送る。1 フレームが数十 KB あり UDP の 1 パケットに収まらないため、映像だけ TCP にしている。

遅延を溜めないために、iPad 側は前のフレームの送信が終わるまで次のフレームをエンコードせずに捨てる。回線が細くなるとフレームレートが下がるだけで、映像が過去に取り残されることはない。受信側が落ちている間は 1 秒ごとに再接続を試みる。

フレーム構造 (リトルエンディアン、ヘッダ 20 バイト):

| オフセット | サイズ | 内容 |
|---|---|---|
| 0 | 4 | マジック `IVID` |
| 4 | 1 | バージョン (1) |
| 5 | 1 | フラグ (bit0: 内カメラ) |
| 6 | 2 | 幅 |
| 8 | 2 | 高さ |
| 10 | 2 | 予約 (0) |
| 12 | 4 | JPEG のバイト数 |
| 16 | 4 | フレーム番号 |
| 20 | 可変 | JPEG 本体 |

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

### 5. 映像の受信

```bash
python windows/video_receiver.py
```

プレビューウィンドウに iPad の映像が出る。`q` か `Esc` で終了。

Web カメラとして使うには [OBS Studio](https://obsproject.com/) を入れ、一度 OBS で「仮想カメラ開始」を押して仮想カメラを登録しておく (登録後は OBS を閉じてよい)。そのうえで次のように起動する。

```bash
python windows/video_receiver.py --virtualcam
```

Zoom や Discord のカメラ選択で `OBS Virtual Camera` を選ぶ。iPad を縦にすると縦長の映像が届くが、仮想カメラには黒帯を付けて 1280x720 に収めて出す。

TCP 50006 もファイアウォールで許可しておく。

```bash
netsh advfirewall firewall add rule name="MicSender TCP 50006" dir=in action=allow protocol=TCP localport=50006
```

| オプション | 既定値 | 説明 |
|---|---|---|
| `--port` | 50006 | 待ち受けポート (TCP) |
| `--virtualcam` | 無効 | OBS Virtual Camera に出力する |
| `--no-preview` | 無効 | プレビューウィンドウを出さない |
| `--width` `--height` | 1280 x 720 | 仮想カメラの解像度 |
| `--fps` | 30 | 仮想カメラのフレームレート |

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

音声と映像はそれぞれ「音声を送る」「映像を送る」で個別にオンオフできる。映像を送るときは PC 側で `video_receiver.py` も起動しておく。

音量が足りなければ「音声」セクションのゲインスライダーを上げる。送信中でも即座に反映されるので、PC の音を聞きながら合わせられる。レベルメーターが赤く振り切る手前がちょうどよい。

「マイク処理を使う」は iOS の自動音量調整とノイズ抑制の切り替え。既定は有効で、こちらのほうが実用的な音量になる。切ると加工のない生の音になるかわりにかなり小さくなるので、楽器の録音など素の波形が欲しいときだけ切る。切り替えは次に送信を開始したときに効く。

バックグラウンドモードに `audio` を宣言しているので、ホーム画面に戻っても送信は続く。ただし LiveContainer 経由の場合はホストアプリの扱い次第で切られることがあるため、確実に送り続けたいときはアプリを前面に置いておく。

### カメラ

- 「内カメラ」「外カメラ」は送信中でも切り替えられる
- 解像度は 480p / 720p / 1080p、画質は JPEG の圧縮率。どちらも送信中に変えてよい
- iPad の向きに合わせて映像も回転する。縦持ちなら縦長で届く
- 内カメラは既定で反転せずに送る。Zoom などは自分側のプレビューを勝手に鏡像にするため、相手からは正しい向きに見える。鏡像のまま送りたいときだけ「内カメラを左右反転して送る」を有効にする
- アプリを背面に回すと iOS の制限でカメラは止まり、前面に戻ると再開する。音声はバックグラウンドでも続く。Split View や Stage Manager で他のアプリと並べている間は止まらない

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
| 映像が「PC の受信待ち」のまま | `video_receiver.py` が起動しているか、TCP 50006 がファイアウォールで許可されているかを確認 |
| 映像がカクつく | 解像度を 720p や 480p に下げるか、画質を下げる。アプリの fps 表示が 30 近く出ていれば送信側は間に合っている |
| `--virtualcam` でエラーになる | OBS Studio を入れて一度「仮想カメラ開始」を押す |
| カメラの許可ダイアログが出ない | LiveContainer ではホストアプリ側の権限として扱われる。iPad の設定アプリで LiveContainer のカメラを許可する |
| アプリ起動直後に落ちる | LiveContainer のログを確認。マイク権限の説明文が Info.plist にあるかを確認 |

## 帯域

音声は 48 kHz / モノラル / 16 bit で 768 kbps、ヘッダ込みで約 845 kbps。

映像は JPEG を毎フレーム送るので重く、実際のカメラ映像だと 720p / 画質 60% / 30 fps で 10 から 20 Mbps 程度、1080p ではその 2 倍強になる。Wi-Fi 5 (11ac) 以上ならまず足りるが、2.4 GHz 帯ではカクつきやすい。モバイル回線を経由させたい場合は Opus と H.264 への置き換えが必要になる。

## 開発について

このリポジトリは Anthropic の Claude Opus 5 を [Claude Code](https://claude.com/claude-code) 経由で使って作成した。iOS アプリ、受信スクリプト、GitHub Actions ワークフロー、この README のいずれも同じセッションで生成している。

受信側は 440 Hz のテストトーンを 10 ms 刻みで 200 パケット流すループバックテストで、ロスもアンダーランもなく再生されることを確認済み。映像の受信側も、合成した JPEG を 30 fps で横向き・縦向き合わせて 180 フレーム流し、全フレームの受信、再接続時の古い接続の破棄、不正ヘッダでの切断、OBS Virtual Camera への出力を確認済み。iOS 側の実機動作は各自の環境で確認すること。
