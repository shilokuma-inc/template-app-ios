#!/bin/bash
# 手動ループ（manual-loop）を、担当者の Mac と Claude アカウントで回すための補助スクリプト。
#   usage: scripts/askhub-manual.sh start <Discussion 番号> <epic/機能名>
#          scripts/askhub-manual.sh launch <完了語>
#          scripts/askhub-manual.sh status [--stopping]
#          scripts/askhub-manual.sh resume
#          scripts/askhub-manual.sh final
#
# 流れ（担当者の Claude Code が、AskHub からコピーした指示を受けて行う）:
#   1. start:  担当者が自分か確かめ、ralph-setup.sh で制御用 worktree とスロットを作り、epic を origin に push してから ready-for-loop を外す。
#              信用する author（このリポジトリに書き込み権限を持つ人）を表示し、状態用の Issue を「開始待ち」で書く
#   2. （Claude が playbook の {{...}} を埋め、STEP A に沿って goal を作る）
#   3. launch: 完了語を記録し、ralph-start.sh で state を作り、制御用 worktree で claude -p のループをバックグラウンドで起動する
#              （bypassPermissions で起動する。MDM などで禁止された Mac では auto モード。どちらも使えなければ起動しない）
#   4. status: 状態用の Issue を書き手 manual・回している人つきで書き直す（playbook の STEP D から呼ぶ。10 分に 1 回まで）
#   5. resume: 回答が付いた後などに、記録した完了語でループを起動し直す
#   6. final:  ループが終わったら、ゴール元の目印つきの最終 PR（epic-final）を作る。制御用 worktree の外から呼ぶ
#              goal に未完了のタスクが残っていれば作らない（回答待ちの PR だけが残っているときは作る）
#
# 必要なもの: gh（このリポジトリに書き込み権限のあるアカウントでログイン済み）・git・claude（ralph-loop プラグイン入り）
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift

fail() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '3,7p' "$0" | sed 's/^# //' >&2; exit 64; }

[[ -n "$COMMAND" ]] || usage
for command in gh git; do
  command -v "$command" >/dev/null 2>&1 || fail "$command が見つかりません"
done

# メインの checkout（制御用 worktree やスロットから呼ばれても、共通の .git から求める）
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || fail "git リポジトリの中で実行してください"
MAIN=$(dirname "$COMMON_DIR")
NAME=$(basename "$MAIN")
STEM="${NAME%-ios}"
CTL="$(dirname "$MAIN")/$STEM-ralph-ctl"
STATE_FILE="$CTL/.claude/askhub-manual.local.txt"
LOOP_STATE="$CTL/.claude/ralph-loop.local.md"
GOAL="$CTL/.claude/ralph-goal.local.md"
RALPH_STATE="$CTL/.claude/ralph-state.local.md"
PLAYBOOK="$CTL/.claude/ralph-playbook.local.md"
PID_FILE="$CTL/.claude/askhub-loop.pid"
LOG_DIR="${ASKHUB_LOG_DIR:-$HOME/Library/Logs/askhub/manual}"
BASE_BRANCH="${ASKHUB_BASE_BRANCH:-develop}"
STATUS_INTERVAL=600

REPOSITORY=$(cd "$MAIN" && gh repo view --json nameWithOwner --jq .nameWithOwner) || fail "GitHub のリポジトリを特定できません（gh auth status を確認してください）"
OWNER="${REPOSITORY%%/*}"
REPO="${REPOSITORY#*/}"

# 記録（key=value）を読む・書く
state_get() { [[ -f "$STATE_FILE" ]] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -1; return 0; }
state_set() {
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  local rest
  rest=$(grep -v "^$1=" "$STATE_FILE" || true)
  { [[ -n "$rest" ]] && printf '%s\n' "$rest"; printf '%s=%s\n' "$1" "$2"; } > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# start で記録した base branch を、resume・final でも使う（ASKHUB_BASE_BRANCH を付け忘れても、開始時と同じ base になるように）
if [[ "$COMMAND" != start ]]; then
  RECORDED_BASE=$(state_get base_branch)
  if [[ -n "$RECORDED_BASE" ]]; then BASE_BRANCH="$RECORDED_BASE"; fi
fi

viewer() { gh api user --jq .login; }

# このリポジトリで信用する author（書き込み権限を持つアカウント。AskHub と同じ判定）
trusted_authors() {
  gh api "repos/$REPOSITORY/collaborators?affiliation=all" --paginate \
    --jq '.[] | select(.permissions.push or .permissions.maintain or .permissions.admin) | .login' | sort -f | paste -sd, -
}

is_trusted() {
  local login="$1" list="$2"
  [[ -n "$login" ]] && printf '%s\n' "${list//,/$'\n'}" | grep -Fqix -- "$login"
}

loop_alive() {
  local pid
  [[ -f "$PID_FILE" ]] || return 1
  pid=$(tr -d '[:space:]' < "$PID_FILE")
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Discussion の ready-for-loop を外す（Discussion のラベルは REST で外せないので GraphQL を使う）
remove_ready_label() {
  local discussion_id="$1" label_id
  label_id=$(gh api graphql -f query='query($o:String!,$r:String!){ repository(owner:$o,name:$r){ label(name:"ready-for-loop"){ id } } }' \
    -f o="$OWNER" -f r="$REPO" --jq '.data.repository.label.id // ""')
  [[ -n "$label_id" ]] || return 0
  # shellcheck disable=SC2016  # GraphQL の変数なので展開しない
  gh api graphql -f query='mutation($d:ID!,$l:ID!){ removeLabelsFromLabelable(input:{labelableId:$d,labelIds:[$l]}){ clientMutationId } }' \
    -f d="$discussion_id" -f l="$label_id" >/dev/null
}

# playbook の「信用する author」を今の値に書き直す（epic の途中で招待した人も、次の起動から信用する）
refresh_trusted_authors() {
  local trusted="$1" current
  [[ -f "$PLAYBOOK" ]] || return 0
  current=$(sed -n -E 's/.*\*\*信用する author: `([^`]*)`\*\*.*/\1/p' "$PLAYBOOK" | head -n 1)
  [[ -n "$current" && "$current" != "$trusted" ]] || return 0
  OLD="$current" NEW="$trusted" perl -pi -e 's/\Q`$ENV{OLD}`\E/`$ENV{NEW}`/g' "$PLAYBOOK"
  echo "playbook の信用する author を更新しました（${trusted}）"
}

# ---- 状態用の Issue（loop-status）--------------------------------------------------------

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso_of() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

count_lines() { grep -c -E "$1" "$2" 2>/dev/null || true; }

# 状態を決める。--stopping はループが promise を出して終わる直前（state ファイルがまだあっても止まったものとして扱う）
compute_state() {
  local stopping="$1" waiting="$2" open
  open=$(grep -E '^- \[ \]' "$GOAL" 2>/dev/null | grep -vc '※回答待ち' || true)
  if [[ "$stopping" != true && -f "$LOOP_STATE" ]]; then
    if loop_alive; then echo running; else echo gave-up; fi
  elif [[ "$open" -gt 0 ]]; then
    echo waiting-to-start
  elif [[ -n "$waiting" ]]; then
    echo waiting-for-answer
  else
    echo completed
  fi
}

state_title() {
  case "$1" in
    running) echo "実行中" ;;
    waiting-for-answer) echo "回答待ち" ;;
    waiting-to-start) echo "開始待ち" ;;
    gave-up) echo "異常終了（再開を諦めた）" ;;
    completed) echo "完了（最終 PR のマージ待ち）" ;;
    *) echo "$1" ;;
  esac
}

write_status() {
  local stopping="${1:-false}" force="${2:-false}"
  local discussion epic runner waiting state total completed deferred last checked marker issue body signature now
  discussion=$(state_get discussion)
  epic=$(state_get epic)
  runner=$(state_get runner)
  [[ -n "$discussion" && -n "$epic" && -n "$runner" ]] || fail "手動ループの記録がありません（先に start を実行してください）"
  waiting=$(gh pr list -R "$REPOSITORY" --base "$epic" --label needs-answer --state open --limit 1000 --json number --jq '.[].number' | sort -n | paste -sd, -)
  state=$(compute_state "$stopping" "$waiting")
  total=$(count_lines '^- \[[ x]\]' "$GOAL")
  completed=$(count_lines '^- \[x\]' "$GOAL")
  deferred=$(count_lines '^- \[x\].*※保留' "$GOAL")
  signature="$state|$completed/$total/$deferred|$waiting"
  now=$(date +%s)
  local written
  written=$(state_get status_written_at)
  if [[ "$force" != true && "$signature" == "$(state_get status_signature)" ]] && (( now - ${written:-0} < STATUS_INTERVAL )); then
    return 0
  fi
  last=$(printf '%s\n' "$(mtime "$LOOP_STATE")" "$(mtime "$GOAL")" "$(mtime "$RALPH_STATE")" | sort -n | tail -1)
  checked=$(iso_now)
  marker="{\"checkedAt\":\"$checked\",\"discussion\":$discussion,\"epic\":\"$epic\""
  if [[ "$last" -gt 0 ]]; then marker="$marker,\"lastActivityAt\":\"$(iso_of "$last")\""; fi
  if [[ "$total" -gt 0 ]]; then marker="$marker,\"progress\":{\"completed\":$completed,\"deferred\":$deferred,\"total\":$total}"; fi
  marker="$marker,\"runner\":\"$runner\",\"state\":\"$state\""
  if [[ -n "$waiting" ]]; then marker="$marker,\"waitingPullRequests\":[$waiting]"; fi
  marker="$marker,\"writer\":\"manual\"}"
  body=$(cat <<BODY
<!-- ask-hub:loop-status $marker -->
## ループの状態

手動ループ（@$runner さんの Mac）が書き換える Issue です。編集・クローズしないでください。

| 項目 | 値 |
| --- | --- |
| 状態 | $(state_title "$state") |
| 書き手 | 手動 |
| 回している人 | @$runner |
| epic | $epic |
| ゴール元 | Discussion #$discussion |
| 進捗 | $completed / $total タスク完了 |
| 回答待ちの PR | ${waiting:-なし} |
| 確認時刻 | $checked |
BODY
)
  # 信用する author が作った状態用の Issue のうち、open で最も新しく更新されたもの（無ければ閉じたもので最も新しく更新されたもの）を使う
  # 信用する author ごとに探す（信用外の author が loop-status の Issue を大量に作っても、件数の上限で取りこぼさない）
  local trusted author candidates=""
  trusted=$(trusted_authors) || trusted=""
  # 取得できないときは状態用の Issue を作らない。ループ（STEP D や launch の後）を止めないよう、警告だけ出して成功で返す
  if [[ -z "$trusted" ]]; then
    echo "warning: 信用する author を取得できないため、状態用の Issue を更新しません（gh auth status と、このリポジトリの権限を確認してください）" >&2
    return 0
  fi
  local result
  while IFS= read -r author; do
    [[ -n "$author" ]] || continue
    # 取得に失敗したときも、上と同じく警告だけ出して成功で返す（取りこぼしたまま新しい Issue を作らない）
    if ! result=$(gh issue list -R "$REPOSITORY" --label loop-status --state all --author "$author" --limit 1000 --json number,state,updatedAt \
                    --jq '.[] | "\(if .state == "OPEN" then 0 else 1 end)\t\(.updatedAt)\t\(.number)"'); then
      echo "warning: @$author の状態用の Issue を取得できないため、状態用の Issue を更新しません（gh auth status を確認してください）" >&2
      return 0
    fi
    candidates+="$result"$'\n'
  done < <(printf '%s\n' "${trusted//,/$'\n'}")
  issue=$(printf '%s' "$candidates" | sed '/^$/d' | sort -t $'\t' -k1,1n -k2,2r | head -n 1 | cut -f 3)
  if [[ -z "$issue" ]]; then
    gh label create loop-status -R "$REPOSITORY" --color bfdadc --description "AskHub のループの状態を書き出す Issue" >/dev/null 2>&1 || true
    gh issue create -R "$REPOSITORY" --title "【AskHub】ループの状態" --label loop-status --body "$body" >/dev/null
  else
    gh issue edit "$issue" -R "$REPOSITORY" --body "$body" >/dev/null
    gh issue reopen "$issue" -R "$REPOSITORY" >/dev/null 2>&1 || true
  fi
  state_set status_signature "$signature"
  state_set status_written_at "$now"
  echo "ループの状態を書きました: $(state_title "$state")（回答待ちの PR: ${waiting:-なし}）"
}

# ---- ループの起動 --------------------------------------------------------------------------

# claude を指定の権限モードで起動したとき、実際に効く権限モード（起動時の init イベントから読む）。
# MDM や組織の管理設定で bypassPermissions が禁止されていると、エラーにならずに default で起動し、
# 確認の要る操作（ファイルの編集・コマンド）がすべて黙って拒否されるので、起動の前に確かめる。
# 制御用 worktree のループの Stop hook に捕まらないよう、一時ディレクトリで hook を止めて起動する。
# init の行が出たら（または ASKHUB_PROBE_TIMEOUT 秒（既定 60）たったら）、子プロセスごと止める
# （固まっても launch を止めない。claude の子プロセスが出力を開いたまま残っても待たないよう、新しいプロセスグループで起動する）。読めなければ空
effective_permission_mode() {
  local mode="$1" dir pid ticks=0 found="" limit=$(( ${ASKHUB_PROBE_TIMEOUT:-60} * 10 ))
  dir=$(mktemp -d)
  (cd "$dir" && exec perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' "${ASKHUB_CLAUDE:-claude}" -p --permission-mode "$mode" \
      --settings '{"disableAllHooks":true}' --no-session-persistence --output-format stream-json --verbose --max-turns 1 \
      "OK とだけ答えてください" </dev/null >"$dir/out" 2>/dev/null) &
  pid=$!
  while (( ticks < limit )); do
    found=$(grep -m 1 '"subtype":"init"' "$dir/out" 2>/dev/null | sed -n -E 's/.*"permissionMode": *"([^"]*)".*/\1/p' || true)
    [[ -n "$found" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    ticks=$(( ticks + 1 ))
  done
  # 終わる直前に書かれた init も拾う
  [[ -n "$found" ]] || found=$(grep -m 1 '"subtype":"init"' "$dir/out" 2>/dev/null | sed -n -E 's/.*"permissionMode": *"([^"]*)".*/\1/p' || true)
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir"
  printf '%s' "$found"
}

# ループを起動する権限モード。bypassPermissions が使えなければ auto にする。どちらも使えなければ起動しない
loop_permission_mode() {
  local mode
  mode=$(effective_permission_mode bypassPermissions)
  if [[ "$mode" == bypassPermissions ]]; then
    echo bypassPermissions
    return 0
  fi
  echo "この Mac では bypassPermissions が使えないため（起動時の権限モード: ${mode:-不明}）、auto モードで起動します" >&2
  mode=$(effective_permission_mode auto)
  if [[ "$mode" != auto ]]; then
    fail "この Mac では bypassPermissions も auto モードも使えません（起動時の権限モード: ${mode:-不明}）。確認の要る操作がすべて拒否されてループが進まないため、起動しません"
  fi
  echo auto
}

launch_loop() {
  local promise="$1"
  command -v "${ASKHUB_CLAUDE:-claude}" >/dev/null 2>&1 || fail "claude が見つかりません"
  loop_alive && fail "ループは既に動いています（PID $(cat "$PID_FILE")）。止めるには scripts/ralph-stop.sh"
  local permission_mode
  permission_mode=$(loop_permission_mode)
  [[ -f "$LOOP_STATE" ]] && rm -f "$LOOP_STATE"
  (cd "$CTL" && "$MAIN/scripts/ralph-start.sh" "$promise" >/dev/null)
  [[ -f "$LOOP_STATE" ]] || fail "state ファイルを作れませんでした: $LOOP_STATE"
  mkdir -p "$LOG_DIR"
  local log initial
  log="$LOG_DIR/$STEM-loop-$(date +%Y%m%d-%H%M%S).log"
  initial=$(sed -n '/^---$/,/^---$/!p' "$LOOP_STATE" | sed '/^$/d')
  # この Claude Code の会話とは別に、制御用 worktree で claude -p のループを起動する（Stop hook が周回させる）
  (
    cd "$CTL"
    nohup "${ASKHUB_CLAUDE:-claude}" -p --add-dir "${CTL%-ctl}-a" --add-dir "${CTL%-ctl}-b" \
      --permission-mode "$permission_mode" "$initial" </dev/null >>"$log" 2>&1 &
    echo $! > "$PID_FILE"
  )
  state_set log "$log"
  state_set permission_mode "$permission_mode"
  echo "ループを起動しました（PID $(cat "$PID_FILE")、権限モード: $permission_mode、ログ: $log）"
  echo "進み具合を見るには: tail -f \"$log\""
  write_status false true
}

# ---- サブコマンド --------------------------------------------------------------------------

case "$COMMAND" in
  start)
    DISCUSSION="${1:-}"
    EPIC="${2:-}"
    [[ "$DISCUSSION" =~ ^[0-9]+$ ]] || usage
    [[ "$EPIC" =~ ^epic/[a-z0-9][a-z0-9-]*$ ]] || fail "epic のブランチ名は epic/<英小文字・数字・ハイフン> にしてください: $EPIC"
    ME=$(viewer)
    TRUSTED=$(trusted_authors)
    is_trusted "$ME" "$TRUSTED" || fail "@$ME はこのリポジトリに書き込み権限がありません"
    # 1 行目: id・閉じているか・作成者・ラベル。2 行目以降: コメントの作成者と 1 行目（担当のコメントの目印を探す）
    INFO=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ discussion(number:$n){
        id closed author{login} labels(first:20){ nodes{ name } } comments(last:100){ nodes{ author{login} body } } } } }' \
      -f o="$OWNER" -f r="$REPO" -F n="$DISCUSSION" \
      --jq '.data.repository.discussion | if . == null then "MISSING" else
        "\(.id)\t\(.closed)\t\(.author.login // "")\t\([.labels.nodes[].name] | join(","))",
        (.comments.nodes[] | "C\t\(.author.login // "")\t\(.body | ltrimstr("\n") | split("\n")[0])") end') \
      || fail "Discussion #$DISCUSSION を取得できません"
    HEADER=$(printf '%s\n' "$INFO" | head -n 1)
    [[ "$HEADER" != MISSING ]] || fail "Discussion #$DISCUSSION が見つかりません"
    IFS=$'\t' read -r DISCUSSION_ID CLOSED AUTHOR LABELS <<<"$HEADER"
    [[ "$CLOSED" == false ]] || fail "Discussion #$DISCUSSION は閉じています"
    is_trusted "$AUTHOR" "$TRUSTED" || fail "Discussion #$DISCUSSION の作成者（@$AUTHOR）は、このリポジトリで信用する author ではありません"
    [[ ",$LABELS," == *",manual-loop,"* ]] || fail "Discussion #$DISCUSSION に manual-loop がありません（AskHub の回答画面で「手動で回す」を選んで投稿してください）"
    # 担当者は、信用する author が書いた担当のコメント（<!-- ask-hub:manual-assignee login="…" -->）のうち最後のもの
    ASSIGNEE=""
    while IFS=$'\t' read -r kind author first; do
      [[ "$kind" == C ]] || continue
      login=$(printf '%s' "$first" | sed -n -E 's/^<!-- ask-hub:manual-assignee login="([A-Za-z0-9-]+)" -->.*/\1/p')
      if [[ -n "$login" ]] && is_trusted "$author" "$TRUSTED"; then ASSIGNEE="$login"; fi
    done < <(printf '%s\n' "$INFO" | tail -n +2)
    if [[ -z "$ASSIGNEE" ]]; then
      fail "Discussion #$DISCUSSION に担当のコメントがありません（AskHub の回答画面で担当者を選んで投稿してください）"
    fi
    if [[ "$(printf '%s' "$ASSIGNEE" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')" && "${ASKHUB_MANUAL_FORCE:-}" != 1 ]]; then
      fail "この手動ループの担当者は @$ASSIGNEE です（あなたは @$ME）。担当を変えるときは、Discussion に担当のコメントを付け直してください"
    fi
    # 同じ Discussion でも、動いているループの記録（完了語など）を消さないように拒否する
    loop_alive && fail "制御用 worktree でループが動いています（PID $(cat "$PID_FILE")）。止めてから start を実行してください（止めるには scripts/ralph-stop.sh）"
    PREVIOUS=$(state_get discussion)
    if [[ -n "$PREVIOUS" && "$PREVIOUS" != "$DISCUSSION" && -f "$LOOP_STATE" ]]; then
      fail "制御用 worktree で Discussion #$PREVIOUS の手動ループが途中です。終わってから始めてください"
    fi
    (cd "$MAIN" && scripts/ralph-setup.sh "$EPIC" "$BASE_BRANCH" >/dev/null)
    # 子 PR の base になるので、epic を origin に置いておく（ralph-setup.sh は push しない）
    git -C "$MAIN" push --quiet -u origin "$EPIC" || fail "$EPIC を origin に push できません"
    # 準備と push が済んでから ready-for-loop を外す（途中で失敗したとき、ラベルだけ外れた状態を残さない）
    remove_ready_label "$DISCUSSION_ID"
    rm -f "$STATE_FILE"
    state_set repository "$REPOSITORY"
    state_set discussion "$DISCUSSION"
    state_set epic "$EPIC"
    state_set base_branch "$BASE_BRANCH"
    state_set runner "$ME"
    write_status false true
    cat <<NEXT
手動ループの準備ができました（$REPOSITORY / Discussion #$DISCUSSION / $EPIC / 担当 @$ME）。
制御用 worktree: $CTL

次に行うこと（Claude Code）:
  1. $PLAYBOOK の {{...}} をすべて埋める（.claude/ralph/README.md の「使い方」）。
     - TRUSTED_AUTHORS: $TRUSTED
     - GOAL_SOURCE: Discussion #$DISCUSSION
     - INTEGRATION_BRANCH: $EPIC / BASE_BRANCH: $BASE_BRANCH
  2. playbook の STEP A に沿って $GOAL を作る（Discussion の、信用する author の本文・コメント・返信だけを使う）
  3. 完了語を決めて、ループを起動する:
       scripts/askhub-manual.sh launch "<完了語>"
NEXT
    ;;

  launch)
    PROMISE="${1:-}"
    [[ -n "$PROMISE" ]] || usage
    [[ -f "$STATE_FILE" ]] || fail "手動ループの記録がありません（先に start を実行してください）"
    refresh_trusted_authors "$(trusted_authors)"
    state_set promise "$PROMISE"
    launch_loop "$PROMISE"
    ;;

  status)
    if [[ "${1:-}" == "--stopping" ]]; then
      write_status true true
    else
      write_status false false
    fi
    ;;

  resume)
    [[ -f "$STATE_FILE" ]] || fail "手動ループの記録がありません（先に start を実行してください）"
    PROMISE=$(state_get promise)
    [[ -n "$PROMISE" ]] || fail "完了語の記録がありません（launch で起動してください）"
    EPIC=$(state_get epic)
    # 片付け済みのスロットを作り直す（ralph-setup.sh は既存の worktree を再利用する）
    (cd "$MAIN" && scripts/ralph-setup.sh "$EPIC" "$BASE_BRANCH" >/dev/null)
    refresh_trusted_authors "$(trusted_authors)"
    launch_loop "$PROMISE"
    ;;

  final)
    [[ -f "$STATE_FILE" ]] || fail "手動ループの記録がありません"
    # 制御用 worktree そのものか、その中なら拒否する（前方一致だと …-ralph-ctl2 のような別のディレクトリも拒否してしまう）
    if [[ -d "$CTL" ]]; then
      CTL_REAL=$(cd "$CTL" && pwd -P)
      HERE=$(pwd -P)
      if [[ "$HERE" == "$CTL_REAL" || "$HERE" == "$CTL_REAL/"* ]]; then
        fail "制御用 worktree の外（メインの checkout など）で実行してください"
      fi
    fi
    loop_alive && fail "ループがまだ動いています。終わってから最終 PR を作ってください"
    DISCUSSION=$(state_get discussion)
    EPIC=$(state_get epic)
    # status と同じ判定で状態を求め、goal のタスクが終わっているときだけ進める
    # 回答待ちの PR が残っていても作る（自動ループと同じ。回答待ちの PR は下で本文に載せる）
    # goal が読めないと未完了のタスクを 0 件と数えてしまうので、先に拒否する
    [[ -f "$GOAL" && -r "$GOAL" ]] || fail "goal がありません、または読み込めません: $GOAL"
    WAITING=$(gh pr list -R "$REPOSITORY" --base "$EPIC" --label needs-answer --state open --limit 1000 --json number --jq '.[].number' | sort -n | paste -sd, -)
    # ※回答待ちの未完了タスクごとに、goal に書いた PR（※回答待ち（PR #123 / ask id 456））が open な回答待ちの PR か確かめる
    # PR を閉じた・ラベルを外したタスクは、compute_state では完了扱いになり、本文の「回答待ちの PR」にも載らないので拒否する
    while IFS= read -r TASK; do
      if [[ "${TASK#*※回答待ち}" =~ PR[[:space:]]*#([0-9]+) ]]; then
        [[ ",$WAITING," == *",${BASH_REMATCH[1]},"* ]] \
          || fail "goal の ※回答待ち のタスクの PR #${BASH_REMATCH[1]} が、open な回答待ちの PR（needs-answer）ではありません。goal を直すか、resume でループを再開してください: $TASK"
      else
        fail "goal の ※回答待ち のタスクに PR 番号がありません。goal を直してください: $TASK"
      fi
    done < <(grep -E '^- \[ \].*※回答待ち' "$GOAL" || true)
    FINAL_STATE=$(compute_state true "$WAITING")
    case "$FINAL_STATE" in
      completed | waiting-for-answer) ;;
      waiting-to-start) fail "goal に未完了のタスクが残っています（$GOAL）。scripts/askhub-manual.sh resume でループを再開してください" ;;
      *) fail "ループの状態が「$(state_title "$FINAL_STATE")」のため、最終 PR を作れません" ;;
    esac
    # マージせずに閉じた PR は既存として扱わない（作り直せるように）。open かマージ済みがあれば作らない
    EXISTING=$(gh pr list -R "$REPOSITORY" --head "$EPIC" --base "$BASE_BRANCH" --state all --json url,state --jq '[.[] | select(.state != "CLOSED")][0].url // ""')
    if [[ -n "$EXISTING" ]]; then
      echo "最終 PR は既にあります: $EXISTING"
      exit 0
    fi
    SUMMARY=$(awk '/^## 最終 PR に載せる内容/{f=1; next} /^## /{f=0} f' "$RALPH_STATE" 2>/dev/null | grep -v '^<!--.*-->$' || true)
    [[ -n "$(printf '%s' "$SUMMARY" | tr -d '[:space:]')" ]] || fail "$RALPH_STATE の「最終 PR に載せる内容」が空です（ループが STEP D で埋めます）"
    gh label create epic-final -R "$REPOSITORY" --color B60205 --description "epic から develop への最終 PR" >/dev/null 2>&1 || true
    # 回答待ちの PR は、ループが書いた内容に頼らず、この時点で open なものを本文に載せる（ask の内容は各 PR を見てもらう）
    if [[ -n "$WAITING" ]]; then
      SUMMARY=$(printf '%s\n\n## 回答待ちの PR\n\n%s\n\n質問の内容はそれぞれの PR の ask を確認してください。' "$SUMMARY" "$(printf '%s\n' "${WAITING//,/$'\n'}" | sed 's/^/- #/')")
    fi
    # 先頭の 2 行は、マージ時にゴール元の Discussion を閉じるワークフロー（close-goal-discussion.yml）が読む目印
    BODY=$(printf 'ゴール元: Discussion #%s\n<!-- ask-hub:discussion %s -->\n\n%s\n\n---\nこの PR は手動ループ（@%s）が作成しました。AskHub アプリの「要対応」タブの「マージ待ち」から確認して、merge commit でマージしてください。\n' \
      "$DISCUSSION" "$DISCUSSION" "$SUMMARY" "$(state_get runner)")
    URL=$(gh pr create -R "$REPOSITORY" --base "$BASE_BRANCH" --head "$EPIC" --title "【FEAT】$EPIC を $BASE_BRANCH に取り込む" \
      --assignee @me --label epic-final --body "$BODY")
    echo "最終 PR を作りました: $URL"
    if [[ "$BASE_BRANCH" != develop ]]; then
      echo "注意: base が develop ではないため、マージしてもゴール元の Discussion は自動で閉じません（close-goal-discussion.yml は develop へのマージだけを見る）。マージ後に Discussion #$DISCUSSION を手で閉じてください" >&2
    fi
    write_status true true
    ;;

  *)
    usage
    ;;
esac
