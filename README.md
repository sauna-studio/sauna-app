# sauna-app

利用者向けSwiftUI iOS・iPadOSアプリ（27.2以上）の開発リポジトリです。現在は画面の実装に先立ち、`SaunaAppleSession` SwiftPMライブラリのローカル保存契約を実装しています。

Sauna API / PostgreSQLを業務データの正本とし、認証はPasskeyのみを使います。予約・決済・チャットの画面、AuthenticationServicesによるPasskey操作、Associated Domainsと本番API接続はまだ実装していません（[app #2](https://github.com/sauna-studio/sauna-app/issues/2)）。Vintage・Pumpkinはデザイン参照であり、利用条件未確認の資産はコピーしません。

## Session contract

セッショントークンはiOSの`WhenUnlockedThisDeviceOnly` Keychainへ保存し、環境・customer/staff・アプリnamespaceで分離します。CSRFはメモリだけに保持します。復元したトークンは未検証であり、ユーザー情報・施設権限を生成しません。API再照合前に認証済みと表示してはいけません。

[保存と通信の境界・実測結果](docs/session-contract.md)を参照してください。SwiftPMのmacOS 27.0対応はKeychainを含まないホスト検証用であり、macOS製品を提供するものではありません。

## Verification

Swift 6.4 / Xcode 27.2とiOS 27.2 Simulator runtimeが必要です。

```sh
swift build
swift test
python3 scripts/test_simulator.py
```

ホストテストはfake persistenceだけを使用します。Simulatorスクリプトは専用deviceを作成し、実SecItem検証後にそのdeviceだけを削除します。テストhostは証明書・秘密鍵・Teamを使わないad-hoc署名です。既存のホストKeychainや他のSimulatorを操作しません。

CIはrepository policyに加え同じbuild/testを実行します。公式の`xcode-27` runnerでXcode 27.2を明示選択します。runnerのXcodeは現在RC build 27B48、ローカル実測はfinal 27B52であり、同一buildとは扱いません（[公式runner仕様](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)）。

[AGENTS.md](AGENTS.md)と[CONTRIBUTING.md](CONTRIBUTING.md)に従い、独立Review / Security ReviewとGitHub Codexレビューを満たしてからマージします。
