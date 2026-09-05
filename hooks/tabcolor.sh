#!/bin/bash
# Claude Code / Codex CLI の状態を Terminal.app のタブの見た目で表示する。
#
#   tabcolor.sh init       セッション開始：元の背景色・カーソル色・タイトルを記録して無色へ
#   tabcolor.sh working    作業中：ごく薄い暖色
#   tabcolor.sh done       完了：薄い緑。フォアグラウンドにすると無色へ戻る
#   tabcolor.sh attention  承認待ち：応答するまで知らせ続ける（下記）
#   tabcolor.sh resume     承認待ちだった場合だけ作業中へ戻す（PostToolUse 用・軽量）
#   tabcolor.sh restore    セッション終了：無色へ
#   tabcolor.sh reset      平常の色・タイトルを記録し直す（テーマ変更後に1回だけ）
#
# 承認待ちの見せ方は、そのタブが最前面かどうかで切り替わる。
#   バックグラウンド … 背景全面を暖色でゆっくり明滅（離れていても気づけるように）
#   フォアグラウンド … 背景は平常色を基本とし、ATTENTION_FG_PERIOD 秒に1回だけ
#                      薄い暖色へふわりと明るくして戻す。
#                      読んでいる最中はほぼ平常色なので文字が読める。
#
# 明滅は「明るさ 0〜100 の数列」を先に作り、AppleScript 側はそれを順に流すだけにする。
# なめらかな明滅（fade）と 0か100かの点滅（blink）の違いは、数列の中身だけになる。
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
WORKING_TINT=(26000 13000 0);    WORKING_MIX=16    # 作業中：ごく薄い暖色
DONE_TINT=(0 34000 10000);       DONE_MIX=20       # 完了：薄い緑
ATTENTION_TINT=(26000 13000 0);  ATTENTION_MIX=55  # 承認待ち（背面）：同じ暖色を濃く
# 作業中と承認待ちは同じ黄みの暖色で、濃さだけが違う。赤みの強い橙は
# 「エラーが起きた」と読まれ、藤色は暗い画面で見えにくかったため、
# 両方を試したうえでこの形に落ち着いた（2026-09-05）。完了だけが緑。
# 承認待ちの 55% は、作業中の 16% と輝度で十分離すために要る（28.1 対 41.7）。
# 同じ色相なので、濃さを近づけると明滅の途中で作業中と見分けがつかなくなる。

# 明滅のしかた。
#   fade  … 平常色と暖色の間をなめらかに往復する（既定）
#   blink … 0か100かで切り替える従来の点滅
#   off   … 明滅させず点灯したまま
BLINK_STYLE=fade
BLINK_PERIOD=3.0           # fade：明滅1往復の秒数（暗→明→暗）。大きいほどゆっくり
BLINK_STEPS=20             # fade：1往復の段階数。多いほど滑らかで、その分負荷が増える
                           # 段階数 ÷ 周期 が1秒あたりの色変更の回数になる（既定は約7回）
BLINK_INTERVAL=0.45        # blink：点滅間隔（秒）。0 は off と同じ扱い

# 承認待ち × フォアグラウンド のときの見せ方
ATTENTION_FG_MIX=6              # いちばん明るいときの暖色の濃さ（0=平常色のまま）
ATTENTION_FG_PERIOD=7           # 明滅の周期（秒）。この間隔で1回ふわりと明るくなる
ATTENTION_FG_ON=1               # いちばん明るいところで保つ秒数
ATTENTION_FG_FADE=0.8           # fade：明るくなる／暗くなるのにかける秒数（片道）
ATTENTION_FG_STEP=0.15          # fade：内部の刻み（秒）
ATTENTION_FG_TICK=0.5           # blink：内部の刻み（秒）
ATTENTION_FG_CURSOR=1           # 1=カーソルも背景と一緒に明滅させる / 0=背景だけ
ATTENTION_CURSOR=(65535 28000 0)  # 明滅させるカーソル色（明側）。暗側は平常のカーソル色
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

# ── 承認待ちと「入力待ち」を切り分ける ─────────────────
# Claude Code の Notification は2種類の出来事で発火する。
#   ・承認が必要      "Claude needs your permission to use Bash"
#   ・入力待ち(idle)  "Claude is waiting for your input"
# 両方を承認待ち扱いにすると、応答を読んでいるだけの平常時に
# 承認待ちの明滅が始まってしまう（2026-09-01 に実際に発生）。
# フック入力の message を見て、承認を求めるものだけ点滅させる。
#
# Codex の PermissionRequest には message が無く、そのイベント自体が
# 承認要求なので、message を取れなかった場合は点滅させる（従来どおり）。
if [ "$STATE" = "attention" ] && [ ! -t 0 ]; then
  HOOK_INPUT=""
  IFS= read -r -t 2 HOOK_INPUT 2>/dev/null || true
  if [ -n "$HOOK_INPUT" ]; then
    MSG="$(printf '%s' "$HOOK_INPUT" \
           | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
           | head -n 1)"
    if [ -n "$MSG" ]; then
      case "$MSG" in
        *permission*|*Permission*|*approve*|*Approve*) ;;   # 承認待ち → 点滅させる
        *) exit 0 ;;                                        # 入力待ちなど → 何もしない
      esac
    fi
  fi
fi
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

# ── 明るさ（0〜100）の数列を作る ────────────────────
# 背面は「暗→明→暗」の1往復、前面は「1周期のうち1回だけ明るくなる」形。
# cos を使うと両端がゆっくり・中央が速くなり、機械的な点滅より目にやわらかい。
levels_fade_cycle() { # $1=段階数
  awk -v n="$1" 'BEGIN{ if(n<2)n=2; pi=atan2(0,-1);
    for(i=0;i<n;i++) printf "%s%d", (i?", ":""), int(100*(1-cos(2*pi*i/n))/2+0.5); print "" }'
}
levels_fade_pulse() { # $1=周期 $2=片道の秒数 $3=保つ秒数 $4=刻み
  awk -v p="$1" -v f="$2" -v on="$3" -v t="$4" 'BEGIN{ pi=atan2(0,-1); if(f<=0)f=0.001;
    if(2*f+on>p){ s=p/(2*f+on); f=f*s; on=on*s }   # 周期に収まらない設定は縮める
    n=int(p/t+0.5); if(n<2)n=2;
    for(i=0;i<n;i++){ x=i*t;
      if(x<f)           v=100*(1-cos(pi*x/f))/2;
      else if(x<f+on)   v=100;
      else if(x<2*f+on) v=100*(1+cos(pi*(x-f-on)/f))/2;
      else              v=0;
      printf "%s%d", (i?", ":""), int(v+0.5) } print "" }'
}
levels_blink_pulse() { # $1=周期 $2=点灯秒数 $3=刻み
  awk -v p="$1" -v on="$2" -v t="$3" 'BEGIN{ n=int(p/t+0.5); if(n<2)n=2;
    k=int(on/t+0.5); if(k<1)k=1; if(k>n-1)k=n-1;
    for(i=0;i<n;i++) printf "%s%d", (i?", ":""), (i<k?100:0); print "" }'
}
# 前面かどうかの確認は毎刻みでは重いので、おおむね 0.5 秒に1回に間引く
front_every() { awk -v s="$1" 'BEGIN{ n=int(0.5/s+0.5); if(n<1)n=1; print n }'; }

if [ "$BLINK_STYLE" = "fade" ]; then
  BG_STEP="$(awk -v p="$BLINK_PERIOD" -v n="$BLINK_STEPS" 'BEGIN{ if(n<2)n=2; printf "%.3f", p/n }')"
  BG_LEVELS="$(levels_fade_cycle "$BLINK_STEPS")"
  FG_STEP="$ATTENTION_FG_STEP"
  FG_LEVELS="$(levels_fade_pulse "$ATTENTION_FG_PERIOD" "$ATTENTION_FG_FADE" "$ATTENTION_FG_ON" "$ATTENTION_FG_STEP")"
else
  BG_STEP="$BLINK_INTERVAL"
  BG_LEVELS="100, 0"
  FG_STEP="$ATTENTION_FG_TICK"
  FG_LEVELS="$(levels_blink_pulse "$ATTENTION_FG_PERIOD" "$ATTENTION_FG_ON" "$ATTENTION_FG_TICK")"
fi
FRONT_EVERY_BG="$(front_every "$BG_STEP")"
FRONT_EVERY_FG="$(front_every "$FG_STEP")"

# 走っている監視・点滅を退場させる（トークンを書き換えるだけ。kill はしない）。
# 点滅中だった場合は、点滅プロセスが次のトークン確認に到達して抜けるまで待つ。
# 待たずに塗ると、退場直前の1回に上書きされて色が戻らない。
# 承認待ちだったときはカーソル色・タイトルも確実に戻す（点滅側でも戻すが二重に保証する）。
cancel_bg() {
  local was; was="$(cat "$STATE_FILE" 2>/dev/null)"
  printf 'none\n' > "$WATCH_FILE"
  if [ "$was" = "attention" ]; then
    if [ "$BLINK_STYLE" != "off" ] && [ "$BLINK_INTERVAL" != "0" ]; then
      sleep "$(awk -v a="$BG_STEP" -v b="$FG_STEP" \
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
#   $1$2$3 = 背面で明滅させる暖色（いちばん明るいとき）
#   $4$5$6 = 前面で明滅させる薄い暖色（いちばん明るいとき）
# osascript 1本が常駐する。色を変える回数だけ Terminal に描き直させるので、
# 既定（1秒に約7回）で Terminal と合わせて1コアの数%。トークンが変われば自分で終了する。
start_blink() {
  local token; token="$(new_token)"
  printf '%s\n' "$token" > "$WATCH_FILE"
  local maxsecs=$(( FOCUS_MAX_MIN * 60 ))

  # カーソル併用・タイトル併用は設定で切れる。オンのときだけ行を差し込む。
  local c_set="" t_enable="" t_block="" t_restore=""
  if [ "$ATTENTION_FG_CURSOR" = "1" ]; then
    c_set="            set cursor color of target to my blend(baseCUR, peakCUR, lv)"
  fi
  if [ "$ATTENTION_FG_TITLE" = "1" ]; then
    t_enable="      set title displays custom title of target to true"
    # タイトルには中間色が無いので、明るさが半分を越えたところで切り替える
    t_block="          set wantOn to (lv > 50)
          if wantOn is not titleOn then
            tell application \"Terminal\"
              if wantOn then
                set custom title of target to \"$(esc "$ATTENTION_TITLE_ON")\"
              else
                set custom title of target to \"$(esc "$ATTENTION_TITLE_OFF")\"
              end if
            end tell
            set titleOn to wantOn
          end if"
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

-- tty から自分のタブを探す
on findTab()
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is "$MYTTY" then return t
      end repeat
    end repeat
  end tell
  return missing value
end findTab

-- 保存したタブ参照が、まだ自分のタブを指しているか確かめる。
-- Terminal のタブ参照は位置で解決されるため、ウィンドウが増減すると
-- 黙って別のタブを指すようになる（2026-09-01 に実測）。放置すると
-- 無関係なウィンドウを点滅させてしまうので、毎周ここで確かめ直す。
-- 大半の周回は tty を1回読むだけで済み、探索は必要なときだけ走る。
on ensureTab(cur)
  try
    tell application "Terminal"
      if (tty of cur) is "$MYTTY" then return cur
    end tell
  end try
  return my findTab()
end ensureTab

-- 平常色 a と承認待ちの色 b を、明るさ lv（0〜100）で混ぜる
on blend(a, b, lv)
  return {((item 1 of a) + ((item 1 of b) - (item 1 of a)) * lv / 100) as integer, ¬
          ((item 2 of a) + ((item 2 of b) - (item 2 of a)) * lv / 100) as integer, ¬
          ((item 3 of a) + ((item 3 of b) - (item 3 of a)) * lv / 100) as integer}
end blend

on run
  set target to my findTab()
  if target is missing value then return

  set baseBG to {$O_R, $O_G, $O_B}
  set peakBG to {$1, $2, $3}
  set peakFG to {$4, $5, $6}
  set baseCUR to {$C_R, $C_G, $C_B}
  set peakCUR to {${ATTENTION_CURSOR[0]}, ${ATTENTION_CURSOR[1]}, ${ATTENTION_CURSOR[2]}}
  set bgLevels to {$BG_LEVELS}
  set fgLevels to {$FG_LEVELS}

  set mode to ""
  set lastLv to -1
  set titleOn to false
  set startedAt to current date
  repeat
    if not my stillMine() then exit repeat
    if ((current date) - startedAt) > $maxsecs then exit repeat
    set target to my ensureTab(target)
    if target is missing value then exit repeat
    if my isFront() then
      -- 前面：平常色を基本にして、1周期に1回だけ薄い暖色へふわりと明るくする。
      -- 内側の1周は $ATTENTION_FG_PERIOD 秒ぶん（数列 fgLevels × $FG_STEP 秒）。
      if mode is not "fg" then
        tell application "Terminal"
          set background color of target to baseBG
$t_enable
        end tell
        set mode to "fg"
        set lastLv to -1
      end if
      set i to 0
      repeat with lvRef in fgLevels
        if not my stillMine() then exit repeat
        set lv to lvRef as integer
        -- 明るさが前の刻みと同じなら何も送らない（暗いままの大半の時間は無操作）
        if lv is not lastLv then
          set c to my blend(baseBG, peakFG, lv)
          tell application "Terminal"
            set background color of target to c
$c_set
          end tell
$t_block
          set lastLv to lv
        end if
        set i to i + 1
        if (i mod $FRONT_EVERY_FG) is 0 then
          if not my isFront() then exit repeat
        end if
        delay $FG_STEP
      end repeat
    else
      -- 背面：前面用の装飾を戻し、背景全面を暖色でゆっくり明滅させる
      if mode is not "bg" then
        tell application "Terminal"
          set cursor color of target to baseCUR
$t_restore
        end tell
        set mode to "bg"
      end if
      set i to 0
      repeat with lvRef in bgLevels
        if not my stillMine() then exit repeat
        set c to my blend(baseBG, peakBG, (lvRef as integer))
        tell application "Terminal" to set background color of target to c
        set i to i + 1
        if (i mod $FRONT_EVERY_BG) is 0 then
          if my isFront() then exit repeat
        end if
        delay $BG_STEP
      end repeat
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
    if [ "$BLINK_STYLE" = "off" ] || [ "$BLINK_INTERVAL" = "0" ]; then
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
