#!/usr/bin/env python3
"""transcript JSONL → handoff 素材 (stdlib only)。
出力 (stdout) は KEY<TAB>VALUE 行 + セクション本文。hook 側が整形する。"""
import json, sys, os

# harness 注入文 (skill base directory / system reminder / command 通知等) は
# user request として採用しない
_SKIP_PREFIXES = ("<", "/", "Base directory for this skill", "[SYSTEM", "Caveat:")
_SKIP_CONTAINS = ("<task-notification>", "<command-name>", "<local-command")

def main(path):
    if not path or not os.path.exists(path):
        print("USED_TOKENS\t0"); return 0
    requests, files, cmds, used = [], [], [], 0
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            msg = rec.get("message", {}) or {}
            usage = rec.get("usage") or msg.get("usage")
            if usage:
                used = (usage.get("input_tokens", 0) or 0) \
                     + (usage.get("cache_read_input_tokens", 0) or 0) \
                     + (usage.get("cache_creation_input_tokens", 0) or 0)
            content = msg.get("content")
            if isinstance(content, str):
                content = [{"type": "text", "text": content}]
            for blk in content or []:
                if not isinstance(blk, dict):
                    continue
                t = blk.get("type")
                if t == "text" and rec.get("type") == "user":
                    txt = (blk.get("text") or "").strip()
                    # single-char / slash command / harness 注入文は除外
                    if len(txt) > 3 and not txt.startswith(_SKIP_PREFIXES) \
                            and not any(s in txt for s in _SKIP_CONTAINS):
                        requests.append(txt[:280])
                elif t == "tool_use":
                    inp = blk.get("input", {}) or {}
                    fp = inp.get("file_path") or inp.get("notebook_path")
                    if fp:
                        files.append(fp)
                    if blk.get("name") == "Bash" and inp.get("command"):
                        cmds.append((inp["command"] or "")[:200])
    # 直近を優先・重複除去
    def uniq_tail(xs, n):
        seen, out = set(), []
        for x in reversed(xs):
            if x in seen:
                continue
            seen.add(x); out.append(x)
            if len(out) >= n:
                break
        return list(reversed(out))
    print(f"USED_TOKENS\t{used}")
    for r in uniq_tail(requests, 5):
        print(f"REQUEST\t{r}")
    for fp in uniq_tail(files, 8):
        print(f"FILE\t{fp}")
    for c in uniq_tail(cmds, 5):
        print(f"CMD\t{c}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ""))
