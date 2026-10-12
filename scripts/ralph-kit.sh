#!/bin/bash
# ralph-kit（ralph-loop 一式の正本: https://github.com/shilokuma-inc/ralph-kit）を取得して、その中のスクリプトを実行する。
# このファイルは ralph-kit の install.sh が置く。直すときは、このリポジトリではなく ralph-kit の shim/ を直す。
#   usage: scripts/ralph-kit.sh run <ralph-setup|ralph-start|ralph-stop|askhub-manual> [引数…]
#          scripts/ralph-kit.sh path       取得した kit の場所を表示する（README.md・playbook.md はここにある）
#          scripts/ralph-kit.sh version    使う版と、そのコミットを表示する
#
# 使う版は .claude/ralph/kit.conf の ref（既定は v1）。互換を保つ更新は、kit の v1 のタグが動くだけで届く。
# 取得した kit は版（コミット）ごとに別の場所に置き、取得し直しても実行中のスクリプトを書き換えない。
#
# 環境変数（省略可）:
#   RALPH_KIT_DIR    取得せずに、この場所の kit を使う。run は実行するスクリプトにもこれを渡すので、
#                    ループ（launch で起動した claude）の中から呼ぶスクリプトは、起動したときと同じ版の kit を使う。
#                    kit を直して試すときは、kit の checkout を指定する
#   RALPH_KIT_REF    kit.conf の ref の代わりに使う版（タグ・ブランチ・コミット）
#   RALPH_KIT_CACHE  取得した kit の置き場所（既定: ~/.cache/ralph-kit）
#   RALPH_KIT_URL    kit の取得元（既定: https://github.com/shilokuma-inc/ralph-kit.git）
#   RALPH_KIT_FETCH_INTERVAL  タグ・ブランチを取り直す間隔（秒。既定: 300）
#   RALPH_KIT_LOCK_TIMEOUT    ほかのプロセスの取得を待つ上限（秒。既定: 120）。過ぎたら取得せずに手元の版を使う
#
# 取得した kit に入っている中継（shim/scripts/ralph-kit.sh）がこのファイルと違えば、処理をそちらに任せる。
# 中継を直したときも、各リポジトリへの PR なしで届けるため（このファイルが使われるのは、最初の取得だけになる）
set -euo pipefail

# Git hook や wrapper から継承した経路変数が別のチェックアウトを指すことがある
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

fail() { echo "ralph-kit: $*" >&2; exit 1; }
warn() { echo "ralph-kit: $*" >&2; }
usage() { sed -n '4,6p' "$0" | sed 's/^# //' >&2; exit 64; }

# kit の中継に任せたときは、任せた側（各リポジトリの scripts/）の場所を受け取る
SCRIPTS_DIR="${RALPH_KIT_SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd -P)}"
CONF="$(dirname "$SCRIPTS_DIR")/.claude/ralph/kit.conf"
URL="${RALPH_KIT_URL:-https://github.com/shilokuma-inc/ralph-kit.git}"
CACHE="${RALPH_KIT_CACHE:-$HOME/.cache/ralph-kit}"
# ループは周回ごとに status を呼ぶので、タグ・ブランチは毎回ではなく間隔をあけて取り直す
FETCH_INTERVAL="${RALPH_KIT_FETCH_INTERVAL:-300}"
[[ "$FETCH_INTERVAL" =~ ^[0-9]+$ ]] || fail "RALPH_KIT_FETCH_INTERVAL は 0 以上の整数で指定してください（指定: ${FETCH_INTERVAL}）"
LOCK_TIMEOUT="${RALPH_KIT_LOCK_TIMEOUT:-120}"
[[ "$LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || fail "RALPH_KIT_LOCK_TIMEOUT は 0 以上の整数で指定してください（指定: ${LOCK_TIMEOUT}）"
# 通信が止まった取得を打ち切る（ロックを持ったまま固まると、同じ Mac のほかのループも進めなくなる）。認証の入力も待たない
GIT_NET=(env GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 GIT_TERMINAL_PROMPT=0)

conf_ref() {
  [[ -f "$CONF" ]] || return 0
  sed -n -E 's/^[[:space:]]*ref[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p' "$CONF" | tail -n 1
}

# 取得した kit の場所（KIT）と、そのコミット（SHA）を決める
locate() {
  if [[ -n "${RALPH_KIT_DIR:-}" ]]; then
    [[ -x "$RALPH_KIT_DIR/bin/ralph-setup.sh" ]] || fail "RALPH_KIT_DIR が kit を指していません: $RALPH_KIT_DIR"
    KIT=$(cd "$RALPH_KIT_DIR" && pwd -P)
    REF="${RALPH_KIT_REF:-local}"
    SHA="${RALPH_KIT_SHA:-$(git -C "$KIT" rev-parse HEAD 2>/dev/null || echo unknown)}"
    return 0
  fi
  REF="${RALPH_KIT_REF:-$(conf_ref)}"
  REF="${REF:-v1}"
  # git の引数として読まれる値（- で始まるもの）や、参照名に使えない文字を含む値は受け付けない
  [[ "$REF" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || fail "kit の版の指定が不正です: $REF"
  command -v git >/dev/null 2>&1 || fail "git が見つかりません"
  mkdir -p "$CACHE" || fail "kit の置き場所を作れません: $CACHE"
  if lock; then
    fetch_and_extract
    unlock
  else
    # ほかのプロセスの取得が終わらないときは、取得せずに手元にある版で続ける
    warn "kit の取得の順番待ちが ${LOCK_TIMEOUT} 秒を超えたので、手元にある版を使います（${LOCK} が残っていないか確かめてください）"
    use_cached || fail "手元に kit の版 $REF がありません（${LOCK} が残っていないか確かめてください）"
  fi
}

# 取得も展開もせずに、手元にある版を使う
use_cached() {
  SHA=$(git --git-dir="$CACHE/repo.git" rev-parse -q --verify "$REF^{commit}" 2>/dev/null) || return 1
  KIT="$CACHE/$SHA"
  [[ -f "$KIT/.ralph-kit-complete" ]]
}

# 同じ Mac で複数のループが同時に取得しても壊れないよう、取得と展開は 1 つずつ行う
LOCK=""
lock() {
  local waited=0 limit=$((LOCK_TIMEOUT * 5))
  LOCK="$CACHE/.lock"
  trap 'exit 130' INT TERM
  until mkdir "$LOCK" 2>/dev/null; do
    # 取得の途中で止められて残ったロックは、10 分たったら外す
    if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
      rmdir "$LOCK" 2>/dev/null || true
      continue
    fi
    (( waited < limit )) || return 1
    sleep 0.2
    waited=$((waited + 1))
  done
  # 取れてから外す処理を付ける（待ちきれずに終わるとき、ほかのプロセスのロックを外さないように）
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}
unlock() {
  rmdir "$LOCK" 2>/dev/null || true
  trap - EXIT INT TERM
}

fetch_and_extract() {
  local mirror="$CACHE/repo.git" stamp="$CACHE/repo.git/ralph-kit-fetched-at" now last need=false tmp
  now=$(date +%s)
  if [[ ! -d "$mirror" ]]; then
    rm -rf "$mirror.tmp"
    "${GIT_NET[@]}" git clone --quiet --bare "$URL" "$mirror.tmp" || fail "kit を取得できません（${URL}）。ネットワークを確かめてください"
    mv "$mirror.tmp" "$mirror"
    echo "$now" > "$stamp"
  fi
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if ! git --git-dir="$mirror" rev-parse -q --verify "$REF^{commit}" >/dev/null 2>&1; then
    need=true
  elif [[ ! "$REF" =~ ^[0-9a-f]{40}$ ]] && (( now - last >= FETCH_INTERVAL )); then
    # コミットを直接指定したときは中身が変わらないので取り直さない。タグ・ブランチは動くので取り直す
    need=true
  fi
  if $need; then
    if ! "${GIT_NET[@]}" git --git-dir="$mirror" fetch --quiet --prune --force origin \
         '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'; then
      warn "kit の更新を取得できませんでした。手元にある版を使います"
    fi
    # 失敗しても時刻を残す（オフラインのとき、周回ごとに取得を試して待たせないよう、次も間隔をあける）
    echo "$now" > "$stamp"
  fi
  SHA=$(git --git-dir="$mirror" rev-parse -q --verify "$REF^{commit}") \
    || fail "kit の版 $REF が見つかりません（.claude/ralph/kit.conf の ref を確かめてください）"
  KIT="$CACHE/$SHA"
  # 展開済みの印が無いもの（展開の途中で止められたもの）は作り直す。印のあるものは書き換えない（実行中のループが読んでいる）
  if [[ ! -f "$KIT/.ralph-kit-complete" ]]; then
    tmp=$(mktemp -d "$CACHE/.extract.XXXXXX") || fail "kit を展開する場所を作れません: $CACHE"
    if ! git --git-dir="$mirror" archive "$SHA" | tar -x -C "$tmp"; then
      rm -rf "$tmp"
      fail "kit（${SHA}）を展開できません"
    fi
    touch "$tmp/.ralph-kit-complete"
    rm -rf "$KIT"
    mv "$tmp" "$KIT"
  fi
}

# 取得した kit に入っている中継がこのファイルと違えば、そちらに任せる（任せた先では、もう一度は任せない）
delegate() {
  local newer="$KIT/shim/scripts/ralph-kit.sh"
  [[ -z "${RALPH_KIT_DELEGATED:-}" && -f "$newer" ]] || return 0
  cmp -s "$newer" "$0" && return 0
  RALPH_KIT_DELEGATED=1 RALPH_KIT_SCRIPTS_DIR="$SCRIPTS_DIR" exec bash "$newer" "$@"
}

COMMAND="${1:-}"
case "$COMMAND" in
  run)
    case "${2:-}" in
      ralph-setup | ralph-start | ralph-stop | askhub-manual) ;;
      *) usage ;;
    esac
    ;;
  path | version) ;;
  *) usage ;;
esac
locate
delegate "$@"
shift
case "$COMMAND" in
  run)
    NAME="$1"
    shift
    [[ -x "$KIT/bin/$NAME.sh" ]] || fail "kit（${REF}）に bin/$NAME.sh がありません"
    # 子のプロセス（ループの claude など）から呼ぶ中継は、ここで渡す kit の場所を使う（任せた印は引き継がない）
    unset RALPH_KIT_DELEGATED RALPH_KIT_SCRIPTS_DIR
    export RALPH_KIT_DIR="$KIT" RALPH_KIT_REF="$REF" RALPH_KIT_SHA="$SHA"
    exec "$KIT/bin/$NAME.sh" "$@"
    ;;
  path)
    echo "$KIT"
    ;;
  version)
    echo "$REF $SHA"
    ;;
esac
