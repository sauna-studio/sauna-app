# SwiftUI policy provenance

Canonical source: [sauna-studio/.github/policies/swiftui.md](https://github.com/sauna-studio/.github/blob/3097a1df8eb8f397adf803562aadd4ef46aaf609/policies/swiftui.md).
Source commit: `3097a1df8eb8f397adf803562aadd4ef46aaf609`.
Policy SHA-256: `9a12bdf1e70121bf5eb38a738f01009700ec46a2979ff6d555ed9cab44f38558`.

<!-- BEGIN SAUNA_STUDIO_SWIFTUI_POLICY -->
## SwiftUI policy — iOS/iPadOS 27.2+

Scope: SwiftUI work in `sauna-app` and `sauna-admin-app`. Read the available SwiftUI Expert Skill; project requirements override generic older-OS fallback advice. Verify availability against the deployment target and selected SDK. Do not impose an architecture or adopt Liquid Glass automatically.

### Layout

Start with standard containers. Select `Layout` for placement, `onGeometryChange` for observation, `alignmentGuide` for relationships, Subview APIs for containers, `ArrangementView` for two regions. Check `ViewThatFits`/`fixedSize` sizing. `if` removes; `opacity`/`hidden` reserve space. Check invisible accessibility/hit testing. `GeometryReader` needs a geometry-driven purpose; prevent feedback loops. `Layout` is not lazy virtualization. [User reference](https://zenn.dev/zunda_pixel/articles/2cc489b4168a5a)

### Identity and ownership

Identity controls state lifetime; changing initializer arguments does not reset existing state. Use stable model IDs. Change `.id` or conditional containers only for intentional lifetime changes. Do not treat inferred List caches as API contracts. [User reference](https://zenn.dev/zunda_pixel/articles/ea826f888d05ed)

Keep primitive view-local `@State` private. Preserve owned observable models with `@State`; use `@Bindable` for injected edits and plain values for read-only inputs. An initial value seeds that identity's storage; `View.init` may run again. Later parent updates need values or bindings. UI-owned observable models/routers use explicit `@MainActor` under our nonisolated default.

### Observation

Prefer property-granular `@Observable` models and small dependency boundaries. A class alone does not guarantee faster rendering. Measure actual UI updates rather than generalizing old benchmark counts; do not eliminate appropriate primitive state. [User reference](https://zenn.dev/zunda_pixel/articles/9ce01609d0d234)

### Navigation

Default to an exhaustive `Hashable` route enum with stable IDs and `[Route]`; use `NavigationPath` when heterogeneous types are needed. Own the router at its scope and inject through `@Environment`. Modernize legacy wrappers. Never derive a retroactive `Binding: Hashable` from mutable wrapped values. [User reference](https://zenn.dev/zunda_pixel/articles/ebf2a079cbf68b)

Own routers per scene/account/profile; key private presentation caches by environment/facility too. Clear authenticated presentation on logout, revocation or identity changes; discard late results from a previous identity/scope. Keep token/CSRF handling in the existing session layer, not UI state or navigation persistence. Routes contain IDs, not credentials or full private models. Authorized display models remain allowed. Restored IDs/deep links require API authorization; UI state grants no access. Preserve redacted errors.

### Verification

For UI changes, build/test on the target SDK and check iPhone/iPad resizing, Dynamic Type, accessibility, state lifetime and back navigation. Profile performance when needed. Document-only changes verify policy parity/links; do not claim unexecuted UI or Instruments checks.

Apple contracts: [Observation migration](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro), [State](https://developer.apple.com/documentation/swiftui/state), [NavigationStack](https://developer.apple.com/documentation/swiftui/navigationstack), [Layout](https://developer.apple.com/documentation/swiftui/layout), [ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview). Skill: [SwiftUI Agent Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill).
<!-- END SAUNA_STUDIO_SWIFTUI_POLICY -->
