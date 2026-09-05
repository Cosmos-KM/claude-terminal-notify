# Claude Code / Codex CLI ターミナル表示セット

ターミナルで作業していて「いま承認待ちなのか、終わったのか」が
画面を見なくても分かるようにする仕組みです。

**macOS 専用です。** タブの色付けに AppleScript で Terminal.app を操作し、
効果音と読み上げに macOS の `afplay` / `say` を使うため、
Windows・Linux では動きません（インストーラが起動時に弾きます）。

![デモ](https://raw.githubusercontent.com/Cosmos-KM/claude-terminal-notify/main/demo.gif)

## 何が起きるか

**タブの背景色**（Terminal.app）

| 状態 | 見た目 |
| --- | --- |
| 作業中 | ごく薄い青紫 |
| 完了 | 薄い緑。そのタブを前面にすると自動で消える |
| 承認待ち・**他のタブを見ているとき** | 藤色で全面がゆっくり明滅する |
| 承認待ち・**そのタブを見ているとき** | ほぼ平常色。7秒に1回だけ、薄くふわりと明るくなる |

承認待ちの見せ方が2つあるのが要点です。離れているときは気づけるように派手に、
読んでいるときは文字が読めるように控えめに切り替わります。

**音と読み上げ**

| きっかけ | 効果音 | 読み上げ（英語） | 端末ベル |
| --- | --- | --- | --- |
| 作業完了 | 下降音 | "Done" | 鳴る |
| 承認待ち | 上昇音 | "Permission needed" | 鳴る |

Claude Code から呼ばれても Codex から呼ばれても同じです。

画面に出るポップアップ（通知センターのバナー）は**既定では出しません**。
音と読み上げで足りるためです。出したい場合は `notify.sh` の
`BANNER_ENABLED` を `1` にしてください（下記「好みに合わせる」を参照）。

## 入れ方

```bash
git clone https://github.com/Cosmos-KM/claude-terminal-notify.git
cd claude-terminal-notify
./install.sh
```

ZIP（`terminal-notify-forMac.zip`）を受け取った場合は、展開して
`cd terminal-notify` してから同じく `./install.sh` を実行します。

入っている CLI（Claude Code / Codex CLI）を検出して、両方に組み込みます。
片方だけなら `./install.sh --claude` または `./install.sh --codex`。

インストール後に次の2点を確認してください。

1. **自動化** — 設定 → プライバシーとセキュリティ → 自動化 → ターミナル → Terminal をオン
   （これが無いとタブの色が変わりません）
2. **通知** — 既定ではポップアップを出さないので、設定は不要です。
   `BANNER_ENABLED=1` にした場合だけ、設定 → 通知 → ターミナル をオンにしてください

すでに開いているセッションには効きません。開き直してください。
Codex は初回起動時にフックの信頼を確認してくるので、内容を見て許可します。

## 外し方

```bash
./install.sh --remove
```

設定ファイルから自分が足したエントリだけを消します。
他のフック（ガード等）には触りません。

## 現状を見る

```bash
./install.sh --check
```

どのイベントに何が登録されているかを一覧します。何も変更しません。

## 動作条件

| | |
| --- | --- |
| OS | macOS |
| ターミナル | **色付けは Terminal.app のみ。** iTerm2・Ghostty・VS Code 等では色は付かず、音と読み上げだけ動く |
| 必要なもの | `python3`（インストール時のみ。無ければ `xcode-select --install`） |
| `jq` | あれば使う。無ければ `sed` で代用するので入れなくてよい |

`tmux` の中では色付けは無効になります（tty がタブと対応しないため、黙って何もしません）。

## 中身

```
install.sh              入れる・外す・確認
lib/install_hooks.py    設定ファイルへの足し引き（install.sh から呼ばれる）
hooks/notify.sh         効果音・読み上げ・端末ベル（バナーは既定でオフ）
hooks/tabcolor.sh       タブ背景色
```

`hooks/` の2本が `~/.claude/hooks/` に置かれ、Claude Code と Codex の
両方から共用されます。設定の登録先はそれぞれ次のとおりです。

- Claude Code … `~/.claude/settings.json` の `hooks`
- Codex CLI … `~/.codex/hooks.json` の `hooks`

どちらも各CLIが自分で書き換えるファイルなので、インストーラは
**丸ごと上書きせず、自分が足したエントリだけ**を足し引きします。
実行前に `.notify.bak` を残します。何度実行しても結果は変わりません。

## 好みに合わせる

設定値はすべて2つのスクリプトの**冒頭**にまとまっています。
書き換えたらセッションを開き直すだけで反映されます。

```
~/.claude/hooks/notify.sh     音・読み上げ
~/.claude/hooks/tabcolor.sh   タブの色
```

### 色と時間の書き方

- **色は RGB を 0〜65535 の3つの数値**で書きます（`(30000 12000 58000)` = 藤色）。
  よくある 0〜255 表記の値は 257 倍してください（例：`200` → `51400`）
- **`〜_MIX` は「平常の背景色に何％混ぜるか」**です。`0` にするとその状態では
  色を変えません（＝その状態の色付けを止められます）
- 時間はすべて秒。小数も使えます（`0.45` など）

---

### `notify.sh` — 音・読み上げ

**オン・オフ**

| 設定 | 既定 | 意味 |
| --- | --- | --- |
| `VOICE_ENABLED` | `1` | 読み上げる／しない |
| `SOUND_ENABLED` | `1` | 効果音を鳴らす／鳴らさない |
| `BELL_ENABLED` | `1` | 端末ベルを鳴らす／鳴らさない。Terminal の「視覚ベル」をONにするとウィンドウが光る |
| `BANNER_ENABLED` | `0` | 通知センターのポップアップ。`1` にする場合は 設定 → 通知 → ターミナル の許可も必要 |
| `TERMINAL_ONLY` | `1` | ターミナルで動かしているときだけ通知する。`0` でデスクトップアプリ内でも鳴る |

**読み上げ**

| 設定 | 既定 | 意味 |
| --- | --- | --- |
| `VOICE_NAME` | `Samantha` | 声。`say -v '?'` で一覧が見られる。日本語なら `Kyoko` など |
| `VOICE_RATE` | `200` | 速さ。macOS の既定は 180 前後。大きいほど速い |
| `SPEECH_STOP` | `Done` | 作業完了のときの文言 |
| `SPEECH_PERMISSION` | `Permission needed` | 承認待ちのときの文言 |
| `SPEECH_WAITING` | `Waiting for your input` | 入力待ちのときの文言 |
| `SPEECH_OTHER` | `Claude needs you` | 上のどれにも分類できなかったときの文言 |

**効果音**

| 設定 | 既定 | 意味 |
| --- | --- | --- |
| `SND_DIR` | `~/.claude/hooks/sounds` | 効果音を置くフォルダ |
| `SOUND_STOP` | `exit_voice_mode.mp3` | 完了の音（下降する締めの音） |
| `SOUND_NOTIFY` | `enter_voice_mode.mp3` | 承認待ちの音（上昇する呼びかけ音） |
| `SOUND_STOP_ALT` | `Glass.aiff` | `SOUND_STOP` が無いときの代替 |
| `SOUND_NOTIFY_ALT` | `Submarine.aiff` | `SOUND_NOTIFY` が無いときの代替 |

`.mp3` `.aiff` `.wav` など `afplay` が再生できる形式なら何でも指定できます。
macOS 標準音は `/System/Library/Sounds/` にあります（Finder で ⌘+Shift+G）。

---

### `tabcolor.sh` — タブの色

**各状態の色**

| 設定 | 既定 | 意味 |
| --- | --- | --- |
| `WORKING_TINT` / `WORKING_MIX` | `(14000 10000 26000)` / `16` | 作業中の色と濃さ |
| `DONE_TINT` / `DONE_MIX` | `(0 34000 10000)` / `20` | 完了の色と濃さ |
| `ATTENTION_TINT` / `ATTENTION_MIX` | `(30000 12000 58000)` / `30` | 承認待ち・**他のタブを見ているとき**の色と濃さ（いちばん明るいとき） |

**承認待ち・他のタブを見ているとき**

平常色と藤色の間を、なめらかに行き来します（`fade`）。

| 設定 | 既定 | 意味 |
| --- | --- | --- |
| `BLINK_STYLE` | `fade` | `fade`＝なめらかに明滅 / `blink`＝0か100かで切り替える点滅 / `off`＝明滅させず点灯したまま |
| `BLINK_PERIOD` | `3.0` | `fade`：明滅1往復の秒数（暗→明→暗）。大きいほどゆっくり |
| `BLINK_STEPS` | `20` | `fade`：1往復の段階数。多いほど滑らかで、その分負荷が増える |
| `BLINK_INTERVAL` | `0.45` | `blink`：点滅の間隔（秒）。小さいほど速い。`0` は `off` と同じ扱い |

明るさは 0〜100 の数列として先に作り、それを順に流しています。`fade` と `blink` の
違いは数列の中身だけで、`fade` は cos で両端がゆっくりになるようにしてあります。

**承認待ち・そのタブを見ているとき**

読んでいる最中に激しく点滅すると文字が読めないため、控えめな別の見せ方をします。

| 設定 | 既定 | 意味 |
| --- | --- | --- |
| `ATTENTION_FG_MIX` | `6` | 光らせる色の濃さ。`0` にすると背景は平常色のまま変化しない |
| `ATTENTION_FG_PERIOD` | `7` | 何秒に1回光らせるか |
| `ATTENTION_FG_ON` | `1` | いちばん明るいところで何秒保つか |
| `ATTENTION_FG_FADE` | `0.8` | `fade`：明るくなる／暗くなるのにかける秒数（片道） |
| `ATTENTION_FG_STEP` | `0.15` | `fade`：内部の刻み（秒） |
| `ATTENTION_FG_TICK` | `0.5` | `blink`：内部の刻み（秒） |
| `ATTENTION_FG_CURSOR` | `1` | カーソルも背景と一緒に明滅させる／背景だけにする |
| `ATTENTION_CURSOR` | `(48000 36000 65535)` | 明滅させるカーソルの色（明るい側。暗い側は平常のカーソル色） |
| `ATTENTION_FG_TITLE` | `0` | タブのタイトルも点滅させる。**CLI 側が毎秒書き換えるので競合する**（既定でオフ） |
| `ATTENTION_TITLE_ON` | `🟣 承認待ち` | タイトル点滅の明るい側の文字列 |
| `ATTENTION_TITLE_OFF` | `⚪️ 承認待ち` | タイトル点滅の暗い側の文字列 |

**完了の緑の消し方**

| 設定 | 既定 | 意味 |
| --- | --- | --- |
| `FOCUS_CLEAR` | `1` | そのタブを前面にすると緑を消す。`0` にすると次の操作まで残る |
| `FOCUS_GRACE` | `3` | 緑を消すまでの最短表示秒数（見る前に消えるのを防ぐ） |
| `FOCUS_POLL` | `2` | 前面かどうかを見にいく間隔（秒） |
| `FOCUS_MAX_MIN` | `60` | 監視と点滅の最長時間（分）。過ぎたら諦めて色を残す |

---

### よくある調整例

**音を全部止めて、色だけにする**

```bash
VOICE_ENABLED=0
SOUND_ENABLED=0
BELL_ENABLED=0
```

**読み上げを日本語にする**

```bash
VOICE_NAME="Kyoko"
SPEECH_STOP="完了しました"
SPEECH_PERMISSION="承認をお願いします"
SPEECH_WAITING="入力を待っています"
```

**承認待ちを明滅させず、点灯したままにする**

```bash
BLINK_STYLE=off
```

**もっとゆっくり、もっと滑らかに明滅させる**

```bash
BLINK_PERIOD=5     # 1往復に5秒かける
BLINK_STEPS=34     # 段階を増やす（1秒あたりの色変更が増える＝負荷も増える）
```

**以前の、0か100かの点滅に戻す**

```bash
BLINK_STYLE=blink
BLINK_INTERVAL=0.45
```

**そのタブを見ているときも、はっきり気づけるようにする**

```bash
ATTENTION_FG_MIX=20      # 濃くする
ATTENTION_FG_PERIOD=5    # 5秒に1回に増やす
```

**逆に、見ているときは一切光らせない（カーソルだけで知らせる）**

```bash
ATTENTION_FG_MIX=0
```

**作業中は色を変えず、完了と承認待ちだけ知らせる**

```bash
WORKING_MIX=0
```

**完了の緑を、次に何か操作するまで残す**

```bash
FOCUS_CLEAR=0
```

## 効果音について

既定の効果音は、そのMacに Claude デスクトップアプリが入っていれば
インストール時にそこから複製します（配布物には同梱していません）。
入っていない場合は macOS 標準の `Submarine` / `Glass` を使います。
好きな音に差し替えるのが確実です。

## 仕組みのメモ

- 自分の tty を親プロセスから辿るので、ウィンドウやタブを何枚開いていても
  自分のタブだけが変わります
- 承認待ちの明滅は AppleScript が1本常駐します。色を変えた回数だけ Terminal が
  描き直すので、既定（1秒に約7回）では Terminal と合わせて1コアの数%です。
  気になるときは `BLINK_STEPS` を減らすか `BLINK_PERIOD` を伸ばしてください。
  承認するか60分経つと自分で終了します
- Terminal.app がタブ単位で変えられるのは背景色・カーソル色・文字色・タイトルだけです。
  枠線やタブバーだけを塗る手段はありません。文字色は TUI と衝突し、
  タイトルは CLI 側が毎秒書き換えるため、既定では背景色とカーソル色だけを使います
