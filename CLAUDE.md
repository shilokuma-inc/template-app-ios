# IOSTemplateApp

## 全員向けの事実

<!-- AskHub のワーカーの Claude にも渡す、このリポジトリの事実（アプリの作り・決まり・ビルドで気をつけること）を書く。
     AskHub はこの節があればこの節だけを、無ければ CLAUDE.md 全体を Claude に渡す -->

- CI・リリースのワークフローは、共通リポジトリ [shilokuma-inc/app-kit](https://github.com/shilokuma-inc/app-kit) の再利用ワークフローを呼ぶ。`.github/workflows/` の呼ぶ側のファイルと SwiftLint・CodeRabbit の設定は app-kit が配るので、ここでは直さない。リポジトリごとの値は `.github/app-kit.json` に書く

## 人のセッション向けの手順

<!-- 人の Claude Code のセッションだけが使う手順を書く -->
