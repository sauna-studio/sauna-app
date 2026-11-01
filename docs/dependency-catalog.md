# Apple dependency catalog and compiler policy

ユーザー指定の10repositoryを事前登録する。依存の宣言・解決と、productのcompile・runtime利用を区別する。新しい認証・業務UIを実装する段階ではない。

| Repository / immutable manifest | 宣言 | 解決 | Swift tools |
| --- | --- | --- | --- |
| [swift-http-api-proposal](https://github.com/apple/swift-http-api-proposal/blob/dff8847b09af6ea70b30472bd5c5bc91dd86c830/Package.swift) | main | main@dff8847b09af | 6.4 |
| [valet](https://github.com/square/Valet/blob/43f517941ced37752c0cd5e2b53a3c9d021c848b/Package.swift) | from 5.0.0 | 5.1.1 | 6.0 |
| [defaults](https://github.com/sindresorhus/Defaults/blob/00a7465a0668a87fa159e779b9d80f1f9652357e/Package.swift) | from 9.0.0 | 9.0.9 | 6.2 |
| [swift-memberwise-init-macro](https://github.com/gohanlon/swift-memberwise-init-macro/blob/d0fb82bb6638051524214fb54524bfcd876735a1/Package.swift) | from 0.6.0 | 0.6.0 | 5.9 |
| [swift-http-types](https://github.com/apple/swift-http-types/blob/bff4b6903cdc99dda49649dd52f46c11cfd3ed50/Package.swift) | exact 1.8.0 | 1.8.0 | 6.1 |
| [swift-algorithms](https://github.com/apple/swift-algorithms/blob/87e50f483c54e6efd60e885f7f5aa946cee68023/Package.swift) | from 1.2.0 | 1.2.1 | 5.7 |
| [swift-async-algorithms](https://github.com/apple/swift-async-algorithms/blob/13713a4ffdee8abd929f92568ee9462a46ae26e0/Package.swift) | from 1.0.0 | 1.1.7 | 6.2 |
| [swift-collections](https://github.com/apple/swift-collections/blob/98ef3c98609a1e31b7e157b5b619579001a789d6/Package.swift) | from 1.1.0 | 1.7.1 | 6.2 |
| [swift-retry](https://github.com/fumoboy007/swift-retry/blob/df9d7b185d2e433147ec0083a73c257e665eea0d/Package.swift) | from 0.2.4 | 0.2.4 | 5.9 |
| [swift-async-operations](https://github.com/mtj0928/swift-async-operations/blob/5ee33ce3b4e59e6aa9b1dfe95f1623bd142efa7b/Package.swift) | from 0.5.0 | 0.5.0 | 6.0 |

全推移依存のrevisionは`Package.resolved`を正本とする。proposalのmainは`dff8847b09af6ea70b30472bd5c5bc91dd86c830`へ解決した。観測したmanifestはCollections exact1.7.1、AsyncAlgorithms exact1.1.7、AsyncHTTPClient exact1.35.0を要求する。Collectionsの以前の1.7.5から1.7.1への変更は、この採用したmainの厳密な依存要求に整合するためであり、任意の互換分岐は追加しない。

## 利用範囲

- 新catalogのproductをtarget dependenciesへ追加していない。macro・Valet・Defaults・retry・HTTPAPIsなどは**宣言と解決まで**であり、全productのbuildやruntime動作を検証済みとはしない。SwiftPMのunused dependency warningはこの状態を示す。
- Defaultsへtoken・CSRF・identity・施設権限を保存しない。Valetを追加してもKeychain providerは暗黙移行しない。host Keychainの呼出・探索をしない。
- retryをlogin/logout/ceremonyなど非冪等な認証operationへ自動適用しない。macroをtoken/CSRF/lease/ticketなどopaque型に付与して初期化制約を開かない。
- `SWIFT_SYNTAX_VERSION`や`HTTP_API_ENABLE_WASM`をoverrideしない。macro pluginのsandbox/validationを無効化しない。将来productを採用するときは、対象OSで実compile・動作・Security Reviewを追加する。

## 自前targetのcompiler policy

Swift 6 language mode、`defaultIsolation(nil)`（effective nonisolated）、strictMemorySafety、warnings-as-errorsに加え、以下6つを自前targetへ適用する。外部dependencyの設定を上書きしない。

- ExistentialAny
- InternalImportsByDefault
- MemberImportVisibility
- InferIsolatedConformances
- ImmutableWeakCaptures
- NonisolatedNonsendingByDefault

公開APIのFoundation型は明示的な`public import Foundation`で表す。生成internal sourceは手編集しない。unsafe/uncheckedや全体のwarning抑制で検査を回避しない。

```sh
python3 scripts/validate_swift_policy.py
swift build --force-resolved-versions
```

validatorはeffective manifest、10repositoryのURL/宣言重複/requirement、mainのreview済みcommit、全pinのimmutable revisionを検査する。機能flag欠落・重複宣言・main revision改変を拒否する負例を確認した。

更新時は採用するupstream sourceを確認し、明示的にresolve/updateする。main採用revisionはcatalog recordとlockへ同時記録し、`--force-resolved-versions`で再現する。未使用productの追加だけでruntime機能を完成扱いにしない。

## 利用者側の検証

既存runtime利用はOpenAPI Runtime / URLSession / HTTPTypes（CollectionsのDequeModuleは推移依存）を継続する。HTTPTypes既存exact1.8.0を維持する。root lockは35pins、Xcode product consumer lockは既存runtime4pinsだけを含み、その4つが一致することを`validate_openapi.py`で検証する。

strictMemorySafetyへの対応として、49byte保存形式のencodeをpointer viewから整数shiftへ変更し、既知big-endian byte fixtureで旧形式互換を検証する。loopback HTTP fixtureはPOSIX pointer操作からNetwork.frameworkへ置換し、loopback限定・8KiB入力・connection/cleanup timeoutを維持する。通信・Keychain provider・CSRF・競合制御は変更しない。

```sh
python3 scripts/validate_openapi.py --verify-upstream
swift test --force-resolved-versions
python3 scripts/test_simulator.py
```

現時点のhost41件/5suiteに成功（旧format golden1件を追加）。Xcodeの両自前targetも同じpolicyをDebug/Releaseへ設定する。Xcode27.2のinstalled Swift.xcspecに登録済みの5 feature設定と、未登録のImmutableWeakCapturesだけtarget限定OTHER_SWIFT_FLAGSを使う。`validate_swift_policy.py`はnative Xcode CLIで全target/configurationのeffective settingsを検証する。別途、実build logのcompiler invocationでも有効なflagを照合した。外部packageへtarget flagsを強制しない。

## Security C interop boundary

strictMemorySafetyを有効に保ち、`SecItemCopyMatching`の同期out-parameterを渡す3式（製品1、Simulator検証2）だけを`unsafe` expressionで監査対象として明示する。initialized local `CFTypeRef? = nil`は同期call中だけ参照し、pointerを保存・await越しに渡さない。installed iOS27.2 `Security.framework/Headers/SecItem.h`のretained-result契約に従い、既存のARC保持・status/attribute検査・namespace/CASを変えない。

根拠は[Apple SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))と[Swift SE-0458 unsafe expression](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md#unsafe-expression)。意味・ABIや自動的な安全証明を追加するものではなく、global unsafe flags・警告抑制・unchecked宣言へ広げない恒久的なC API境界である。Keychain providerを変更するための暫定回避とは扱わない。

## 最終ローカル検証

- SwiftPM host41件/5suite成功（両独立Review/Securityも別immutable snapshotで41件成功）。
- 新policyを有効にした専用iOS27.2 Simulatorで実SecItem6件＋共通41件、47件成功。所有deviceを削除し一覧からの消失を確認した。独立Reviewも別所有deviceでSecItem6件を再実行して成功し、そのdeviceだけを削除した。
- library / UIKit test host / test bundleの実compile invocationで6 feature・strictMemorySafety・warnings-as-errorsを確認した。effective settingsは両Xcode targetのDebug/Releaseでnonisolated。installedxcspecはこのdefaultではactorflagを出力しないため、MainActor default flagが無いことも照合した。
- native JSONはApple公式`xcprojformatter`0.1.0のschema roundtripでbyte差分無し。独自JSON変換や生成Swift sourceの手編集は無い。
- 最終Sources/Package/35pinsとhash一致するroot別snapshotで、稼働中の実API/PostgreSQL18へ両profileの復元→revalidate200/CSRFmemory→logout204/localclear→旧token401を実行し1test/0.112秒で成功。[Issue13の証跡](https://github.com/sauna-studio/sauna-app/issues/13#issuecomment-6552934619)に結果と所有fixture cleanupを記録した。host Keychainや既存サービスを変更せず、追加smoke testは製品repoへ入れていない。

最新GitHub CI/Codexレビュー結果は実装PRを正本とする。以上の結果をnative Passkey UI/AASA/実機/本番domainや、未使用catalog全productの検証完了へ広げない。
