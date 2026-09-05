#!/bin/bash
# Claude Code の通知フック。
#   使い方: notify.sh stop | notify.sh notification
#   フック入力の JSON を stdin で受け取る。
#
# ─── 設定（ここだけ書き換えれば挙動が変わる）─────────────────
VOICE_ENABLED=1                 # 1=読み上げる / 0=読み上げない
BANNER_ENABLED=0                # 1=通知センターに出す / 0=出さない
                                # 既定は 0（音と読み上げで足りるため）。
                                # 1 にする場合は、設定 → 通知 → ターミナル の
                                # 許可も必要になる。
SOUND_ENABLED=1                 # 1=効果音を鳴らす / 0=鳴らさない
BELL_ENABLED=1                  # 1=端末ベルを鳴らす / 0=鳴らさない
                                # Terminal の「視覚ベル」ONでウィンドウが光る。
                                # Claude Code は preferredNotifChannel でも鳴らせるが、
                                # Codex CLI には相当設定が無いのでここで鳴らす。
TERMINAL_ONLY=1                 # 1=ターミナルで動かしているときだけ通知する
                                # 0=どこで動いていても通知する
                                # フックの登録先（settings.json / hooks.json）は
                                # ターミナル版とデスクトップアプリ版で共有されるため、
                                # 既定ではアプリ内で動いているときは黙る。
                                # アプリには独自の通知があるので二重に鳴らさない。

VOICE_NAME="Samantha"           # `say -v '?'` で一覧が見られる
VOICE_RATE=200                  # 読み上げ速度（既定は 180 前後）

# 効果音。Claude.app の音を ~/.claude/hooks/sounds/ に複製して使う。
# macOS 標準音に戻すなら /System/Library/Sounds/Glass.aiff などを指定。
SND_DIR="$HOME/.claude/hooks/sounds"
SOUND_STOP="$SND_DIR/exit_voice_mode.mp3"      # 完了：下降する締めの音
SOUND_NOTIFY="$SND_DIR/enter_voice_mode.mp3"   # 承認待ち：上昇する呼びかけ音
# 上のファイルが無い環境（Claude.app 未導入の Mac）で使う macOS 標準音
SOUND_STOP_ALT="/System/Library/Sounds/Glass.aiff"
SOUND_NOTIFY_ALT="/System/Library/Sounds/Submarine.aiff"

SPEECH_STOP="Done"
SPEECH_PERMISSION="Permission needed"
SPEECH_WAITING="Waiting for your input"
SPEECH_OTHER="Claude needs you"  # message はあるが分類できなかった場合のみ
# ────────────────────────────────────────────────

# 親プロセスを辿り、ターミナルの中で動いているかを判定する。
# デスクトップアプリ（Claude.app / ChatGPT.app）が直接起動した CLI は
# 制御端末を持たない（tty が ?? になる）。さらに念のため、
# 途中でアプリ本体に行き着いた場合も「ターミナルではない」と判定する。
# 引数で開始 PID を渡せる（テスト用。既定は自分の親）。
in_terminal() {
  local pid="${1:-$PPID}" tty_found=0 t cmd n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ $n -lt 12 ]; do
    cmd="$(ps -o args= -p "$pid" 2>/dev/null)"
    case "$cmd" in
      */Claude.app/*|*/ChatGPT.app/*|*/Cursor.app/*|*/Visual\ Studio\ Code.app/*)
        return 1 ;;
    esac
    t="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$t" ] && [ "$t" != "??" ] && tty_found=1
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    n=$((n + 1))
  done
  [ "$tty_found" = "1" ]
}

[ "$TERMINAL_ONLY" = "1" ] && ! in_terminal && exit 0

EVENT="${1:-stop}"
PAYLOAD="$(cat)"

# フック入力から値を1つ取り出す。引数はキー名（先頭のドットは不要）。
# jq は macOS 15 以降にしか同梱されないので、無ければ sed で代用する
# （扱うのは .cwd / .message / .model の平坦な文字列だけなので sed で足りる）。
if command -v jq >/dev/null 2>&1; then
  field() { printf '%s' "$PAYLOAD" | jq -r ".$1 // empty" 2>/dev/null; }
else
  field() {
    printf '%s' "$PAYLOAD" \
      | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1
  }
fi

CWD="$(field cwd)"
PROJECT="$(basename "${CWD:-$PWD}")"
RAW_MESSAGE="$(field message)"

# Codex のフック入力には Codex 固有フィールドの model が含まれる。
# Claude Code とスクリプトを共用しつつ、通知元だけ正しく表示する。
APP_NAME="Claude Code"
[ -n "$(field model)" ] && APP_NAME="Codex"

case "$EVENT" in
  notification)
    SOUND="$SOUND_NOTIFY"; SOUND_ALT="$SOUND_NOTIFY_ALT"
    BODY="${RAW_MESSAGE:-確認が必要です}"
    case "$RAW_MESSAGE" in
      # Codex のフック入力には message が無い（渡されるのは session_id / model /
      # tool_name など）。PermissionRequest で呼ばれた時点で承認待ちと確定するので、
      # 空のときは permission として扱う。ここが無いと Codex が
      # "Claude needs you" と他社名を読み上げてしまう（2026-09-01 修正）。
      ""|*permission*|*Permission*) SPEECH="$SPEECH_PERMISSION" ;;
      *waiting*|*idle*)            SPEECH="$SPEECH_WAITING" ;;
      *)                           SPEECH="$SPEECH_OTHER" ;;
    esac
    TITLE="$APP_NAME 🔔 $PROJECT"
    ;;
  *)
    SOUND="$SOUND_STOP"; SOUND_ALT="$SOUND_STOP_ALT"
    BODY="処理が完了しました"
    SPEECH="$SPEECH_STOP"
    TITLE="$APP_NAME ✅ $PROJECT"
    ;;
esac

# 通知センターのバナー（AppleScript の文字列リテラル用にエスケープ）
if [ "$BANNER_ENABLED" = "1" ]; then
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  osascript -e "display notification \"$(esc "$BODY")\" with title \"$(esc "$TITLE")\"" >/dev/null 2>&1
fi

# 端末ベル。自分の tty を親プロセスから辿って直接送る
if [ "$BELL_ENABLED" = "1" ]; then
  find_tty() {
    local pid="$PPID" t n=0
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ $n -lt 6 ]; do
      t="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
      if [ -n "$t" ] && [ "$t" != "??" ]; then printf '/dev/%s' "$t"; return 0; fi
      pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
      n=$((n + 1))
    done
    return 1
  }
  MYTTY="$(find_tty)" && [ -w "$MYTTY" ] && printf '\a' > "$MYTTY" 2>/dev/null
fi

# 効果音。ファイルが無ければ macOS の警告音でフォールバック
if [ "$SOUND_ENABLED" = "1" ]; then
  if [ -f "$SOUND" ]; then
    afplay "$SOUND" >/dev/null 2>&1
  elif [ -f "$SOUND_ALT" ]; then
    afplay "$SOUND_ALT" >/dev/null 2>&1
  else
    osascript -e 'beep' >/dev/null 2>&1
  fi
fi

[ "$VOICE_ENABLED" = "1" ] && say -v "$VOICE_NAME" -r "$VOICE_RATE" "$SPEECH" >/dev/null 2>&1

exit 0
