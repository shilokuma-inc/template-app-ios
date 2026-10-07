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
# Ruby の標準ライブラリだけで動く（gem のインストールは不要）。

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

def env!(name)
  value = ENV.fetch(name, '')
  abort "環境変数 #{name} が設定されていません" if value.empty?
  value
end

def base64url(data)
  Base64.urlsafe_encode64(data, padding: false)
end

# App Store Connect API の認証に使う JWT（ES256）を作る
# https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests
def make_token(key_path:, key_id:, issuer_id:)
  key = OpenSSL::PKey::EC.new(File.read(key_path))
  now = Time.now.to_i
  header = { alg: 'ES256', kid: key_id, typ: 'JWT' }
  payload = { iss: issuer_id, iat: now, exp: now + (10 * 60), aud: 'appstoreconnect-v1' }
  signing_input = "#{base64url(header.to_json)}.#{base64url(payload.to_json)}"

  # OpenSSL の署名は DER 形式なので、JWT が求める r || s（各 32 バイト）に変換する
  der = key.sign(OpenSSL::Digest.new('SHA256'), signing_input)
  r, s = OpenSSL::ASN1.decode(der).value.map { |n| n.value.to_s(2).rjust(32, "\x00") }
  "#{signing_input}.#{base64url(r + s)}"
end

def find_app(bundle_id:, token:)
  uri = URI('https://api.appstoreconnect.apple.com/v1/apps')
  uri.query = URI.encode_www_form('filter[bundleId]' => bundle_id, 'fields[apps]' => 'name,bundleId,sku')
  request = Net::HTTP::Get.new(uri)
  request['Authorization'] = "Bearer #{token}"
  # API が応答しないときにジョブのタイムアウト（45 分）まで待たないよう、接続と読み取りに上限を設ける
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    http.request(request)
  end

  unless response.is_a?(Net::HTTPSuccess)
    abort "::error::App Store Connect API の呼び出しに失敗しました（HTTP #{response.code}）\n#{response.body}"
  end

  # filter が完全一致でない場合に備えて、Bundle ID が一致するものだけを見る
  JSON.parse(response.body).fetch('data').find { |app| app.dig('attributes', 'bundleId') == bundle_id }
end

def write_summary(markdown)
  path = ENV.fetch('GITHUB_STEP_SUMMARY', '')
  File.write(path, "#{markdown}\n", mode: 'a') unless path.empty?
end

bundle_id = env!('BUNDLE_ID')
app_name = env!('APP_NAME')
token = make_token(
  key_path: env!('API_KEY_PATH'),
  key_id: env!('APPLE_API_KEY_ID'),
  issuer_id: env!('APPLE_API_ISSUER_ID')
)

app = find_app(bundle_id: bundle_id, token: token)
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
write_summary(guide)
puts "::error::App Store Connect に #{bundle_id} のアプリがありません。Job Summary の手順でアプリを作成してから再実行してください"
exit 1
