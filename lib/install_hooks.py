#!/usr/bin/env python3
"""Claude Code / Codex CLI の設定ファイルへ、通知フックを足し引きする。

対象となる設定ファイルは、どちらも各CLIが自分で書き換えるものなので、
丸ごと上書きせず「自分が足したエントリ」だけを足し引きする。
実行前に自動でバックアップを取る。冪等なので何度実行してもよい。

  python3 install_hooks.py            # 両方へ組み込む（設定ファイルがある方だけ）
  python3 install_hooks.py --claude   # Claude Code だけ
  python3 install_hooks.py --codex    # Codex CLI だけ
  python3 install_hooks.py --remove   # 取り外す
  python3 install_hooks.py --check    # 現状を表示するだけ（変更しない）
"""

import json
import os
import shutil
import sys

HOOK_DIR = "$HOME/.claude/hooks"  # 設定ファイルへはこの形のまま書く（環境非依存）

# (イベント, スクリプト, 引数)
CLAUDE_PLAN = [
    ("SessionStart",      "tabcolor.sh", "init"),          # 平常色にする
    ("UserPromptSubmit",  "tabcolor.sh", "working"),       # 作業中：薄い暖色
    ("Stop",              "notify.sh",   "stop"),          # 音・読み上げ・バナー・ベル
    ("Stop",              "tabcolor.sh", "done"),          # 完了：薄い緑
    ("Notification",      "notify.sh",   "notification"),  # 承認待ちの音
    ("Notification",      "tabcolor.sh", "attention"),     # 承認待ち：オレンジ
    ("PostToolUse",       "tabcolor.sh", "resume"),        # 承認後に作業中へ戻す
    ("PostToolUseFailure", "tabcolor.sh", "resume"),
    ("PermissionDenied",  "tabcolor.sh", "resume"),
    ("SessionEnd",        "tabcolor.sh", "restore"),       # 平常色へ戻す
]

# Codex には Claude Code の Notification に相当するものが無く、
# PermissionRequest がその役目を担う。PostToolUseFailure / PermissionDenied も無い。
CODEX_PLAN = [
    ("SessionStart",      "tabcolor.sh", "init"),
    ("UserPromptSubmit",  "tabcolor.sh", "working"),
    ("Stop",              "notify.sh",   "stop"),
    ("Stop",              "tabcolor.sh", "done"),
    ("PermissionRequest", "notify.sh",   "notification"),
    ("PermissionRequest", "tabcolor.sh", "attention"),
    ("PostToolUse",       "tabcolor.sh", "resume"),
    ("SessionEnd",        "tabcolor.sh", "restore"),
    ("Interrupt",         "tabcolor.sh", "init"),          # 中断時も平常色へ
]

# Codex はこの2イベントを 3 秒に切り詰め、async も同期実行へ落とす
# （合わせておかないと起動のたびに警告が出る）。tabcolor.sh は 0.2 秒程度で終わる。
CODEX_SHORT_EVENTS = ("SessionEnd", "Interrupt")

TARGETS = {
    "claude": {
        "label": "Claude Code",
        "path": os.path.expanduser("~/.claude/settings.json"),
        "plan": CLAUDE_PLAN,
        "short_events": (),
    },
    "codex": {
        "label": "Codex CLI",
        "path": os.path.expanduser("~/.codex/hooks.json"),
        "plan": CODEX_PLAN,
        "short_events": CODEX_SHORT_EVENTS,
    },
}

# 自分が足したエントリの目印。他人のフック（ガード等）を巻き込まないよう
# スクリプト名まで含めて厳密に判定する。
MARKS = ("/.claude/hooks/notify.sh", "/.claude/hooks/tabcolor.sh")


def is_mine(command):
    return any(m in str(command) for m in MARKS)


def cmd_for(script, arg):
    return '"%s/%s" %s' % (HOOK_DIR, script, arg)


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        text = f.read().strip()
    return json.loads(text) if text else {}


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def commands_of(hooks, event):
    out = []
    for group in hooks.get(event, []):
        for h in group.get("hooks", []):
            out.append(str(h.get("command", "")))
    return out


def show(target, hooks):
    mine = sum(1 for e in hooks for c in commands_of(hooks, e) if is_mine(c))
    print("  %s: 通知フック %d 件 / 全 %d 件"
          % (target["label"], mine,
             sum(len(commands_of(hooks, e)) for e in hooks)))
    for event in sorted(hooks):
        for c in commands_of(hooks, event):
            print("    %-18s %s%s" % (event, c[:60], "  ←通知" if is_mine(c) else ""))


def apply(target, remove):
    path = target["path"]
    data = load(path)
    hooks = data.setdefault("hooks", {})

    if os.path.exists(path):
        backup = path + ".notify.bak"
        shutil.copy2(path, backup)
        print("  バックアップ: %s" % backup)

    changed = 0
    if remove:
        for event in list(hooks):
            groups = []
            for group in hooks[event]:
                kept = [h for h in group.get("hooks", [])
                        if not is_mine(h.get("command", ""))]
                changed += len(group.get("hooks", [])) - len(kept)
                if kept:
                    group["hooks"] = kept
                    groups.append(group)
            if groups:
                hooks[event] = groups
            else:
                del hooks[event]
        print("  取り外し: %d 件" % changed)
    else:
        for event, script, arg in target["plan"]:
            command = cmd_for(script, arg)
            if command in commands_of(hooks, event):
                continue
            entry = {"type": "command", "command": command}
            if event in target["short_events"]:
                entry["timeout"] = 3
            else:
                entry["timeout"] = 20
                entry["async"] = True
            hooks.setdefault(event, []).append({"hooks": [entry]})
            changed += 1
        print("  組み込み: %d 件（既にある分は飛ばした）" % changed)

    save(path, data)
    return hooks


def main():
    argv = sys.argv[1:]
    remove = "--remove" in argv
    check = "--check" in argv
    picked = [k for k in ("claude", "codex") if "--" + k in argv] or ["claude", "codex"]

    for key in picked:
        target = TARGETS[key]
        exists = os.path.exists(target["path"])
        if check:
            print("--- %s: %s%s" % (target["label"], target["path"],
                                    "" if exists else "（無し）"))
            if exists:
                show(target, load(target["path"]).get("hooks", {}))
            continue
        if not exists and remove:
            print("--- %s: 設定ファイルが無いので何もしない" % target["label"])
            continue
        if not exists and key == "codex" and not os.path.isdir(
                os.path.expanduser("~/.codex")):
            print("--- %s: 未インストールらしいので飛ばす" % target["label"])
            continue
        print("--- %s: %s" % (target["label"], target["path"]))
        show(target, apply(target, remove))


if __name__ == "__main__":
    main()
