#!/bin/bash
# Claude Code / Codex CLI のターミナル表示（音・読み上げ・タブ背景色）を組み込む。
#
#   ./install.sh              両方へ組み込む（入っている CLI だけ）
#   ./install.sh --claude     Claude Code だけ
#   ./install.sh --codex      Codex CLI だけ
#   ./install.sh --check      現状を表示するだけ（何も変更しない）
#   ./install.sh --remove     取り外す
#
# 設定ファイルは丸ごと上書きせず、自分が足したエントリだけを足し引きする。
# 実行前に .notify.bak を残す。冪等なので何度実行してもよい。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/hooks"
SOUNDS="$DEST/sounds"
CLAUDE_APP_SFX="/Applications/Claude.app/Contents/Resources/ion-dist/audio/voice/sfx"

ARGS=("$@")
has() { local a; for a in ${ARGS+"${ARGS[@]}"}; do [ "$a" = "$1" ] && return 0; done; return 1; }

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\033[31mエラー:\033[0m %s\n' "$1" >&2; exit 1; }

echo
echo "Claude Code / Codex CLI ターミナル表示セットアップ"
echo "================================================"

# ── 前提の確認 ───────────────────────────────────
[ "$(uname)" = "Darwin" ] || die "macOS 専用です（Terminal.app のタブ色を AppleScript で変えるため）。"
command -v python3 >/dev/null 2>&1 || die "python3 が必要です。'xcode-select --install' で入ります。"

if ! ps -Ao comm= 2>/dev/null | grep -q '/Terminal\.app/Contents/MacOS/Terminal$'; then
  warn "Terminal.app が動いていません。タブの色付けは Terminal.app でのみ動きます"
  warn "（iTerm2・Ghostty・VS Code 等では色は付かず、音と読み上げだけ動きます）。"
fi

# ── 取り外し ────────────────────────────────────
if has --remove; then
  echo
  python3 "$HERE/lib/install_hooks.py" --remove ${ARGS+"${ARGS[@]}"}
  echo
  echo "設定ファイルから取り外しました。"
  echo "スクリプト本体と効果音は $DEST に残してあります。不要なら手動で削除してください。"
  exit 0
fi

# ── 現状確認だけ ─────────────────────────────────
if has --check; then
  echo
  python3 "$HERE/lib/install_hooks.py" --check ${ARGS+"${ARGS[@]}"}
  exit 0
fi

# ── スクリプト本体を置く ──────────────────────────
echo
echo "[1/3] スクリプトを $DEST へ配置"
mkdir -p "$DEST" || die "$DEST を作れませんでした。"
for s in notify.sh tabcolor.sh; do
  [ -f "$HERE/hooks/$s" ] || die "$HERE/hooks/$s が見つかりません。"
  if [ -f "$DEST/$s" ] && ! cmp -s "$HERE/hooks/$s" "$DEST/$s"; then
    cp "$DEST/$s" "$DEST/$s.bak"
    warn "既存の $s を $s.bak へ退避しました"
  fi
  cp "$HERE/hooks/$s" "$DEST/$s"
  chmod +x "$DEST/$s"
  ok "$DEST/$s"
done

# ── 効果音 ──────────────────────────────────────
echo
echo "[2/3] 効果音"
mkdir -p "$SOUNDS"
if [ -d "$CLAUDE_APP_SFX" ]; then
  # このMacに入っている Claude.app から複製する（配布物には同梱しない）
  copied=0
  for f in enter_voice_mode.mp3 exit_voice_mode.mp3; do
    if [ -f "$CLAUDE_APP_SFX/$f" ]; then
      cp "$CLAUDE_APP_SFX/$f" "$SOUNDS/$f" && copied=$((copied + 1))
    fi
  done
  # 変数の直後に全角文字を置かないこと（bash が変数名の一部と解釈する）
  [ "$copied" -gt 0 ] && ok "Claude.app から $copied 個を複製 → ${SOUNDS}"
fi
if [ ! -f "$SOUNDS/enter_voice_mode.mp3" ]; then
  warn "Claude.app が無いため macOS 標準音（Submarine / Glass）を使います"
  warn "好みの音にするなら notify.sh 冒頭の SOUND_STOP / SOUND_NOTIFY を書き換えてください"
fi

# ── 設定ファイルへ登録 ────────────────────────────
echo
echo "[3/3] 設定ファイルへ登録"
python3 "$HERE/lib/install_hooks.py" ${ARGS+"${ARGS[@]}"} || die "登録に失敗しました。"

# ── 仕上げ ──────────────────────────────────────
echo
echo "組み込みました。最後に次を確認してください。"
cat <<'NOTE'

  1. 「自動化」の許可
     初回だけ「Terminal を操作する許可」を求められます。許可しないと色が付きません。
     設定 → プライバシーとセキュリティ → 自動化 → ターミナル → Terminal をオン

  2. 通知の許可（既定では不要）
     ポップアップは既定で出しません。出したい場合だけ notify.sh の
     BANNER_ENABLED を 1 にし、設定 → 通知 → ターミナル をオンにしてください

  3. 平常色の記録
     ターミナルのテーマを変えたときは、色が付いていない状態で1回だけ実行してください。
       ~/.claude/hooks/tabcolor.sh reset

  4. 反映
     すでに開いているセッションには効きません。Claude Code / Codex を開き直してください。
     Codex は初回起動時にフックの信頼を確認してくるので、内容を見て許可してください。

  設定（色の濃さ・点滅の速さ・声・音）は、次の2ファイルの冒頭にまとまっています。
    ~/.claude/hooks/tabcolor.sh
    ~/.claude/hooks/notify.sh
NOTE
echo
