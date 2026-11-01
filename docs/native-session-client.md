# Native session revalidation and logout

[app #10](https://github.com/sauna-studio/sauna-app/issues/10) / [ADR0017](https://github.com/sauna-studio/sauna-docs/blob/main/docs/adr/0017-apple-session-api-client.md)。この段階は既存tokenのAPI再検証とlogoutに限定する。AuthenticationServicesによる登録・署名、UI、AASA、本番domain、実機Data Protectionはapp #2に残す。

## 契約と生成

OpenAPI正本は`sauna-api@6e0c0497b2cebc86ab8ee801f4cfeaad5736e4bc`の`Sources/SaunaAPIContract/openapi.yaml`。全ファイルを保持し、`docs/openapi-source.json`にSHA256を記録する。filterは`getAuthSession`と`logoutSession`だけ。内部Client/DTOを公式command pluginで`GeneratedSources`へ生成してcommitし、手編集しない。

依存はGenerator 1.14.3 / Runtime 1.13.3 / URLSession 1.4.0 / HTTPTypes 1.8.0をexact指定する。URLSession 1.4.0は調査時の[公式最新安定release](https://github.com/apple/swift-openapi-urlsession/releases/tag/1.4.0)。root `Package.resolved`は生成toolの依存も含む。Xcodeのlocal package consumerはruntimeの4依存だけを解決するため、workspace lockのruntime pinsがroot lockと同一であることを検証する。

```sh
python3 scripts/validate_openapi.py --verify-upstream
swift package --force-resolved-versions --allow-writing-to-package-directory generate-code-from-openapi --target SaunaAppleSession
git diff --exit-code -- Sources/SaunaAppleSession/GeneratedSources
test -z "$(git ls-files --others --exclude-standard -- Sources/SaunaAppleSession/GeneratedSources)"
swift build --force-resolved-versions
swift test --force-resolved-versions
python3 scripts/test_simulator.py
```

更新時は上流の採用commitを先に決め、全snapshotとsource recordのcommit/hashを同時更新する。必要なら依存を解決して両lockを更新し、生成・差分確認・runtime pins照合・全テストを実行する。Generatorの公式manual-generation exampleと同様に入力yamlをtarget source内に置くため、SwiftPMは2つの非Swift入力についてunhandled-file warningを出す。runtime resourceとしてこれらを配布しない。

## 安全境界

`SessionClient(vault:)`はvault自身のreadonly scopeを使い、別scope・URL・header・transportのpublic注入を提供しない。production未設定は初期化時に拒否する。宛先は`http://127.0.0.1:8080`固定。customer Originは`http://localhost:5173`、staffは5174でありbackend originとは別。

送信直前にoperationID/method/path/baseURL、scheme/authority/Host、単一profile Origin、CSRF対応を照合し、profile cookieを付与する。Generatorのheader URI encodingはOriginをpercent encodeするため、そのprofileの既知literalまたは既知encoded literalだけを照合してliteralへ上書きする。任意percent decodeはしない。cookie手動搬送とこの補正は[api #51](https://github.com/sauna-studio/sauna-api/issues/51#issuecomment-6552561069)に削除条件・回帰を記録する。security guards全体を暫定対処として削除しない。

公式URLSession transportは`.buffered`を明示し、既存ephemeral sessionのredirect拒否delegateを使用する。cookie jar・cache・credential storageを無効化し、timeoutは10秒。16KiBは**生成JSON decoderへの入力上限**であり、URLSessionがbufferするwire受信メモリの上限ではない。現在は固定local endpointだけを許可し、本番接続は拒否する。生成Client経由の実socketテストでredirect先へのrequestが0であることを確認する。

## 再検証と失効

1. 復元leaseのscope/generation/revision/期限を検証し、以前のmemory CSRFを破棄してGET `/auth/session`を送る。GETにはCSRFを付与せず、cookieを再発行しない。
2. 200でSet-Cookieが無いこと、JSON schema、canonical UUID、正規CSRF、将来かつ24時間以内・lease以内の期限を検証する。UUIDから施設権限を生成しない。
3. actor内でも期限/cancellationと同leaseを再検証した後だけmemory CSRFを設定し、`VerifiedSession`を返す。CSRFの使用期限はAPI metadata期限で短縮し、保存token期限を延長しない。
4. 401はerror bodyに依存せず同leaseを精密失効する。期限切れpreflightも同leaseだけを削除する。403/429/503/network/timeout/cancel/不正200を成功にせず、raw body・ClientError・DecodingErrorは公開しない。
5. logoutは同leaseのtoken+CSRFでPOST `/auth/logout`。204と正しい単一削除cookieを確認する。成功・失敗・cancelいずれでも当該leaseのローカル失効を試みる。古いlogout/401/200は新loginを変更しない。

logoutは正しい204とローカル精密削除が両方成功した時だけ成功を返す。失敗時はremote logout成功とは報告せず、storage失敗も固定errorで通知する。error値だけでremote/localのphaseを個別に判定できるとは約束しない。永続削除失敗は同process再復元を抑止し、再起動後の残tokenも未検証でしか復元しない。

## 検証構成

Xcode harnessは以前の直接Sources frameworkから、正本のlocal SwiftPM productをlinkするtest bundleへ変更した。package dependenciesとgenerated codeを同じbuildで検証するため、既存target settingsを引き継ぎstandard `project.pbxproj`を構成した。旧`project.xcproj`からXcode自身が自動変換したとは扱わない。

ホストテストはfake persistenceだけ。内部test transportは任意URLをpublic clientへ公開せず、宛先guard後に所有random loopback portへrouteして実HTTPを検証する。固定8080への実API接続は別smokeで確認する。Keychain実検証は専用iOS 27.2 Simulator、合成token、test固有namespaceのみ。host Keychainや既存API/Web/DBを停止・resetしない。

実行件数・独立Review/Security・GitHub Codex・CIの最終結果はPRへ記録する。未実行を成功と扱わない。

## この段階の実測

- ローカルXcode27.2 final: host40件/5suite成功。専用iOS27.2 Simulatorは実Keychain6件＋共通40件（46件）成功。localSwiftPM product経由の生成code/依存もbuildした。終了後、所有deviceの削除を一覧照合した。
- 再生成9file差分無し、immutable API snapshot/hash、両lock runtime pins、actionlint、diff検査成功。新しい未追跡生成.swiftを入れた負例もCI検査により拒否する。
- 独立Review/Securityは別snapshotでhostテストとsourceを検証する。最終結果はPRに集約する。
- rootの別snapshotで、稼働中の実Sauna API/PostgreSQL18へ両profileのpublic client再検証→logout→旧token401を実行し、1test/0.135秒で成功した。最終source hash一致を照合済み。検証用追加test/平文fixtureは製品へ追加していない。初期fixture準備失敗分の所有者不明な残存可能性と、所有UUIDだけを削除するcleanup方針は[Issue10の証跡](https://github.com/sauna-studio/sauna-app/issues/10#issuecomment-6552590700)に記録し、完全な掃除済みと推測しない。
