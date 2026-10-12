# ralph-loop

このリポジトリの ralph-loop（自律開発ループ）一式の正本は [shilokuma-inc/ralph-kit](https://github.com/shilokuma-inc/ralph-kit) にある。
**手順と設計の根拠は ralph-kit の `README.md` にある。ループを扱う作業の前に必ず読むこと。**
手元の場所は `scripts/ralph-kit.sh path` で分かる（表示された場所の `README.md`。playbook は `playbook.md`、goal・state の雛形は `templates/`）。

| このリポジトリのファイル | 役割 |
| --- | --- |
| `scripts/ralph-setup.sh`・`ralph-start.sh`・`ralph-stop.sh`・`askhub-manual.sh` | ralph-kit の同名のスクリプトを呼ぶ中継。使い方は ralph-kit と同じ |
| `scripts/ralph-kit.sh` | kit を取得して実行する（`path`・`version` で場所と版を表示する） |
| `.claude/ralph/kit.conf` | 使う kit の版（既定は `v1`。互換を保つ更新は、このリポジトリを変えずに届く） |
| `.github/workflows/close-goal-discussion.yml` | 最終 PR のマージでゴール元の Discussion を閉じる。本体は ralph-kit のワークフロー |

これらのファイルは ralph-kit の `install.sh` が置く。**ループの手順やスクリプトを直すときは、このリポジトリではなく ralph-kit に PR を出す**
（全リポジトリに届く）。このアプリだけの前提は、制御用 worktree の playbook の「このアプリ固有の前提」に書く。
