# sauna-app
Sauna Studio app


## Scope

利用者向けSwiftUI iOS・iPadOSアプリ。iOS・iPadOS 27.2以上。予約・決済・チャットのUIを提供する。

## Architecture

Sauna APIを正本とし、Passkeyでログインする。TweetbotのVintage・Pumpkinをデザイン参照にする。利用条件の未確認な資産はコピーしない。

## Verification

実装後は対象Xcodeでbuild/testを実行し、Xcode MCP・Simulatorで主要導線を確認する。古いOS向けの互換分岐は追加しない。

初期PRは開発基盤のみを追加します。CIはRepository policy検査を実行し、業務機能の実装や動作検証はまだ含みません。

[AGENTS.md](AGENTS.md) と [CONTRIBUTING.md](CONTRIBUTING.md) に従い、Issueの依存関係を満たしてから独立Review Agentを並行起動して実装します。共通規則適用元: [sauna-studio/.github@075c6695309d](https://github.com/sauna-studio/.github/tree/075c6695309d28baad2dc1391d7d3821b81142cc)。
