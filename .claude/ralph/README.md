# ralph-loop 運用テンプレート

[ralph-loop](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/ralph-loop) で
自律的に実装を回すための雛形。設計の根拠と、実際に踏んだ落とし穴は
[Discussion #87](https://github.com/shilokuma-inc/template-app-ios/discussions/87) を参照。

## 構成

```
.claude/ralph/
  playbook.template.md          手順。毎イテレーション読み直される
  goal.template.md              タスクと確定済みの決定事項
  state.template.md             in-flight / 回答待ち / 保留 の記録
  settings.deny.example.json    権限の deny リスト（制御用 worktree の settings.json へ）
  CLAUDE.snippet.md             CLAUDE.md に貼るポインタ（新しいセッションの入口）
scripts/
  ralph-setup.sh                worktree と統合ブランチを用意する
  ralph-start.sh                state ファイルを生成する（＝ループ開始）
  ralph-stop.sh                 停止と後片付け
```

ループが実際に読むのは、制御用 worktree に置かれた次の3ファイル。

| ファイル | 役割 |
| --- | --- |
| `ralph-playbook.local.md` | 手順。**直せば次の周回から反映される**（ループの張り直し不要） |
| `ralph-goal.local.md` | タスクのチェックリストと決定事項 |
| `ralph-state.local.md` | in-flight の PR と、人間への申し送り |

いずれも `.git/info/exclude` で除外される（`ralph-setup.sh` が追記する）。

## まず CLAUDE.md にポインタを置く

新しい Claude Code セッションはこの仕組みの存在を知らない。**`CLAUDE.md` は毎セッション
自動で読み込まれる唯一の入口**なので、`CLAUDE.snippet.md` の内容を `CLAUDE.md` に
追記しておく。これが無いと、文脈を持たないセッションは state ファイルを手書きしたり、
統合ブランチを挟まずに develop へ直接マージしたりする。

## 使い方

以下は `myapp-ios` で `epic/monetization` を回す場合の例。
**ブランチ名とパスは自分のものに読み替えること**（そのまま貼っても動くよう、
山かっこのプレースホルダは使っていない）。

```bash
# 1. worktree と統合ブランチを用意（epic/[機能名] をテーマ単位で指定する）
scripts/ralph-setup.sh epic/monetization

# 2. 制御用 worktree の playbook と goal を埋める
#    playbook の二重波かっこをすべて置換し、「このアプリ固有の前提」を書く

# 3. 統合ブランチを push
cd ../myapp-ralph-ctl && git push -u origin epic/monetization

# 4. ループ開始（state ファイルを生成）
../myapp-ios/scripts/ralph-start.sh "MONETIZATION DONE"

# 5. 起動（ralph-start.sh が出力するコマンドをそのまま使う）
```

停止は `scripts/ralph-stop.sh`。worktree ごと消すなら、**Claude のセッションが終了してから**
`scripts/ralph-stop.sh --worktrees` を実行する（実行中のループを止めたのと同じ呼び出しでは、
作業中のスロットを壊さないよう削除しない）。

### テンプレートを更新したとき

**テンプレートは初回のみコピーされる。** 置換済みの playbook を上書きしないためで、
改善しても既存の制御用 worktree には自動では届かない。

`ralph-setup.sh` を再実行すると、**既存の playbook に無いテンプレートの節を見出し単位で
報告する**ので、必要なものを手で取り込む。ゴールと state は影響を受けない。

## 設計上の要点

**統合ブランチを挟む。** `develop` へ直接マージさせると push のたびに Upload 系
ワークフローが発火し、1タスクごとにビルドが App Store Connect へ積まれる。
**`epic/[機能名]`**（テーマ単位）に集約し、人間が最後に1本の PR でレビューして取り込む。
`epic/**` はフィーチャーブランチと同じく Build / Archive が走るので、CI の検証力は保たれる。
CI の無いリポジトリでは、playbook のローカル検証（`{{VERIFY_COMMANDS}}`）を通したことを state に記録し、それを CI の代わりにする。
1ループ = 1 epic。epic を分ければ、ループ自体を複数走らせて並列化できる。

**`gh pr checks --watch` を使わない。** 最大10分ブロックしてループが止まる。
各イテレーションの冒頭で非ブロッキングに確認し、pending なら次のタスクへ進む。
worktree 2枠で PR を常時2本 in-flight に保てる。

**Issue は明示的に閉じる。** `resolve #N` の自動クローズは
デフォルトブランチへのマージでしか発火しない。統合ブランチ運用では効かない。

**指示は author で絞る。** public リポジトリでは Discussion / Issue / PR に
誰でもコメントできる。「本文だけ読む」にすると決定（コメント欄に書かれる）を
取りこぼすので、**author で判定する**。信用する author は playbook に
`{{TRUSTED_AUTHORS}}` としてリストで書き、共同開発者が増えたら追記する。
リポジトリの collaborator から自動で導出しない — 招待した瞬間に自律ループへの
指示権限が付く形になるため、増やす操作は明示的な判断であるべき。
信用外 author のコメントは**黙殺せず** state に記録し、人間が判断できるようにする。

**スラッシュコマンドを経由しない。** プラグインのコマンドは名前空間付きで
解決が不安定なうえ、`/hooks` に Stop hook が表示されないため状態を誤認しやすい。
`ralph-start.sh` が state ファイルを直接書く方式なら、これらに依存しない。
`session_id` を空にすると hook 側のセッション照合がスキップされる。

**Stop hook は作業ディレクトリでループを判定する。** hook は、その時点の作業ディレクトリにある
`.claude/ralph-loop.local.md` を探す。また `session_id` が空なので、どのセッションのものかは区別しない。そのため次の 2 つに注意する。
- ループの Claude がスロットに `cd` したままターンを終えると、ループが無いと判断され、**エラーも出さずに止まる**。
  playbook では、スロットでの操作を `git -C` とサブシェルに限り、ターンの終わりに作業ディレクトリを確認させている
- **制御用 worktree の中で、別の Claude Code セッションを開かない（`cd` もしない）。** そのセッションも
  ループ本体として Stop hook に捕まり、ループの指示を受け取ってしまう

**マージ条件は「全 CI が pass」＋「CodeRabbit の未対応指摘なし」＋「未回答の `ask` なし」。**
CI の無いリポジトリでは「全 CI が pass」の代わりに「PR の最新コミットでローカル検証が通った記録がある」を使う。ただし、CodeRabbit のレビューが投稿されるまではマージしない。
CodeRabbit の指摘はコードレビューとして対応し、各コメントに返信する。
自分が `ask` を残した PR は**マージせず保留**し、回答が付くまで待つ。
ただし保留中の PR がスロットを占有すると前に進めなくなるため、
**スロットは解放して state の「回答待ち」へ移す**。

**マージを止める `ask` は「epic にマージした時点で手遅れになるもの」に絞る。**
epic → develop の最終 PR で人間のレビューは必ず入るので、子 PR ごとに止めると
同じ確認を2回することになる。ninjacord-ios では ask の大半が「既定値で進めても後から直せる判断」か
「実機での確認依頼」で、1件ずつ回答するまで後続が止まり、人間がボトルネックになっていた。
セルフレビューのコメントは次の3種類に分ける。

| 種類 | 条件 | マージ | 行き先 |
| --- | --- | --- | --- |
| `ask` | 後から戻せない / App Store Connect などリポジトリ外の作業が必須 / 決定事項と矛盾 / 後続タスクの前提が変わる | 止める | PR コメントで回答を待つ |
| `decision` | 既定値で進めても後から安く直せる判断 | 止めない | epic ごとの判断ログ Issue に集約 |
| 実機確認 | 実機・実データでしか確かめられない | 止めない | 個別の Issue に起票し、PR には memo で起票した旨を書く |

判断ログ Issue は、人間が都合のよいときにまとめて見る。チェックを付ければ承認、
コメントで別案を指示すればループが修正タスクとして積んで epic 内で直す。
**返答のない decision は既定値のまま確定**し、promise を出す前に state の
「最終 PR に載せる内容」へ一覧で書き出される。承認・変更された判断はゴールファイルの
決定事項に書き戻されるので、次の epic へ持ち越せば同じ種類の判断で止まらない。

**deny リストは制御用 worktree の `.claude/settings.json` に置き、リポジトリにはコミットしない。**
`settings.local.json` は個人の上書き用で gitignore される前提のファイルであり、
Claude Code が権限承認を自動追記するため、deny がそこに同居すると失われうる。
一方でリポジトリにコミットすると、`gh pr create --base <base>` の deny が
通常開発の PR 作成まで塞ぐ。制御用 worktree に置けば、ループにだけ効く。

**`max_iterations: 0`（無制限）で回すなら、詰まりを扱えること。**
promise は完全一致でしか成立せず「詰まった」を表現できないため、
着手不能なタスクがあると無限ループになる。playbook の「詰まったときの扱い」で
タスクを**保留として閉じられる**ようにし、無進捗が続いたら自分で停止させる。
`ralph-start.sh` はこの節が playbook に無いと 0 での起動を拒否する。

## AskHub・オーケストレーターとの連携

[AskHub](https://github.com/shilokuma-inc/ask-hub-apple) は、人間の判断が要るものだけを集めて iPhone / Mac から回答する受信箱アプリ。
家の Mac に常駐するオーケストレーター（`askhub-orchestrator`）が回答を見て、このループを自動で起動・再開し、最終 PR を作る。
手で `ralph-start.sh` を叩く運用から、次の流れに置き換わる。

| きっかけ | 自動で起きること |
| --- | --- |
| Discussion の質問に回答して「確定」（`ready-for-loop`） | 起動スクリプト（`askhub-start-loop`）が goal を作り、`ralph-setup.sh` → `ralph-start.sh` → ループを起動 |
| PR の ask に回答（`needs-answer`） | 止まっていたループを再開 |
| 全タスク完了 | オーケストレーターが epic → develop の最終 PR（`epic-final`）を作る |
| 最終 PR を develop にマージ | ワークフロー（`close-goal-discussion.yml`）が、ゴール元の Discussion を解決済みで閉じる |

**このテンプレートの側で守ること**（形式の正本は ask-hub-apple の `docs/protocol.md`）:

- ask のコメントは質問の目印（`<!-- ask-hub:question id="…" options="…" -->`）で始め、PR に `needs-answer` を付ける。
  目印が無い ask は AskHub に届かず、回答してもループが再開しない
- 判断ログ Issue には `decision-log`、実機確認 Issue には `needs-verify` を付ける（AskHub の「急がない」に出る）
- 最終 PR はループで作らない。オーケストレーターが「最終 PR に載せる内容」を読んで作る
- 不足しているプロトコルのラベルは `ralph-setup.sh` が作る

セットアップ（Mac ごとの手順・設定ファイル）は ask-hub-apple の `docs/orchestrator.md` を参照。

### 手で回す（manual-loop）

担当 PC のオーケストレーターに任せず、別の PC などから手でループを回すときは、ゴール元の Discussion に
ラベル `manual-loop` を付ける（ask-hub-apple の Discussion #273）。AskHub の回答画面で、最後の質問を
「投稿したら、回答を確定してループを始める」の回し方「手動で回す」で投稿すると付く。GitHub で手で付けてもよい。
**GitHub で手で付けるときは、最後の質問に回答する前に付ける。** 全問回答した時点で `manual-loop` が無いと、
オーケストレーターが `ready-for-loop` を付けて自動で起動することがある。
ラベル `manual-loop` は `ralph-setup.sh` が作る（AskHub も「手動で回す」で投稿するときに無ければ作る）。
セットアップ前で無いときは、`gh label create manual-loop --color C5DEF5 --description 'この Discussion のループは手で回す（オーケストレーターは起動しない）'` で作る。
**信用する author の Discussion に付いたときだけ効く。**

`manual-loop` の付いた Discussion について、オーケストレーターは次のように動く:

- 全問回答でも `ready-for-loop` を付けない（`needs-answer` だけ外す）。`ready-for-loop` が付いていても起動しない
- Discussion が open なあいだ（最終 PR のマージで閉じられるまで）、**同じリポジトリのほかの Discussion も自動で起動しない**（1 リポジトリにつきループは 1 つ）
- loop-status は、手で回すループが書く（下記）。オーケストレーターは、書き手が手動で `checkedAt` が 30 分以内のあいだは書かない
- 最終 PR のコンフリクトの解消は今までどおり行う（`epic-final` の PR を見ているだけなので）

依頼の形式（CLAUDE.md の依頼の形式の末尾に「手動で回して」を付ける）:

```
<リポジトリ> で epic/<機能名> のループを回したい。ゴールは Discussion #N。手動で回して
```

AskHub の回答画面で「手動で回す」を選んで投稿すると、この形式の指示（リポジトリと Discussion の番号を埋めたもの）をコピーできる。

手順は通常の起動（`ralph-setup.sh` → playbook を埋める → `ralph-start.sh`）と同じで、次を足す。
ask・判断ログ（`decision-log`）・実機確認（`needs-verify`）の書き方は今のプロトコルのまま（AskHub の受信箱でそのまま扱える）。

1. **始めるときに `ready-for-loop` を外す**（付いていれば）。Discussion のラベルは REST で外せないので GraphQL を使う:
   ```bash
   owner=OWNER repo=REPO number=DISCUSSION_NUMBER   # ゴール元の Discussion に合わせて置き換える
   ids=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){
     discussion(number:$n){ id } label(name:"ready-for-loop"){ id } } }' \
     -f o="$owner" -f r="$repo" -F n="$number" --jq '.data.repository | "\(.discussion.id) \(.label.id)"')
   read -r discussion label <<<"$ids"
   gh api graphql -f query='mutation($d:ID!,$l:ID!){ removeLabelsFromLabelable(input:{labelableId:$d,labelIds:[$l]}){ clientMutationId } }' \
     -f d="$discussion" -f l="$label"
   ```
2. **loop-status を書き手 `manual` で書く**。リポジトリの状態用の Issue（ラベル `loop-status`）の本文の先頭に、目印を置く。
   使う Issue はオーケストレーターと同じ選び方で決める（タイトルでは選ばない）。信用する author が作ったもののうち、
   open なものがあればその中で最も新しく更新されたもの、無ければ閉じたもののうち最も新しく更新されたものを開き直して使う。
   信用する author の Issue が 1 つも無いときだけ、**信用する author のアカウントで**、ラベル `loop-status`・タイトル `【AskHub】ループの状態` で作る
   （信用する author 以外が作った Issue は、オーケストレーターにもアプリにも読まれない。ラベルが無ければ、先に
   `gh label create loop-status --color BFDADC --description 'AskHub のオーケストレーターがループの状態を書き出す Issue'` で作る）:
   ```html
   <!-- ask-hub:loop-status {"checkedAt":"CHECKED_AT","discussion":DISCUSSION_NUMBER,"epic":"epic/FEATURE_NAME","progress":{"completed":COMPLETED,"total":TOTAL},"state":"running","writer":"manual"} -->
   ```
   大文字の値は置き換える。`CHECKED_AT` は書き込む時点の UTC 時刻（`date -u +%Y-%m-%dT%H:%M:%SZ` の出力）、
   `DISCUSSION_NUMBER` はゴール元の Discussion の番号、`COMPLETED` / `TOTAL` は完了したタスクの数と全タスクの数。
   例の値をそのまま貼らない（未来の時刻を書くと、ループが止まってもオーケストレーターの引き継ぎがその分遅れる）。
   形式は ask-hub-apple の `docs/protocol.md` の「ループの状態」（時刻は秒までの ISO 8601・UTC。ローカルパスや PC 名は書かない）。
   状態・epic・進捗が変わったら書き換え、変わらなくても **10 分ごとに `checkedAt` を書き直す**（playbook の STEP D で、
   前回から 10 分たっていれば書き直す、と書いておく）。書き手が `manual` の `checkedAt` が 30 分より古くなると、オーケストレーターが書き直す
3. **最終 PR はループ（または人間）が `epic-final` を付けて作る**。オーケストレーターは手で回す制御用 worktree を見られないので作らない。
   本文は state の「最終 PR に載せる内容」を使い、**先頭に次の 2 行を入れる**（`N` はゴール元の Discussion の番号）。
   マージ後に `close-goal-discussion.yml` が本文の 1 行目と 2 行目でゴール元の Discussion を特定するので、
   この 2 行が無い・番号が一致しないと Discussion が閉じない:
   ```text
   ゴール元: Discussion #N
   <!-- ask-hub:discussion N -->
   ```
   ```bash
   epic=epic/FEATURE_NAME body=final-pr-body.md   # epic のブランチ（置き換える）と、最終 PR の本文を書いたファイル
   gh pr create --base develop --head "$epic" --title '【FEAT】…' --assignee @me --label epic-final --body-file "$body"
   ```
   制御用 worktree の `.claude/settings.json` の deny は `gh pr create --base develop` を塞ぐ（通常のループが最終 PR を作らないため）。
   **手で回すときは、制御用 worktree の外（メインの checkout や別のセッション）から作るか、人間が作る。**
   deny が塞ぐのは制御用 worktree の settings.json だけなので、ほかの場所では通常どおり作れる。
   マージ後は今までどおり、ワークフローがゴール元の Discussion を閉じ、オーケストレーターが判断ログを閉じる

## ループに向かないタスク

判定基準は**自動検証器があるか**。lint とビルドで正しさを担保できないものは向かない。

| 種類 | 理由 |
| --- | --- |
| 新規ターゲット追加（App Extension / Widget / App Intents） | `.xcodeproj` と Provisioning Profile、CI の書き換えに波及する |
| StoreKit の実機・Sandbox 検証 | `.storekit` は Xcode から起動したときだけ適用される。`simctl` では効かない |
| 多言語の訳文品質 | 生成した訳を検証できない |
| 外部コンソール作業（App Store Connect / 広告管理画面） | リポジトリ外 |
| UI の見た目・文言の妥当性 | ビルドが通ることと正しく見えることは別 |

ゴールファイルの「対象外」に明示して着手させないこと。

## 実績

`ninjacord-ios` で Phase 0〜2 を実装。**33 本の PR を生成し v2.0.0 として develop にマージ済み。**
1タスクあたりのイテレーション数は、立ち上がりで約2.5、パイプラインが埋まった定常状態で
**約1.2**（ほぼ毎周1タスク進む）。2枠のスロットで、モデルが CI 待ちで遊ぶ時間をほぼ埋められていた。
