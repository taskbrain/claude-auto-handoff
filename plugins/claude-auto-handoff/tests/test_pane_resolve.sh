#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
# tmux を mock: list-panes は env PANES を出力 (id path command の3列)
TMOCK="$(mktemp -d)"
cat > "${TMOCK}/tmux" <<'M'
#!/usr/bin/env bash
case "$1" in
  list-panes) printf '%s\n' "${PANES}";;
  *) exit 0;;
esac
M
chmod +x "${TMOCK}/tmux"
PATH="${TMOCK}:${PATH}"
. "${HERE}/../scripts/_cc_pane_resolve.sh"
T="/tmp/cch-test-wt-a"

# 1) 同一 cwd に bash と node → claude(node) ペインを優先 (I1)
export PANES="%5 ${T} bash
%3 ${T} node"
assert_eq "$(resolve_pane_by_cwd "${T}")" "%3" "claude(node)ペイン優先"
# 2) command 不一致のみ → 最初の cwd 一致に degrade
export PANES="%5 ${T} bash"
assert_eq "$(resolve_pane_by_cwd "${T}")" "%5" "command 不一致は cwd 一致に degrade"
# 3) cwd 未一致 → 空
export PANES="%9 /other node"
assert_eq "$(resolve_pane_by_cwd "${T}")" "" "cwd 未一致は空"

# pane_is_idle: _capture_pane を override して画面内容を注入
_capture_pane() { printf '%s' "${FAKE_CAP:-}"; }
out=$(FAKE_CAP="app ❯ ready"               pane_is_idle p1 && echo IDLE || echo BUSY); assert_eq "${out}" "IDLE" "idle 画面 → idle"
out=$(FAKE_CAP="generating… esc to interrupt" pane_is_idle p1 && echo IDLE || echo BUSY); assert_eq "${out}" "BUSY" "生成中 (esc to interrupt) → busy"
out=$(FAKE_CAP=""                             pane_is_idle p1 && echo IDLE || echo BUSY); assert_eq "${out}" "BUSY" "capture 空 (不明) → busy"
out=$(pane_is_idle "" && echo IDLE || echo BUSY); assert_eq "${out}" "BUSY" "空 pane → busy"

rm -rf "${TMOCK}"
report
