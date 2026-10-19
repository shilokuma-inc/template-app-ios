# IOSTemplateApp

iOS Application Template (SwiftUI)

iOS アプリのリポジトリを新規作成するときの GitHub テンプレートリポジトリです。
SwiftUI のプロジェクト一式と、ビルド・テスト・Archive・TestFlight 配信までの GitHub Actions ワークフローを含みます。

## Environment

- Xcode 26.6
- iOS 17.0 以上
- Swift 6（Swift 6 言語モード / Strict Concurrency）
- SwiftUI / Swift Testing / XCTest（UI テスト）
- SwiftLint 0.65.1（Build Tool Plugin。バイナリだけを配布する [SwiftLintPlugins](https://github.com/SimplyDanny/SwiftLintPlugins) 経由）

## Status

<div style="margin:0px;padding:0px;">
  <table width="98%" style="border-collapse: collapse;border:2px double #000080;text-align:center;margin:auto;">
    <tbody>
      <tr>
        <td style="border:2px double #000080;">branch \ workflow</td>
        <td style="border:2px double #000080;">Build</td>
        <td style="border:2px double #000080;">Archive</td>
        <td style="border:2px double #000080;">Upload</td>
      </tr>
      <tr>
        <td style="border:2px double #000080;text-align:left;">main</td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-inc/template-app-ios/actions/workflows/build.yml?query=branch%3Amain">
            <img src="https://github.com/shilokuma-inc/template-app-ios/actions/workflows/build.yml/badge.svg?branch=main" alt="Build">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-inc/template-app-ios/actions/workflows/archive.yml?query=branch%3Amain">
            <img src="https://github.com/shilokuma-inc/template-app-ios/actions/workflows/archive.yml/badge.svg?branch=main" alt="Archive">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
        </td>
      </tr>
      <tr>
        <td style="border:2px double #000080;text-align:left;">develop</td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-inc/template-app-ios/actions/workflows/build.yml?query=branch%3Adevelop">
            <img src="https://github.com/shilokuma-inc/template-app-ios/actions/workflows/build.yml/badge.svg?branch=develop" alt="Build">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
        </td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-inc/template-app-ios/actions/workflows/upload.yml?query=branch%3Adevelop">
            <img src="https://github.com/shilokuma-inc/template-app-ios/actions/workflows/upload.yml/badge.svg?branch=develop" alt="Upload">
          </a>
        </td>
      </tr>
    </tbody>
  </table>
</div>

## テンプレートの使い方

### 1. リポジトリを作成する

GitHub の「Use this template」からリポジトリを作成し、clone します。

### 2. プロジェクト名を変更する

`IOSTemplateApp` を新しいアプリ名に一括変更するスクリプトを用意しています。
ディレクトリ・`.xcodeproj`・スキーム・ソース内の識別子・README のバッジ URL をまとめて置換し、GitHub リポジトリの Discussions を有効にします。

```bash
scripts/rename.sh MyApp
```

- アプリ名は英字で始まる英数字のみです（Swift のモジュール名になります）
- README のバッジ URL と Discussions の有効化に使うリポジトリ名は `origin` から推定します。別のものを使う場合は第 2 引数で `owner/repo` を渡します
- 作業ツリーがクリーンな状態で実行し、実行後に `git diff` で差分を確認してコミットしてください
- テンプレートから作成したリポジトリには Discussions の設定が引き継がれず、無効のままになります（ralph-loop はゴールを Discussion で受け取ります）。スクリプトは `gh repo edit --enable-discussions` で有効にするため、`gh` で認証済みで、リポジトリの管理者権限が必要です
- Discussions を有効にできなかったときは、リネームは止めずに警告と手順を表示します。表示された手順で有効にしてください

### 3. 署名情報を設定する

署名情報やバージョンは pbxproj ではなく [Configs/Project.xcconfig](Configs/Project.xcconfig) に集約しています。
リポジトリ作成後、まず以下を書き換えてください。

| 設定 | 内容 |
|---|---|
| `DEVELOPMENT_TEAM` | Apple Developer Program の Team ID |
| `APP_BUNDLE_IDENTIFIER` | アプリ本体の Bundle Identifier。テストターゲットは `.Tests` / `.UITests` を付けて自動で派生します |
| `MARKETING_VERSION` | アプリのバージョン。ビルド番号（`CURRENT_PROJECT_VERSION`）は Upload のときに App Store Connect の最新ビルドを見て Xcode が自動で増やすため、手で上げる必要はありません |
| `IPHONEOS_DEPLOYMENT_TARGET` | 最低サポート OS |

### 4. GitHub Secrets を設定する

Archive / Upload ワークフローは App Store Connect API Key で認証します。
リポジトリの Settings → Secrets and variables → Actions に以下を登録してください。

| Secret | 内容 |
|---|---|
| `EXPORT_OPTIONS` | `ExportOptions.plist` の内容。[docs/ExportOptions.sample.plist](docs/ExportOptions.sample.plist) の `teamID` を書き換えて、ファイルの中身をそのまま登録します |
| `APPLE_API_KEY_BASE64` | App Store Connect の API Key（`AuthKey_XXXXXXXXXX.p8`）を `base64 -i AuthKey_XXXXXXXXXX.p8` でエンコードした文字列 |
| `APPLE_API_KEY_ID` | API Key の Key ID |
| `APPLE_API_ISSUER_ID` | API Key の Issuer ID |

API Key は App Store Connect の「ユーザとアクセス → 統合 → App Store Connect API」で、App Manager 以上の権限で発行します。
### 5. App Store Connect にアプリを作成する

Bundle ID・証明書・プロビジョニングプロファイルは、Export のときに API Key で自動的に作成されます（`-allowProvisioningUpdates`）。
App Store Connect でのアプリ作成だけは API で行えないため、Web 画面で行います。

アプリを作らずに `develop` へ push しても問題ありません。Upload ワークフローがアップロードの前にアプリの有無を確認し（[.github/scripts/check-app-store-app.rb](.github/scripts/check-app-store-app.rb)）、アプリが無ければ「新規アプリ」画面に入力する値（名前・バンドル ID・SKU など）を Job Summary に表示して止まります。表示された値でアプリを作成してから、ワークフローを再実行してください。

SKU は Bundle ID と同じ値にします。SKU はユーザーには見えない社内用の ID で、後から変更できないため、迷わないようにルールを固定しています。

#### TestFlight の内部テスター

Upload ワークフローは、アップロードの前に TestFlight の内部テストグループ「Internal Testers」を作り、変数 `TESTFLIGHT_INTERNAL_TESTERS` のメールアドレスを内部テスターに追加します（[.github/scripts/ensure-internal-testers.rb](.github/scripts/ensure-internal-testers.rb)）。グループは「すべてのビルドへのアクセス」を有効にして作るため、以降のビルドは処理が終わりしだい自動で配信されます。2 回目以降の Upload では確認だけで何もしません。

| 変数 | 内容 |
|---|---|
| `TESTFLIGHT_INTERNAL_TESTERS` | 内部テスターにするメールアドレス。複数のときはカンマ区切り。Organization の変数に登録しておくと、テンプレートから作ったリポジトリすべてで使われます。空なら何もしません |

- 内部テスターになれるのは App Store Connect のユーザー（「ユーザとアクセス」に登録されているメンバー）だけです
- テスターの追加に失敗してもアップロードは止めません。失敗したメールアドレスは Job Summary に表示されます
- グループの作成とテスターの追加には、API Key が App Manager 以上の権限である必要があります

### 6. ブランチ運用と CI

| ブランチ | Build（ビルド + テスト + SwiftLint） | Archive（IPA Export） | Upload（App Store Connect） |
|---|:-:|:-:|:-:|
| `main` | ✅ | ✅ | |
| `develop` | ✅ | | ✅ |
| `release/**` | ✅ | | ✅ |
| その他の作業ブランチ | ✅（Unit テストのみ） | | |
| Pull Request の作成時（opened / reopened / ready_for_review） | ✅ | | |
| Fork からの Pull Request | ✅ | | |

- Upload は Archive → IPA Export を含むため、`develop` / `release/**` では Archive を別途実行しません
- Archive / Upload は Actions タブから手動でも実行できます（Run workflow）。作業ブランチを TestFlight で確認したいときは、Upload を手動実行してそのブランチを選びます
- リポジトリ変数（Settings → Secrets and variables → Actions → Variables）に `ENABLE_DELIVERY=false` を設定すると Upload をスキップします（Archive は App Store Connect にアプリが無くても通るため止めません）。テンプレートリポジトリ自身はこの設定でアップロードを止めています。テンプレートから作成したリポジトリには引き継がれないため、何もしなければ従来どおり実行されます
- ドキュメントだけの変更（`**/*.md`、`docs/**`）では Build を実行しません。Upload（`develop` / `release/**` への push）と Archive（`main` への push）は、ドキュメントだけの変更でも実行します
- 作業ブランチへの push では、時間のかかる UI テスト（`<プロジェクト名>UITests`）を省いて Unit テストだけ実行します。UI テストは Pull Request の作成時と `main` / `develop` / `release/**` への push で実行します。Fork からの Pull Request は push で実行されないため、更新（synchronize）を含むすべてのイベントで UI テストまで実行します
- Xcode のバージョンは [.github/workflows/_build.yml](.github/workflows/_build.yml) と [.github/workflows/_archive.yml](.github/workflows/_archive.yml) の `xcode-version` で固定しています。Environment の更新時はあわせて変更してください

### 7. PR 本文のスクリーンショット

UI の見た目が変わる変更では、Before / After のスクリーンショットを PR 本文に添付します。

- 画像は GitHub の添付ファイルとしてアップロードします。git の履歴やブランチには含まれず、マージ後も表示され続けます
  - ブラウザで PR を作る場合は、本文の入力欄に画像をドラッグ & ドロップします
  - CLI（エージェントを含む）では `gh` の `--attach`（gh v2.99.0 以上）を使います。本文に Markdown の表と `![Before](./before.png)` の形でローカルのパスを書き、同じファイルを `--attach` で渡すと、gh がその場でアップロード先の URL に書き換えます
  - HTML の `<img src="./before.png">` や `<table>` の中のパスは書き換わりません。表は Markdown で書き、幅をそろえたいときは作成後に `<img width="300">` へ置き換えます（下の例）
- アップロードした画像は削除できません。個人情報やトークンなどが写っていないか確認してから添付してください
- Before / After は表で横に並べ、同一条件（同じ端末・OS・外観モード・データ状態）で撮影します
- 影響する画面が複数ある場合は画面ごとに用意します。新規画面で Before が無い場合は「なし」と書きます

```bash
# body.md の表に ![Before](./before.png) と ![After](./after.png) を書いておく
gh pr create --title "..." --body-file body.md --assignee @me \
  --attach ./before.png --attach ./after.png

# 本文の画像を幅 300 の <img> に置き換える（本文を取得できたときだけ更新する）
body=$(gh pr view <番号> --json body -q .body) &&
  printf '%s\n' "$body" \
  | perl -pe 's{!\[([^\]]*)\]\((https://github\.com/user-attachments/assets/[^)\s]+)\)}{<img src="$2" alt="$1" width="300">}g' \
  | gh pr edit <番号> --body-file -
```

### 8. App Store の掲載情報（スクリーンショット・説明文・ヘッダー）

App Store のプロダクトページに載せるものは、`AppStore/` の JSON を元ネタにして、手動実行のワークフローで App Store Connect に反映します。
反映先は「編集できる状態のバージョン」だけで、審査中・配信済みのバージョンには触りません。
どのワークフローも、リポジトリ変数 `ENABLE_DELIVERY=false` のリポジトリ（テンプレート自身など）では反映しません。

| ワークフロー | 反映するもの | 元ネタ | ランナー |
|---|---|---|---|
| `Screenshots/App Store` | スクリーンショット（iPhone 6.9 inch / 6.3 inch / iPad 13 inch / iPhone Duo × 各言語） | `AppStore/screenshots.json` / `AppStore/languages.json` / `AppStore/app.json` | 撮影だけ macOS、縮小と反映は ubuntu |
| `Metadata/App Store` | 説明文・キーワード・プロモーションテキスト・最新情報・URL（既定は dry-run） | `AppStore/metadata/*.json` | ubuntu |
| `Creative assets/App Store` | プロダクトページのヘッダーと検索結果のクリエイティブアセット（既定は dry-run） | `AppStore/creative_assets.json` / `AppStore/creative/<言語>/` | ubuntu |
| `Verify/App Store metadata` | PR で、文字数の上限・撮影設定・撮影モードの Scene との対応を検査する | `AppStore/**` | ubuntu |

**スクリーンショット**

- 撮影はアプリの撮影モード（[IOSTemplateApp/Screenshot/ScreenshotDemo.swift](IOSTemplateApp/Screenshot/ScreenshotDemo.swift)）で行います。`Tools/capture_screenshots.sh` が `-screenshot-demo -screenshot-scene <名前>` と言語を起動引数で渡し、アプリはデモデータで目的の画面を開きます
- 画面を足すときは、`ScreenshotDemo.Scene` に case を足し、`IOSTemplateApp.swift` の `rootView` で開く画面を返し、`AppStore/screenshots.json` の `scenes` に同じ名前を足します（1 表示サイズにつき 10 枚まで）
- 撮るのはリリースのときだけです。`release/**` ブランチを選んで手動実行します（それ以外のブランチでは止まります）
- macOS ランナーの枠を開発のビルドと取り合わないよう、撮影は 1 本ずつ流します。6.3 inch（`deriveFrom`）は撮らずに 6.9 inch を ubuntu で縮めて作り、App Store Connect への反映も ubuntu で行います
- iPhone Duo は Xcode 27.1 と iOS 27.1 のランタイムが要るので、`xcode-27` のランナーで撮ります（`screenshots.json` の `runsOn` / `xcodeVersion`）
- 手元で撮るなら `Tools/capture_screenshots.sh APP_IPHONE_67 ja`（出力は `build/screenshots/`）

**説明文・最新情報**

- `AppStore/metadata/<言語>.json` と `shared.json` に書きます。テンプレートの仮の文言（`TODO:`）が残っているあいだは反映できません
- 「このバージョンの最新情報」は `whatsNew` に `{"version": "1.1.0", "text": "…"}` の形で書きます。`version` が反映先のバージョンと一致するときだけ書き込むので、リリースごとに両方を書き換えます（最初のバージョンには最新情報の欄がありません）

**プロダクトページのヘッダーと検索結果**（[App Store asset best practices](https://developer.apple.com/app-store/asset-best-practices/)）

- iOS 27 / iPadOS 27 以降の App Store では、スクリーンショットとは別に、プロダクトページのヘッダー（21:9、3840x1646）と検索結果（3:2、3840x2560）に画像を載せられます
- 元は [AppStore/creative/src/creative.html](AppStore/creative/src/creative.html)。色と文言（`TODO:`）をアプリに合わせて書き換え、6.9 inch のスクリーンショットを撮ってから `Tools/render_creative_assets.sh build/screenshots/APP_IPHONE_67` で書き出し（Google Chrome を使います）、画像もコミットします
- ヘッダーは初めて来た人にアプリのいちばんの価値を 1 つだけ、検索結果は何をするアプリかを実際の画面と一緒に伝えます。端末によって左右が切れるので、大事なものは中央に寄せます。他社のロゴ・価格・URL・受賞歴は入れません
- `Creative assets/App Store` を `ref-data` → `dry-run` → `upload` の順に流して反映します。置き場所のグループと画像の仕様は、App Asset Library の参照データから引きます
- 反映したら、App Store Connect のプレビューで iPhone / iPad の見え方を確かめてから審査に出します

## 構成

```
.
├── Configs/                 # xcconfig（署名情報・バージョン・Deployment Target）
├── IOSTemplateApp/          # アプリ本体（SwiftUI）
├── IOSTemplateAppTests/     # Unit テスト（Swift Testing）
├── IOSTemplateAppUITests/   # UI テスト（XCTest）
├── IOSTemplateApp.xcodeproj # 共有スキーム IOSTemplateApp を含む
├── AppStore/                # App Store の掲載情報（言語・撮る画面・説明文・クリエイティブアセット）
├── Tools/                   # スクリーンショットの撮影と App Store Connect への反映
├── docs/                    # ExportOptions.plist のサンプル
├── scripts/                 # rename.sh
├── .swiftlint.yml           # SwiftLint 設定
└── .github/
    ├── ISSUE_TEMPLATE/      # Issue テンプレート
    ├── pull_request_template.md
    ├── scripts/             # check-app-store-app.rb（App Store Connect のアプリの有無を確認）
    └── workflows/
        ├── _build.yml       # 共通処理: ビルド + テスト + SwiftLint（workflow_call）
        ├── _archive.yml     # 共通処理: Archive → Export（→ Upload）（workflow_call）
        ├── build.yml        # 全ブランチの push / Fork からの PR
        ├── archive.yml      # main の push
        ├── upload.yml       # develop / release/** の push
        ├── app-store-*.yml  # App Store の掲載情報の反映（手動実行）
        └── verify-app-store-metadata.yml  # 掲載情報の検査（PR）
```

- プロジェクトはフォルダ同期グループ（Xcode 16 以降の形式）で管理しているため、ファイルの追加・削除で pbxproj は変わりません
- SwiftLint は Build Tool Plugin として全ターゲットに適用され、CI では `swiftlint lint --strict` としても実行されます。ルールは [.swiftlint.yml](.swiftlint.yml) で管理します
- CI のワークフローは `*.xcodeproj` の名前と同名の共有スキームが存在することを前提にしています
- [IOSTemplateApp/PrivacyInfo.xcprivacy](IOSTemplateApp/PrivacyInfo.xcprivacy) はプライバシーマニフェストです。UserDefaults（`@AppStorage`）の利用だけを申告しています。データの収集・トラッキング・ほかの理由の申告が必要な API を足したら、ここと App Store Connect の「App のプライバシー」を更新してください

## License

[MIT License](LICENSE)
