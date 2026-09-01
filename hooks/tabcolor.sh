#!/bin/bash
# Claude Code / Codex CLI の状態を Terminal.app のタブの見た目で表示する。
#
#   tabcolor.sh init       セッション開始：元の背景色・カーソル色・タイトルを記録して無色へ
#   tabcolor.sh working    作業中：薄い暖色
#   tabcolor.sh done       完了：薄い緑。フォアグラウンドにすると無色へ戻る
#   tabcolor.sh attention  承認待ち：応答するまで知らせ続ける（下記）
#   tabcolor.sh resume     承認待ちだった場合だけ作業中へ戻す（PostToolUse 用・軽量）
#   tabcolor.sh restore    セッション終了：無色へ
#   tabcolor.sh reset      平常の色・タイトルを記録し直す（テーマ変更後に1回だけ）
#
# 承認待ちの見せ方は、そのタブが最前面かどうかで切り替わる。
#   バックグラウンド … 濃いオレンジで背景全面を速く点滅（離れていても気づけるように）
#   フォアグラウンド … 背景は平常色を基本とし、ATTENTION_FG_PERIOD 秒に1回だけ
#                      薄いオレンジを ATTENTION_FG_ON 秒あいだ点灯させる。
#                      読んでいる最中はほぼ平常色なので文字が読める。
#
# Terminal.app がタブ単位で変えられるのは背景色・カーソル色・文字色・タイトルだけで、
# 枠線・タブバー・プロンプト入力欄だけを塗るプロパティは存在しない。そのうち
#   ・文字色  … Claude Code の TUI は着色が多く実質全面になるので使わない
#   ・タイトル … Claude Code / Codex が作業中スピナーで毎秒書き換えるため奪い合う
#                （2026-08-31 に実測。既定でオフ。ATTENTION_FG_TITLE=1 で併用可）
#
# tty で自分のタブを特定するので、ウィンドウを複数開いていても自分のタブだけが変わる。
# Terminal.app 以外（iTerm2・tmux 等）では黙って何もしない。
#
# ─── 設定 ────────────────────────────────────────
# 元の背景色に混ぜる色と、その割合(%)。割合 0 でその状態は無色のまま。
WORKING_TINT=(26000 13000 0);   WORKING_MIX=16    # 作業中：薄い暖色
DONE_TINT=(0 34000 10000);      DONE_MIX=20       # 完了：薄い緑
ATTENTION_TINT=(52000 9000 0);  ATTENTION_MIX=60  # 承認待ち（背面）：濃いオレンジ

BLINK_INTERVAL=0.45        # 背面での点滅間隔（秒）。0 にすると点滅せず点灯のまま

# 承認待ち × フォアグラウンド のときの見せ方
ATTENTION_FG_MIX=4              # 点灯させる薄いオレンジの濃さ（0=平常色のまま）
ATTENTION_FG_PERIOD=10          # 点灯の周期（秒）。この間隔で1回だけ点く
ATTENTION_FG_ON=1               # 1回あたりの点灯時間（秒）
ATTENTION_FG_TICK=0.5           # 内部の刻み（秒）。カーソルの反転間隔も兼ねる
ATTENTION_FG_CURSOR=1           # 1=カーソルもオレンジで点滅させる / 0=背景の点灯だけ
ATTENTION_CURSOR=(65535 28000 0)  # 点滅させるカーソル色（明側）。暗側は平常のカーソル色
ATTENTION_FG_TITLE=0            # 1=タイトルも点滅させる（CLI 側の書き換えと競合する）
ATTENTION_TITLE_ON="🟠 承認待ち"
ATTENTION_TITLE_OFF="⚪️ 承認待ち"

FOCUS_CLEAR=1              # 1=完了の緑をフォアグラウンドで消す / 0=次の操作まで残す
FOCUS_GRACE=3              # 緑を消すまでの最短表示秒数（見る前に消えるのを防ぐ）
FOCUS_POLL=2               # フォアグラウンド監視の間隔（秒）
FOCUS_MAX_MIN=60           # 監視・点滅の最長時間（分）。過ぎたら諦めて色を残す
# ────────────────────────────────────────────────

SELF="$HOME/.claude/hooks/tabcolor.sh"
STATE_DIR="${TMPDIR:-/tmp}/claude-tabcolor"

terminal_running() {
  ps -Ao comm= 2>/dev/null | grep -q '/Terminal\.app/Contents/MacOS/Terminal$'
}
terminal_running || exit 0

# AppleScript の文字列リテラル用エスケープ
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# 自分の tty を親プロセスを辿って探す
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

# 背景色を設定。$1$2$3=RGB、$4=tty
set_bg() {
  osascript >/dev/null 2>&1 <<AS
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$4" then
        set background color of t to {$1, $2, $3}
        return
      end if
    end repeat
  end repeat
end tell
AS
}

# 最前面のタブの tty を返す（Terminal が最前面でなければ空）
front_tty() {
  osascript 2>/dev/null <<'AS'
tell application "Terminal"
  if frontmost is false then return ""
  try
    return tty of selected tab of front window
  on error
    return ""
  end try
end tell
AS
}

# ── 完了色の監視モード（フォアグラウンドになったら平常色へ戻して終了）──────
# 引数: __watch <tty> <目標R> <目標G> <目標B> <トークン>
if [ "$1" = "__watch" ]; then
  W_TTY="$2"; W_R="$3"; W_G="$4"; W_B="$5"; W_TOKEN="$6"
  WATCH_FILE="$STATE_DIR/$(basename "$W_TTY").watch"
  sleep "$FOCUS_GRACE"
  MAX_ITER=$(( FOCUS_MAX_MIN * 60 / FOCUS_POLL ))
  i=0
  while [ $i -lt $MAX_ITER ]; do
    [ "$(cat "$WATCH_FILE" 2>/dev/null)" = "$W_TOKEN" ] || exit 0
    terminal_running || exit 0
    if [ "$(front_tty)" = "$W_TTY" ]; then
      set_bg "$W_R" "$W_G" "$W_B" "$W_TTY"
      printf 'cleared\n' > "$WATCH_FILE"
      exit 0
    fi
    sleep "$FOCUS_POLL"
    i=$((i + 1))
  done
  exit 0
fi
# ────────────────────────────────────────────────

STATE="${1:-done}"
MYTTY="$(find_tty)" || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null
TTYNAME="$(basename "$MYTTY")"
ORIG_FILE="$STATE_DIR/$TTYNAME"
CURSOR_FILE="$STATE_DIR/$TTYNAME.cursor"
TITLE_FILE="$STATE_DIR/$TTYNAME.title"
WATCH_FILE="$STATE_DIR/$TTYNAME.watch"
STATE_FILE="$STATE_DIR/$TTYNAME.state"
BLINK_FILE="$STATE_DIR/$TTYNAME.blink.scpt"

# resume は「承認待ちだったときだけ作業中へ戻す」。
# PostToolUse は毎回のツール実行で発火するので、該当しなければ即座に抜ける。
if [ "$STATE" = "resume" ]; then
  [ "$(cat "$STATE_FILE" 2>/dev/null)" = "attention" ] || exit 0
  STATE="working"
fi

# 元の背景色を確保する。記録が無いとき、または明示的な reset のときだけ実測する。
# init で毎回実測すると、前回の着色が残っていた場合にそれを「元の色」として
# 焼き付けてしまうため、記録があればそちらを正とする。
# テーマを変えたら `tabcolor.sh reset` を平常色の状態で1回実行する。
if [ "$STATE" = "reset" ] || [ ! -s "$ORIG_FILE" ]; then
  BG="$(osascript 2>/dev/null <<AS
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$MYTTY" then
        set c to background color of t
        return ((item 1 of c) as text) & " " & ((item 2 of c) as text) & " " & ((item 3 of c) as text)
      end if
    end repeat
  end repeat
end tell
AS
)"
  [ -z "$BG" ] && exit 0
  printf '%s\n' "$BG" > "$ORIG_FILE"
fi
read -r O_R O_G O_B < "$ORIG_FILE" 2>/dev/null
[ -z "$O_B" ] && exit 0

# 元のカーソル色。タブ個別の設定ではなくプロファイルの値を正とする
# （タブ側が着色途中のときに焼き付けるのを避けるため）。
if [ "$STATE" = "reset" ] || [ ! -s "$CURSOR_FILE" ]; then
  CUR="$(osascript 2>/dev/null <<AS
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$MYTTY" then
        set c to cursor color of current settings of t
        return ((item 1 of c) as text) & " " & ((item 2 of c) as text) & " " & ((item 3 of c) as text)
      end if
    end repeat
  end repeat
end tell
AS
)"
  [ -n "$CUR" ] && printf '%s\n' "$CUR" > "$CURSOR_FILE"
fi
read -r C_R C_G C_B < "$CURSOR_FILE" 2>/dev/null
[ -z "$C_B" ] && { C_R=45000; C_G=45000; C_B=45000; }

# 元のタイトル設定（1行目=title displays custom title、2行目以降=custom title）。
save_title() {
  [ "$ATTENTION_FG_TITLE" = "1" ] || return 0
  if [ "$1" != "force" ] && [ -s "$TITLE_FILE" ]; then return 0; fi
  local out
  out="$(osascript 2>/dev/null <<AS
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$MYTTY" then
        return ((title displays custom title of t) as text) & linefeed & (custom title of t)
      end if
    end repeat
  end repeat
end tell
AS
)"
  [ -z "$out" ] && return 0
  # 承認待ちの点滅タイトルが残っていた場合、それを「元のタイトル」として
  # 焼き付けないようにする（前回セッションが異常終了したときに起きうる）
  case "$out" in
    *"$ATTENTION_TITLE_ON"*|*"$ATTENTION_TITLE_OFF"*) out='false' ;;
  esac
  printf '%s\n' "$out" > "$TITLE_FILE"
}

orig_tdct() { local v; v="$(head -n 1 "$TITLE_FILE" 2>/dev/null)"; [ "$v" = "true" ] && printf 'true' || printf 'false'; }
orig_title() { tail -n +2 "$TITLE_FILE" 2>/dev/null; }

# カーソル色（と、有効ならタイトル）を平常へ戻す
restore_extras() {
  local title_lines=""
  if [ "$ATTENTION_FG_TITLE" = "1" ]; then
    title_lines="        set custom title of t to \"$(esc "$(orig_title)")\"
        set title displays custom title of t to $(orig_tdct)"
  fi
  osascript >/dev/null 2>&1 <<AS
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$MYTTY" then
        set cursor color of t to {$C_R, $C_G, $C_B}
$title_lines
        return
      end if
    end repeat
  end repeat
end tell
AS
}

[ "$STATE" = "reset" ] && save_title force || save_title

mix() { printf '%d' $(( $1 + ($2 - $1) * $3 / 100 )); }

tint() { # tint <R> <G> <B> <割合> → "R G B"
  # macOS 標準の bash 3.2 には nameref が無いので値で受け取る
  printf '%s %s %s' "$(mix "$O_R" "$1" "$4")" \
                    "$(mix "$O_G" "$2" "$4")" \
                    "$(mix "$O_B" "$3" "$4")"
}

# 前面の周期を刻み数へ落とす。1周期 FG_TICKS 刻み、うち先頭 FG_ON_TICKS 刻みが点灯。
FG_TICKS="$(awk -v p="$ATTENTION_FG_PERIOD" -v t="$ATTENTION_FG_TICK" 'BEGIN{n=int(p/t+0.5); if(n<2)n=2; print n}')"
FG_ON_TICKS="$(awk -v o="$ATTENTION_FG_ON" -v t="$ATTENTION_FG_TICK" -v n="$FG_TICKS" \
               'BEGIN{k=int(o/t+0.5); if(k<1)k=1; if(k>n-1)k=n-1; print k}')"

# 走っている監視・点滅を退場させる（トークンを書き換えるだけ。kill はしない）。
# 点滅中だった場合は、点滅プロセスが次のトークン確認に到達して抜けるまで待つ。
# 待たずに塗ると、退場直前の1回に上書きされて色が戻らない。
# 承認待ちだったときはカーソル色・タイトルも確実に戻す（点滅側でも戻すが二重に保証する）。
cancel_bg() {
  local was; was="$(cat "$STATE_FILE" 2>/dev/null)"
  printf 'none\n' > "$WATCH_FILE"
  if [ "$was" = "attention" ]; then
    if [ "$BLINK_INTERVAL" != "0" ]; then
      sleep "$(awk -v a="$BLINK_INTERVAL" -v b="$ATTENTION_FG_TICK" \
               'BEGIN{m=(a+0>b+0)?a+0:b+0; print m+0.25}')"
    fi
    restore_extras
  fi
}

new_token() { printf '%s' "$$-$(date +%s)-$RANDOM"; }

# 完了色の監視を起動。$1$2$3 = フォアグラウンド時に戻す色
start_watch() {
  [ "$FOCUS_CLEAR" = "1" ] || return 0
  local token; token="$(new_token)"
  printf '%s\n' "$token" > "$WATCH_FILE"
  nohup bash "$SELF" __watch "$MYTTY" "$1" "$2" "$3" "$token" >/dev/null 2>&1 &
}

# 承認待ちの表示を起動。
#   $1$2$3 = 背面で点滅させる濃い色
#   $4$5$6 = 前面で周期的に点灯させる薄い色
# osascript 1本が常駐する（CPU 0.3% 程度）。トークンが変われば自分で終了する。
start_blink() {
  local token; token="$(new_token)"
  printf '%s\n' "$token" > "$WATCH_FILE"
  local cycles=$(( FOCUS_MAX_MIN * 60 ))

  # カーソル併用・タイトル併用は設定で切れる。オンのときだけ行を差し込む。
  local c_on="" c_off="" t_enable="" t_on="" t_off="" t_restore=""
  if [ "$ATTENTION_FG_CURSOR" = "1" ]; then
    c_on="        tell application \"Terminal\" to set cursor color of target to {${ATTENTION_CURSOR[0]}, ${ATTENTION_CURSOR[1]}, ${ATTENTION_CURSOR[2]}}"
    c_off="        tell application \"Terminal\" to set cursor color of target to {$C_R, $C_G, $C_B}"
  fi
  if [ "$ATTENTION_FG_TITLE" = "1" ]; then
    t_enable="      set title displays custom title of target to true"
    t_on="        tell application \"Terminal\" to set custom title of target to \"$(esc "$ATTENTION_TITLE_ON")\""
    t_off="        tell application \"Terminal\" to set custom title of target to \"$(esc "$ATTENTION_TITLE_OFF")\""
    t_restore="      set custom title of target to \"$(esc "$(orig_title)")\"
      set title displays custom title of target to $(orig_tdct)"
  fi

  cat > "$BLINK_FILE" <<AS
on stillMine()
  try
    set tok to (read POSIX file "$WATCH_FILE" as «class utf8»)
  on error
    return false
  end try
  return (tok contains "$token")
end stillMine

-- 自分のタブが最前面か。Terminal が最前面でない、
-- あるいは別ウィンドウ・別タブが選ばれていれば false。
on isFront()
  tell application "Terminal"
    if frontmost is false then return false
    try
      return ((tty of selected tab of front window) is "$MYTTY")
    on error
      return false
    end try
  end tell
end isFront

on run
  -- タブ参照は最初に1度だけ解決する（毎回探索すると点滅が遅くなる）
  set target to missing value
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is "$MYTTY" then set target to t
      end repeat
    end repeat
  end tell
  if target is missing value then return

  set mode to ""
  repeat $cycles times
    if not my stillMine() then exit repeat
    if my isFront() then
      -- 前面：平常色を基本にして、1周期に1回だけ薄いオレンジを点灯させる。
      -- 内側の1周は $ATTENTION_FG_PERIOD 秒ぶん（$FG_TICKS 刻み × $ATTENTION_FG_TICK 秒）。
      if mode is not "fg" then
        tell application "Terminal"
          set background color of target to {$O_R, $O_G, $O_B}
$t_enable
        end tell
        set mode to "fg"
      end if
      repeat with k from 0 to ($FG_TICKS - 1)
        if not my stillMine() then exit repeat
        if not my isFront() then exit repeat
        if k is 0 then
          tell application "Terminal" to set background color of target to {$4, $5, $6}
        else if k is $FG_ON_TICKS then
          tell application "Terminal" to set background color of target to {$O_R, $O_G, $O_B}
        end if
        if (k mod 2) is 0 then
$c_on
$t_on
        else
$c_off
$t_off
        end if
        delay $ATTENTION_FG_TICK
      end repeat
    else
      -- 背面：前面用の装飾を戻し、背景全面を濃いオレンジで速く点滅させる
      if mode is not "bg" then
        tell application "Terminal"
          set cursor color of target to {$C_R, $C_G, $C_B}
$t_restore
        end tell
        set mode to "bg"
      end if
      tell application "Terminal" to set background color of target to {$1, $2, $3}
      delay $BLINK_INTERVAL
      if not my stillMine() then exit repeat
      tell application "Terminal" to set background color of target to {$O_R, $O_G, $O_B}
      delay $BLINK_INTERVAL
    end if
  end repeat

  try
    tell application "Terminal"
      set cursor color of target to {$C_R, $C_G, $C_B}
$t_restore
    end tell
  end try
end run
AS
  nohup osascript "$BLINK_FILE" >/dev/null 2>&1 &
}

case "$STATE" in
  working)
    cancel_bg
    printf 'working\n' > "$STATE_FILE"
    set_bg $(tint "${WORKING_TINT[@]}" "$WORKING_MIX") "$MYTTY"
    ;;
  done)
    cancel_bg
    printf 'done\n' > "$STATE_FILE"
    set_bg $(tint "${DONE_TINT[@]}" "$DONE_MIX") "$MYTTY"
    start_watch "$O_R" "$O_G" "$O_B"
    ;;
  attention)
    printf 'attention\n' > "$STATE_FILE"
    if [ "$BLINK_INTERVAL" = "0" ]; then
      cancel_bg
      set_bg $(tint "${ATTENTION_TINT[@]}" "$ATTENTION_MIX") "$MYTTY"
    else
      start_blink $(tint "${ATTENTION_TINT[@]}" "$ATTENTION_MIX") \
                  $(tint "${ATTENTION_TINT[@]}" "$ATTENTION_FG_MIX")
    fi
    ;;
  init|restore|idle|reset)
    cancel_bg
    printf 'idle\n' > "$STATE_FILE"
    restore_extras
    set_bg "$O_R" "$O_G" "$O_B" "$MYTTY"
    ;;
esac
exit 0
