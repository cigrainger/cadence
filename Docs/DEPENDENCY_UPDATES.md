# Dependency updates

Dependabot monitors both `github-actions` and `swift` at the repository root, monthly. Swift version updates inspect Package.swift and Package.resolved. GitHub's Swift support does **not** currently provide the dependency graph/security-update coverage available for some other ecosystems; keep the explicit inventory and OSV check.

At the 17 October 2026 review:

- ZIPFoundation **0.9.20** is the only external Swift package and the latest upstream release. Keep the exact version and revision pinned; a change also needs the matching archive hash and inventory record.
- Local builds use Apple Swift **6.4**. Upstream Swift **6.4.1** was released on 15 October. CI deliberately uses Xcode 26.3/Swift 6.2 to retain a reproducible supported baseline. A toolchain update is separate from a package update and is not managed by Dependabot.
- The package manifest declares tools version **6.0** and compiles in **Swift 5 language mode**. That is compatibility mode on a modern compiler, not Swift 6 strict concurrency. Move to Swift 6 mode as a dedicated migration with actor ownership, Sendable boundaries and device callback tests; do not merely change the flag.
- OSMD and its renderer dependencies are vendored, so Dependabot's Swift configuration does not update them. Check their source/version provenance, hashes, licenses and notation rendering together. The current inventory explicitly retains unresolved transitive versions.

For action PRs, inspect the pinned SHA and upstream major-version notes, refresh against main, and wait for checks. The reviewed artifact updates retain named ZIP artifacts; Cadence does not opt into direct single-file uploads. Download digest mismatches must fail. Never disable checksum validation to make an update pass.

Sources: [Dependabot options](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference), [dependency graph support](https://docs.github.com/en/code-security/reference/supply-chain-security/dependency-graph-supported-package-ecosystems), [ZIPFoundation releases](https://github.com/weichsel/ZIPFoundation/releases), [Swift 6.4.1](https://github.com/swiftlang/swift/releases/tag/swift-6.4.1-RELEASE).
