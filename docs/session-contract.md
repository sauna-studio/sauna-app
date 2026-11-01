# Apple session storage contract

対象: [sauna-api #55](https://github.com/sauna-studio/sauna-api/issues/55) / 親 [#13](https://github.com/sauna-studio/sauna-api/issues/13)。これは保存・現ローカルcookie受理・通信設定の契約です。native Passkeyログイン全体やAPIクライアントの完成を意味しません。

## 保存と失効

- 正規32byte base64urlトークン、有限の発行時刻・期限、最大24時間を検査し、保存version/破損/時計逆行はfail closedとする。ユーザーIDや権限は保存tokenから生成しない。
- Keychainはservice/account（環境・profile）を精密指定し、同期なし・`WhenUnlockedThisDeviceOnly`を要求する。access groupを追加せず、ホストmacOSではbackend自体をコンパイルしない。
- CSRFはメモリのみ。復元値は`UnverifiedSession`であり、API再照合からCSRFを受けるまでrequest credentialsを発行しない。
- 同期persistence呼出でactor再入を避け、generation ticketでlogout後のlate saveを防ぐ。revisionを照合し、古い401や期限切れcleanupが新しいセッションを削除しない。Keychain `kSecAttrGeneric`による旧revisionのupdate/delete負例をSimulatorで検証する。
- locked/unavailableは不在や期限切れへ変換しない。明示ローカル削除は最初にメモリを失効し、永続削除失敗をエラーで返す。そのprocessでは再復元を抑止する。新revisionが残ればconflictを返す。
- ローカル削除とAPI logout/revocationは別操作。永続削除失敗やoffline時に完全なlogout成功とは報告しない。再起動後に残ったtokenも未検証としてのみ復元され、サーバー失効の成功は保証しない。
- token/CSRF/lease/ticket/vault/storage blobは診断・Mirrorでredactする。生のKeychain query・payload・NSErrorをエラーへ含めない。

## Cookieと通信の境界

`SessionCookieContract`は現在の固定local backend `http://127.0.0.1:8080`、許可endpoint/status、profile別`__Host-`名、Secure/HttpOnly/SameSite=Strict/Path=/、Domainなし、正規tokenと期限を検査する純粋関数。複数Set-Cookieは個別値を保持して渡し、結合・折り畳み・重複属性は拒否する。production originは未設定として拒否する。storage scopeは保存namespaceであり、origin認可の代わりにならない。

`makeEphemeralSession`はcookie自動保存・再送、credential storage、cacheを無効化し、redirectを拒否する。初期URLや呼出元による手動token添付までは制限しない。将来のAPIクライアントは固定Origin/endpointのrequest構築と安全なcookie応答受理・API再照合を統合する必要がある。現在はその統合や実native認証を検証済みとはしない。

## 実測（2026-11-01）

- ローカルXcode 27.2 final 27B52 / Swift 6.4: `swift build`、ホスト22テスト（3suite）成功。fake persistenceのみ。
- 専用iOS 27.2 Simulator: 実Keychain 6件と共通22件、計28件成功。端末限定属性・CSRF非永続化・旧revisionCAS・環境/profile隔離・弱い属性拒否・registryを実測。
- loopback実socketの3件はcookie再送なし、302追従なし、cache再利用なしを実URLSessionで検証。
- 独立ReviewとSecurityは各々別のimmutable snapshot/scratchでホスト22件を再実行し成功。
- Xcode MCPは公式Security資料確認、test framework project生成、専用Simulatorの実行可能性確認に使用。ビルド/テストはXcode CLIで実行。SwiftUIコードは追加していない。

未署名のunhostedテストは実SecItemで`errSecMissingEntitlement`（-34018）になったため、テスト専用UIKit Scene hostとad-hoc署名で正しい実行環境を構成した。証明書・秘密鍵・Apple Team・共有keychain group・属性緩和は不要。これは署名エラーを無視する回避ではなく、実SecItemのためのtesthost構成である。

CI実行結果・GitHub最新Codexレビューは各PRを正本とする。実機の生体認証、Associated Domains、実利用者Passkey登録、本番domain、API cookieを使うnative画面は未検証であり、app #2で継続する。

actionlint 1.7.12のrunner一覧が公式`xcode-27` labelに追従していないため、lint設定にこのlabelだけを補足する。他のrunner-label検査を無効化しない。追跡・削除条件は[app #8](https://github.com/sauna-studio/sauna-app/issues/8)。実CI runnerが動作したことの代用にはしない。

独立Reviewは同じ専用Simulatorの実Keychain6件も別途実行し、0 failuresで成功。Securityは独立host22件とsource、独立Simulator結果の監査を実施した。CI用スクリプトは実行ごとに新しい専用deviceを作成し、他deviceへアクセスせずfinallyで削除する。

CIと同一の`python3 scripts/test_simulator.py`もローカルで成功（28件、exit 0）。新規作成したdeviceの削除をsimctl一覧で照合し、独立レビュー用の専用deviceも検証終了後にそのUDIDだけを削除した。

初回CIはhost22件に成功したが、hosted imageにiOS27.2 runtimeが無く実Simulator工程を失敗として停止した。Apple公式`xcodebuild -downloadPlatform iOS -buildVersion 27.2 -architectureVariant arm64`を一時runnerのsetupに追加する（[公式導入方法](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)）。ローカル既存runtimeやシステム設定は変更しない。未検証のSimulator工程をskip成功にしない。
