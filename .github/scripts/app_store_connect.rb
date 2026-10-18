# frozen_string_literal: true

#
# App Store Connect API を呼ぶための共通処理。.github/scripts/ の各スクリプトから require_relative で読み込む。
# Ruby の標準ライブラリだけで動く（gem のインストールは不要）。
#

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module AppStoreConnect
  BASE_URL = 'https://api.appstoreconnect.apple.com'

  # API の呼び出しが失敗したとき（HTTP 2xx 以外）に投げる
  class Error < StandardError
    attr_reader :status, :body

    def initialize(method, path, status, body)
      @status = status
      @body = body
      super("App Store Connect API の呼び出しに失敗しました（#{method} #{path} → HTTP #{status}）\n#{body}")
    end
  end

  module_function

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

  # 環境変数（API_KEY_PATH / APPLE_API_KEY_ID / APPLE_API_ISSUER_ID）から JWT を作る
  def token_from_env
    make_token(
      key_path: env!('API_KEY_PATH'),
      key_id: env!('APPLE_API_KEY_ID'),
      issuer_id: env!('APPLE_API_ISSUER_ID')
    )
  end

  # API を呼び、レスポンスの JSON を返す（本文が無いときは nil）。2xx 以外は Error を投げる
  def request(method, path, token:, query: nil, body: nil)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(query) if query
    request = Net::HTTP.const_get(method.capitalize).new(uri)
    request['Authorization'] = "Bearer #{token}"
    if body
      request['Content-Type'] = 'application/json'
      request.body = body.to_json
    end
    # API が応答しないときにジョブのタイムアウト（45 分）まで待たないよう、接続と読み取りに上限を設ける
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.request(request)
    end

    raise Error.new(method.upcase, path, response.code, response.body) unless response.is_a?(Net::HTTPSuccess)

    response.body.to_s.empty? ? nil : JSON.parse(response.body)
  end

  # Bundle ID が一致するアプリを返す（無ければ nil）
  def find_app(bundle_id:, token:)
    json = request(:get, '/v1/apps', token: token,
                                     query: { 'filter[bundleId]' => bundle_id, 'fields[apps]' => 'name,bundleId,sku' })
    # filter が完全一致でない場合に備えて、Bundle ID が一致するものだけを見る
    json.fetch('data').find { |app| app.dig('attributes', 'bundleId') == bundle_id }
  end

  def write_summary(markdown)
    path = ENV.fetch('GITHUB_STEP_SUMMARY', '')
    File.write(path, "#{markdown}\n", mode: 'a') unless path.empty?
  end
end
