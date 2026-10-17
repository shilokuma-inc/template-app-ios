#!/usr/bin/env ruby
# frozen_string_literal: true

#
# TestFlight の内部テストグループを用意し、指定したメールアドレスの人を内部テスターに入れる。
# 何度実行しても同じ結果になる（グループやテスターが既にあれば何もしない）。
#
# グループは「すべてのビルドへのアクセス」を有効にして作るため、以降アップロードしたビルドは
# 処理が終わりしだい自動でテスターに配信される。ビルドごとにグループへ追加する必要はない。
#
# 内部テスターになれるのは App Store Connect のユーザー（チームのメンバー）だけ。
# メンバーでないメールアドレスは追加に失敗するので、その旨を表示する。
#
# 使い方（環境変数で渡す）:
#   BUNDLE_ID=jp.shilokuma.MyApp TESTERS='me@example.com, you@example.com' \
#   API_KEY_PATH=AuthKey_XXXXXXXXXX.p8 APPLE_API_KEY_ID=XXXXXXXXXX APPLE_API_ISSUER_ID=xxxxxxxx-... \
#   ruby .github/scripts/ensure-internal-testers.rb
#
#   GROUP_NAME を渡すとグループ名を変えられる（既定は Internal Testers）。
#   TESTERS が空なら何もせずに終わる。
#
# GITHUB_STEP_SUMMARY が設定されていれば（GitHub Actions 上）、結果を Job Summary にも書き出す。
#
# Ruby の標準ライブラリだけで動く（gem のインストールは不要）。API の共通処理は app_store_connect.rb にある。

require_relative 'app_store_connect'

ASC = AppStoreConnect

def find_internal_group(app_id:, name:, token:)
  json = ASC.request(:get, '/v1/betaGroups', token: token, query: {
                       'filter[app]' => app_id,
                       'filter[isInternalGroup]' => 'true',
                       'fields[betaGroups]' => 'name,isInternalGroup,hasAccessToAllBuilds',
                       'limit' => 200
                     })
  json.fetch('data').find { |group| group.dig('attributes', 'name') == name }
end

def create_internal_group(app_id:, name:, token:)
  body = {
    data: {
      type: 'betaGroups',
      attributes: { name: name, isInternalGroup: true, hasAccessToAllBuilds: true },
      relationships: { app: { data: { type: 'apps', id: app_id } } }
    }
  }
  ASC.request(:post, '/v1/betaGroups', token: token, body: body).fetch('data')
end

def group_tester_emails(group_id:, token:)
  json = ASC.request(:get, "/v1/betaGroups/#{group_id}/betaTesters", token: token,
                                                                     query: { 'fields[betaTesters]' => 'email', 'limit' => 200 })
  json.fetch('data').map { |tester| tester.dig('attributes', 'email').to_s.downcase }
end

# 他のアプリで既にテスターになっている人は、新しく作らずに既存のテスターをグループに入れる
def add_tester(email:, group_id:, token:)
  existing = ASC.request(:get, '/v1/betaTesters', token: token,
                                                  query: { 'filter[email]' => email, 'fields[betaTesters]' => 'email', 'limit' => 200 })
                .fetch('data')
                .find { |tester| tester.dig('attributes', 'email').to_s.casecmp?(email) }

  if existing
    ASC.request(:post, "/v1/betaGroups/#{group_id}/relationships/betaTesters", token: token,
                                                                               body: { data: [{ type: 'betaTesters', id: existing.fetch('id') }] })
  else
    body = {
      data: {
        type: 'betaTesters',
        attributes: { email: email },
        relationships: { betaGroups: { data: [{ type: 'betaGroups', id: group_id }] } }
      }
    }
    ASC.request(:post, '/v1/betaTesters', token: token, body: body)
  end
end

bundle_id = ASC.env!('BUNDLE_ID')
group_name = ENV.fetch('GROUP_NAME', '').then { |name| name.empty? ? 'Internal Testers' : name }
emails = ENV.fetch('TESTERS', '').split(/[\s,]+/).reject(&:empty?).uniq(&:downcase)

if emails.empty?
  puts '::notice::TESTERS が空のため、TestFlight の内部テスターの設定を省きます'
  exit 0
end

token = ASC.token_from_env
failures = []
lines = []

begin
  app = ASC.find_app(bundle_id: bundle_id, token: token)
  abort "::error::App Store Connect に #{bundle_id} のアプリがありません" unless app

  group = find_internal_group(app_id: app.fetch('id'), name: group_name, token: token)
  if group
    lines << "- 内部テストグループ「#{group_name}」は作成済みです"
  else
    group = create_internal_group(app_id: app.fetch('id'), name: group_name, token: token)
    lines << "- 内部テストグループ「#{group_name}」を作成しました（すべてのビルドを自動で配信）"
  end

  current = group_tester_emails(group_id: group.fetch('id'), token: token)
  emails.each do |email|
    if current.include?(email.downcase)
      lines << "- #{email} は追加済みです"
      next
    end

    begin
      add_tester(email: email, group_id: group.fetch('id'), token: token)
      lines << "- #{email} を追加しました"
    rescue ASC::Error => e
      failures << email
      lines << "- #{email} を追加できませんでした（HTTP #{e.status}）。App Store Connect の「ユーザとアクセス」に登録されているメールアドレスか確認してください"
      puts e.message
    end
  end
rescue ASC::Error => e
  abort "::error::#{e.message}"
end

summary = "## TestFlight の内部テスター\n\n#{lines.join("\n")}"
puts summary
ASC.write_summary(summary)

unless failures.empty?
  puts "::error::内部テスターに追加できなかったメールアドレスがあります: #{failures.join(', ')}"
  exit 1
end
