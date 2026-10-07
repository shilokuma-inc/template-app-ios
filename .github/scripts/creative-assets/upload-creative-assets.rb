#!/usr/bin/env ruby
# frozen_string_literal: true

#
# App Store Connect API（App Asset Library）で、クリエイティブアセットの画像をアップロードする試験用スクリプト。
#
#   1. Bundle ID からアプリを探し、App Store バージョンの一覧と状態を出す
#   2. アプリの Asset Library と、ヘッダー / 検索結果向けの仕様（reference data）を取得して出す
#   3. ASSET_DIR の画像を CREATIVE_ASSETS として Asset Library にアップロードし、処理完了まで待つ
#   4. PLACEMENT が none 以外なら、編集できる App Store バージョンの全ローカリゼーションに配置する
#      - dedicated: ヘッダー専用の画像をヘッダーに、検索結果専用の画像を検索結果に配置する
#      - universal: 兼用（universalAsset）の画像をヘッダーと検索結果の両方に配置する
#      同じ種類・グループに配置済みのものがあれば削除してから配置し直す（各グループの上限は 1 件のため）
#
# 審査への提出は行わない。
#
# 使い方（環境変数で渡す）:
#   BUNDLE_ID=jp.shilokuma.MyApp ASSET_DIR=path/to/images PLACEMENT=none \
#   API_KEY_PATH=AuthKey_XXXXXXXXXX.p8 APPLE_API_KEY_ID=XXXXXXXXXX APPLE_API_ISSUER_ID=xxxxxxxx-... \
#   OUTPUT_DIR=path/to/output \
#   ruby .github/scripts/creative-assets/upload-creative-assets.rb
#
# OUTPUT_DIR には API のレスポンス（reference data など）を JSON で書き出す。
# GITHUB_STEP_SUMMARY が設定されていれば（GitHub Actions 上）、結果を Job Summary にも書き出す。
#
# 参考:
#   https://developer.apple.com/documentation/appstoreconnectapi/app-asset-library
#   https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets
#
# Ruby の標準ライブラリだけで動く（gem のインストールは不要）。

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

API_BASE = 'https://api.appstoreconnect.apple.com'
HEADER = 'PRODUCT_PAGE_HEADER_ASSET'
SEARCH_RESULTS = 'APP_STORE_SEARCH_RESULTS_ASSET'
PLACEMENT_TYPES = [HEADER, SEARCH_RESULTS].freeze
# 配置を追加できる（審査に出す前・却下後の）バージョンの状態
EDITABLE_VERSION_STATES = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY].freeze
PROCESSING_TIMEOUT = 15 * 60

def env!(name)
  value = ENV.fetch(name, '')
  abort "環境変数 #{name} が設定されていません" if value.empty?
  value
end

def base64url(data)
  Base64.urlsafe_encode64(data, padding: false)
end

def summary(markdown)
  puts markdown
  path = ENV.fetch('GITHUB_STEP_SUMMARY', '')
  File.write(path, "#{markdown}\n", mode: 'a') unless path.empty?
end

def save_json(name, data)
  File.write(File.join(OUTPUT_DIR, name), JSON.pretty_generate(data))
end

class ApiError < StandardError; end

# App Store Connect API の薄いクライアント。処理待ちで 10 分を超えることがあるため、JWT はリクエストごとに作り直す
class Client
  def initialize(key_path:, key_id:, issuer_id:)
    @key = OpenSSL::PKey::EC.new(File.read(key_path))
    @key_id = key_id
    @issuer_id = issuer_id
  end

  def get(path, query = {})
    request(Net::HTTP::Get, path, query: query)
  end

  def post(path, body)
    request(Net::HTTP::Post, path, body: body)
  end

  def patch(path, body)
    request(Net::HTTP::Patch, path, body: body)
  end

  def delete(path)
    request(Net::HTTP::Delete, path)
  end

  private

  # https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests
  def token
    now = Time.now.to_i
    header = { alg: 'ES256', kid: @key_id, typ: 'JWT' }
    payload = { iss: @issuer_id, iat: now, exp: now + (10 * 60), aud: 'appstoreconnect-v1' }
    signing_input = "#{base64url(header.to_json)}.#{base64url(payload.to_json)}"
    # OpenSSL の署名は DER 形式なので、JWT が求める r || s（各 32 バイト）に変換する
    der = @key.sign(OpenSSL::Digest.new('SHA256'), signing_input)
    r, s = OpenSSL::ASN1.decode(der).value.map { |n| n.value.to_s(2).rjust(32, "\x00") }
    "#{signing_input}.#{base64url(r + s)}"
  end

  def request(klass, path, query: {}, body: nil)
    uri = URI("#{API_BASE}#{path}")
    uri.query = URI.encode_www_form(query) unless query.empty?
    req = klass.new(uri)
    req['Authorization'] = "Bearer #{token}"
    if body
      req['Content-Type'] = 'application/json'
      req.body = body.to_json
    end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    # 日本語のメッセージと連結するため、レスポンスは UTF-8 として扱う
    res.body&.force_encoding(Encoding::UTF_8)
    raise ApiError, "#{klass::METHOD} #{path} が失敗しました（HTTP #{res.code}）\n#{res.body}" unless res.is_a?(Net::HTTPSuccess)

    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end
end

def find_app(client, bundle_id)
  data = client.get('/v1/apps', 'filter[bundleId]' => bundle_id, 'fields[apps]' => 'name,bundleId,sku').fetch('data')
  # filter が完全一致でない場合に備えて、Bundle ID が一致するものだけを見る
  data.find { |app| app.dig('attributes', 'bundleId') == bundle_id }
end

def list_versions(client, app_id)
  client.get(
    "/v1/apps/#{app_id}/appStoreVersions",
    'filter[platform]' => 'IOS',
    'fields[appStoreVersions]' => 'versionString,appVersionState,appStoreState,createdDate',
    'limit' => '20'
  ).fetch('data')
end

def report_versions(versions)
  rows = versions.map do |v|
    a = v['attributes']
    "| #{a['versionString']} | #{a['appVersionState'] || '-'} | #{a['appStoreState'] || '-'} | `#{v['id']}` |"
  end
  summary(<<~MARKDOWN)
    ### App Store バージョン（iOS）

    | バージョン | appVersionState | appStoreState | ID |
    | --- | --- | --- | --- |
    #{rows.empty? ? '| （なし） | | | |' : rows.join("\n")}
  MARKDOWN
end

def report_ref_data(ref)
  specs = ref.fetch('imageSpecs', []).select { |s| (s['compatiblePlacementTypes'] & PLACEMENT_TYPES).any? }
  spec_rows = specs.map do |s|
    d = s['dimensions']
    size = d['minWidth'] == d['maxWidth'] ? "#{d['minWidth']}x#{d['minHeight']}" : "#{d['minWidth']}x#{d['minHeight']}〜#{d['maxWidth']}x#{d['maxHeight']}"
    "| #{s['shortName']} | #{s['aspectRatio']} | #{size} | #{s['fileExtensions'].join(' ')} | #{s['alphaAllowed']} | " \
      "#{s['universalAsset']} | #{s['compatiblePlacementTypes'].join('<br>')} |"
  end

  group_rows = ref.fetch('placementTypes', []).select { |t| PLACEMENT_TYPES.include?(t['placementTypeId']) }.flat_map do |t|
    t['specMappings'].map do |m|
      names = m['specs'].map { |id| ref['imageSpecs'].find { |s| s['specId'] == id }&.dig('shortName') || id }
      "| #{t['placementTypeId']} | #{m['placementGroupId']} | #{names.join('<br>')} |"
    end
  end

  limit_rows = ref.fetch('features', []).flat_map do |f|
    f['placementPolicies'].select { |p| PLACEMENT_TYPES.include?(p['placementType']) }.flat_map do |p|
      p['groupLimits'].map { |l| "| #{f['featureId']} | #{p['placementType']} | #{l['groupIds'].join('<br>')} | #{l['maxCount']} |" }
    end
  end

  summary(<<~MARKDOWN)
    ### ヘッダー / 検索結果で使える画像の仕様（reference data）

    | shortName | 比率 | サイズ | 拡張子 | alpha | universal | 使える配置 |
    | --- | --- | --- | --- | --- | --- | --- |
    #{spec_rows.join("\n")}

    ### 配置グループと受け付ける仕様

    | placementType | placementGroup | 仕様 |
    | --- | --- | --- |
    #{group_rows.join("\n")}

    ### 配置できる場所と上限

    | feature | placementType | placementGroup | 上限 |
    | --- | --- | --- | --- |
    #{limit_rows.join("\n")}
  MARKDOWN
end

def upload_image(client, library_id, path)
  file_name = File.basename(path)
  bytes = File.binread(path)
  reservation = client.post('/v1/appAssetLibraryImages', {
    data: {
      type: 'appAssetLibraryImages',
      attributes: {
        fileName: file_name,
        fileSize: bytes.bytesize,
        category: 'CREATIVE_ASSETS',
        referenceName: "#{File.basename(file_name, '.*')} (#{Time.now.utc.strftime('%Y-%m-%d %H:%M')} UTC)"
      },
      relationships: { assetLibrary: { data: { type: 'appAssetLibraries', id: library_id } } }
    }
  }).fetch('data')
  image_id = reservation['id']
  puts "予約しました: #{file_name}（#{image_id}）"

  # アップロード先の URL は認証不要・期限付きのため、JWT は付けない
  reservation.dig('attributes', 'uploadOperations').each do |op|
    uri = URI(op['url'])
    req = Net::HTTPGenericRequest.new(op['method'], true, true, uri)
    op['requestHeaders'].each { |h| req[h['name']] = h['value'] }
    req.body = bytes.byteslice(op['offset'], op['length'])
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    raise ApiError, "#{file_name} のアップロードに失敗しました（HTTP #{res.code}）\n#{res.body}" unless res.is_a?(Net::HTTPSuccess)
  end

  client.patch("/v1/appAssetLibraryImages/#{image_id}", {
    data: { type: 'appAssetLibraryImages', id: image_id, attributes: { uploaded: true } }
  })
  puts "コミットしました: #{file_name}。処理の完了を待ちます"

  deadline = Time.now + PROCESSING_TIMEOUT
  loop do
    image = client.get("/v1/appAssetLibraryImages/#{image_id}").fetch('data')
    state = image.dig('attributes', 'state')
    return image unless %w[AWAITING_UPLOAD UPLOAD_COMPLETE].include?(state)
    raise ApiError, "#{file_name} の処理が #{PROCESSING_TIMEOUT / 60} 分で終わりませんでした（state: #{state}）" if Time.now > deadline

    sleep 10
  end
end

def report_images(images, ref)
  rows = images.map do |path, image|
    a = image['attributes']
    spec = ref['imageSpecs'].find { |s| s['specId'] == a['specId'] }
    details = a['stateDetails'] ? "<br>#{a['stateDetails'].to_json}" : ''
    "| #{File.basename(path)} | #{a['state']}#{details} | #{spec&.dig('shortName') || a['specId'] || '-'} | " \
      "#{spec ? spec['compatiblePlacementTypes'].join('<br>') : '-'} | `#{image['id']}` |"
  end
  summary(<<~MARKDOWN)
    ### Asset Library へのアップロード結果

    | ファイル | state | 一致した仕様 | 使える配置 | ID |
    | --- | --- | --- | --- | --- |
    #{rows.join("\n")}
  MARKDOWN
end

# PLACEMENT の指定に合わせて、配置の種類ごとに使う画像を選ぶ
def choose_assets(placement, images, ref)
  ready = images.values.select { |i| i.dig('attributes', 'state') == 'PREPARE_FOR_SUBMISSION' }
  spec_of = ->(image) { ref['imageSpecs'].find { |s| s['specId'] == image.dig('attributes', 'specId') } }
  PLACEMENT_TYPES.to_h do |type|
    candidates = ready.select do |image|
      spec = spec_of.call(image)
      spec && spec['compatiblePlacementTypes'].include?(type) && spec['universalAsset'] == (placement == 'universal')
    end
    [type, candidates.first]
  end
end

def place_assets(client, version, assets, ref)
  localizations = client.get(
    "/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations",
    'fields[appStoreVersionLocalizations]' => 'locale'
  ).fetch('data')
  mappings = ref['placementTypes'].to_h { |t| [t['placementTypeId'], t['specMappings']] }

  rows = []
  localizations.each do |loc|
    locale = loc.dig('attributes', 'locale')
    assets.each do |type, image|
      next rows << "| #{locale} | #{type} | - | 使える画像がありません |" unless image

      groups = mappings.fetch(type, []).select { |m| m['specs'].include?(image.dig('attributes', 'specId')) }
      next rows << "| #{locale} | #{type} | - | 画像の仕様を受け付けるグループがありません |" if groups.empty?

      groups.each do |group|
        group_id = group['placementGroupId']
        begin
          existing = client.get(
            "/v1/appStoreVersionLocalizations/#{loc['id']}/placements",
            'filter[placementType]' => type, 'filter[placementGroup]' => group_id
          ).fetch('data')
          existing.each { |p| client.delete("/v1/appAssetLibraryPlacements/#{p['id']}") }

          placement = client.post('/v1/appAssetLibraryPlacements', {
            data: {
              type: 'appAssetLibraryPlacements',
              attributes: { placementType: type, placementGroup: group_id },
              relationships: {
                image: { data: { type: 'appAssetLibraryImages', id: image['id'] } },
                appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: loc['id'] } }
              }
            }
          }).fetch('data')
          replaced = existing.empty? ? '' : "（既存の #{existing.size} 件を置き換え）"
          rows << "| #{locale} | #{type} | #{group_id} | #{placement.dig('attributes', 'state')}#{replaced} |"
        rescue ApiError => e
          rows << "| #{locale} | #{type} | #{group_id} | 失敗: #{e.message.lines.last&.strip&.slice(0, 300)} |"
        end
      end
    end
  end

  summary(<<~MARKDOWN)
    ### 配置結果（バージョン #{version.dig('attributes', 'versionString')}）

    | ロケール | placementType | placementGroup | 結果 |
    | --- | --- | --- | --- |
    #{rows.join("\n")}
  MARKDOWN
  rows.none? { |r| r.include?('失敗') }
end

bundle_id = env!('BUNDLE_ID')
asset_dir = env!('ASSET_DIR')
placement = ENV.fetch('PLACEMENT', 'none')
abort "PLACEMENT は none / dedicated / universal のいずれかを指定してください（#{placement}）" unless %w[none dedicated universal].include?(placement)
OUTPUT_DIR = env!('OUTPUT_DIR')
Dir.mkdir(OUTPUT_DIR) unless Dir.exist?(OUTPUT_DIR)
client = Client.new(key_path: env!('API_KEY_PATH'), key_id: env!('APPLE_API_KEY_ID'), issuer_id: env!('APPLE_API_ISSUER_ID'))

begin
  summary("## クリエイティブアセットのアップロード（#{bundle_id}）\n")

  app = find_app(client, bundle_id)
  unless app
    summary("Bundle ID `#{bundle_id}` のアプリが App Store Connect にありません。先に Web 画面でアプリを作成してください。")
    puts "::error::App Store Connect に #{bundle_id} のアプリがありません"
    exit 1
  end
  summary("アプリ: #{app.dig('attributes', 'name')}（ID: `#{app['id']}`）\n")

  versions = list_versions(client, app['id'])
  save_json('app-store-versions.json', versions)
  report_versions(versions)

  library = client.get("/v1/apps/#{app['id']}/assetLibrary").fetch('data')
  summary("Asset Library ID: `#{library['id']}`\n")

  ref = client.get('/v1/appAssetLibraryRefData').fetch('data').first.fetch('attributes')
  save_json('ref-data.json', ref)
  report_ref_data(ref)

  paths = Dir.glob(File.join(asset_dir, '*.{png,jpg,jpeg}')).sort
  abort "::error::#{asset_dir} に画像がありません" if paths.empty?
  images = paths.to_h { |path| [path, upload_image(client, library['id'], path)] }
  save_json('images.json', images.values)
  report_images(images, ref)
  failed = images.values.reject { |i| i.dig('attributes', 'state') == 'PREPARE_FOR_SUBMISSION' }

  if placement == 'none'
    summary("配置はしていません（PLACEMENT=none）。App Store Connect の Asset Library で画像を確認できます。\n")
  else
    version = versions.find { |v| EDITABLE_VERSION_STATES.include?(v.dig('attributes', 'appVersionState') || v.dig('attributes', 'appStoreState')) }
    if version.nil?
      summary("配置できる（審査前の）App Store バージョンがないため、配置はしていません。App Store Connect で新しいバージョンを作成してから再実行してください。\n")
      exit 1
    end
    placed = place_assets(client, version, choose_assets(placement, images, ref), ref)
    exit 1 unless placed
  end

  exit 1 unless failed.empty?
rescue ApiError => e
  summary("### エラー\n\n```\n#{e.message}\n```\n")
  puts "::error::#{e.message.lines.first.strip}"
  exit 1
end
