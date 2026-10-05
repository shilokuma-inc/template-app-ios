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
CI の無いリポジトリでは「全 CI が pass」の代わりに「PR の最新コミットでローカル検証が通った記録がある」を使う。
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
