# Xcode project configuration

SessionSimulatorHarnessはXcode27.2標準のJSON `project.xcproj`を使う。Xcode27以降が両形式を支持するため、旧形式の併置や旧Xcode向け分岐は追加しない。アプリ本体ではなく、正本SwiftPM libraryと共通テストを実行する専用test hostである。

移行は[Apple公式資料](https://developer.apple.com/documentation/xcode/updating-your-xcode-project-configuration-file-format)とinstalled Xcode27.2の`xcodebuild -help`を確認し、公式CLIで実施した。

```sh
xcodebuild -project Tests/SessionSimulatorHarness/SessionSimulatorHarness.xcodeproj \
  -convert-project 'Xcode Project'
```

このXcodeでの形式名は`Xcode Project`である。`JSON`は形式名として拒否され、変更されなかった。拡張子のrenameや独自converterではなく、同CLIが旧`project.pbxproj`を除去し、新`project.xcproj`を出力した。UI操作は中断されたため、UIで変換したとは記録しない。

移行時には次を確認した。

- `xcodebuild -list -json`のtarget/configuration/schemeが移行前後で一致。
- `-showBuildSettings -json`の選択したhost設定が一致。別途、旧PBX全設定と新JSONをFoundationのJSON5 decoderで読み、projectと両targetのDebug/Release全build settingsを比較して一致。product typeの旧`com.apple.product-type.`prefixだけを表現上の違いとして正規化した。
- target IDs、test-host依存、BUNDLE_LOADER/TEST_HOST、iOS27.2/Swift6/strict concurrency、ad-hoc署名と空Team、source membershipを保持。
- local SwiftPM product参照とlockfileを保持。ユーザーの指定依存追加/compiler policyは別Issue #13で適用する。
- [Apple公式xcode-project-format](https://github.com/apple/xcode-project-format)0.1.0（`c132630aabf40f6d6c3f7bb004595d2e5a28ea42`）の`xcprojformatter`でschema読取・書出しを行い、出力がbyte単位で一致。これは開発時の検証toolでありアプリ依存ではない。

`.xcproj`はtrailing commaを含むため、strict JSON parserだけで拒否しない。Xcodeまたは公式format libraryを使用する。JSON5読取も設定比較のためだけに用い、変換結果を手編集で再生成していない。

```sh
swift build --force-resolved-versions
swift test --force-resolved-versions
python3 -m unittest discover -s scripts -p 'test_simulator_selection.py'
python3 scripts/test_simulator.py
```

host40件とinventory-only9件、専用Simulatorの実SecItem6件＋共通40件が成功した。`TEST SUCCEEDED`/exit0と、作成したUUIDがcleanup後のdevice一覧に無いことも確認した。各実行が作成したUUIDだけを削除し、host既存Keychain・証明書・秘密鍵・Apple account設定へ触れない。native Passkey UI/AASA、本番domain、実機でのData Protection検証は含まない。
