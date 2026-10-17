#!/usr/bin/env ruby
# frozen_string_literal: true

#
# App Store Connect に、指定した Bundle ID のアプリが作成済みかを確認する（読み取りのみ）。
# アプリが無い場合は「新規アプリ」画面で入力する値を表示して、終了コード 1 で終わる。
#
# App Store Connect でのアプリ作成は API で行えないため、作成そのものは Web 画面で行う。
# Bundle ID の登録は Export 時に xcodebuild（-allowProvisioningUpdates）が自動で行う。
#
# 使い方（環境変数で渡す）:
#   BUNDLE_ID=jp.shilokuma.MyApp APP_NAME=MyApp \
#   API_KEY_PATH=AuthKey_XXXXXXXXXX.p8 APPLE_API_KEY_ID=XXXXXXXXXX APPLE_API_ISSUER_ID=xxxxxxxx-... \
#   ruby .github/scripts/check-app-store-app.rb
#
# GITHUB_STEP_SUMMARY が設定されていれば（GitHub Actions 上）、結果を Job Summary にも書き出す。
#
# Ruby の標準ライブラリだけで動く（gem のインストールは不要）。API の共通処理は app_store_connect.rb にある。

require_relative 'app_store_connect'

bundle_id = AppStoreConnect.env!('BUNDLE_ID')
app_name = AppStoreConnect.env!('APP_NAME')
token = AppStoreConnect.token_from_env

begin
  app = AppStoreConnect.find_app(bundle_id: bundle_id, token: token)
rescue AppStoreConnect::Error => e
  abort "::error::#{e.message}"
end

if app
  attributes = app.fetch('attributes')
  puts "App Store Connect にアプリがあります: #{attributes['name']}（#{bundle_id}、SKU: #{attributes['sku']}）"
  exit 0
end

# SKU はユーザーに見えない社内用の ID で、後から変更できない。迷わないよう Bundle ID と同じ値にする
guide = <<~MARKDOWN
  ## App Store Connect にアプリがありません

  Bundle ID `#{bundle_id}` のアプリが App Store Connect にまだ作られていないため、アップロードできません。
  [App Store Connect のアプリ一覧](https://appstoreconnect.apple.com/apps) を開き、「＋」→「新規アプリ」に以下を入力して作成してから、このワークフローを再実行してください。

  | 項目 | 入力する値 |
  | --- | --- |
  | プラットフォーム | iOS |
  | 名前 | #{app_name}（App Store 全体で使用済みの名前は使えません。その場合は別の名前にします） |
  | プライマリ言語 | 日本語 |
  | バンドル ID | #{bundle_id} |
  | SKU | #{bundle_id} |
  | ユーザアクセス | フルアクセス |

  - SKU はユーザーには見えない社内用の ID で、後から変更できません。迷わないよう Bundle ID と同じ値にしています
  - バンドル ID の候補に出てこない場合は、Developer Portal への登録がまだです。このワークフローの Export が一度成功すると登録されます
MARKDOWN

puts guide
AppStoreConnect.write_summary(guide)
puts "::error::App Store Connect に #{bundle_id} のアプリがありません。Job Summary の手順でアプリを作成してから再実行してください"
exit 1
