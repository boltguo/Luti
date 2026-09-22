# Contributing to Luti

Keep contributions focused, secure, and easy to review. Extend existing capabilities when they already fit the problem; add configuration, public tools, or abstractions only when the current design cannot express the required behavior.

## Before You Start

- Use macOS 14 or later.
- Install Xcode 26 or later.
- Check existing issues and pull requests before starting substantial work.
- For a large behavior or architecture change, open an issue first to agree on scope before implementation.
- Follow [SECURITY.md](SECURITY.md) for vulnerabilities. Do not report them in a public issue.

## Set Up the Project

```bash
git clone https://github.com/boltguo/Luti.git
cd Luti
open Luti.xcodeproj
```

The shared `Luti` scheme builds the app and runs its tests. `Package.resolved` locks Swift Package Manager versions, so unrelated changes should leave it untouched.

## Build and Test

Run the full test suite without requiring a signing identity:

```bash
xcodebuild test \
  -project Luti.xcodeproj \
  -scheme Luti \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Add or update tests whenever behavior changes. Work involving permissions, authentication, project boundaries, process execution, downloads, browser or computer control, persistence, or recovery must cover failure paths as well as successful ones.

Features that depend on macOS permissions, external providers, code signing, notarization, or the packaged app also need manual verification. Record those checks in the pull request.

## Design and Implementation

- Follow Apple platform conventions and use the existing Material 3 Expressive components and visual language.
- Keep module boundaries clear and component responsibilities focused.
- Prefer the simplest implementation that is correct, secure, maintainable, and testable.
- Reuse existing tools, actions, providers, components, and shared logic before expanding the public surface.
- Preserve distinct permission, risk, and side-effect boundaries.
- If Luti cannot enforce a security boundary, it must fail closed.
- Avoid unrelated refactors, generated churn, and new dependencies.

When user-facing text changes, update all bundled localizations:

- `Luti/Resources/en.lproj/Localizable.strings`
- `Luti/Resources/zh-Hans.lproj/Localizable.strings`
- `Luti/Resources/ja.lproj/Localizable.strings`

If you change a dependency or bundled runtime, update its pinned version, integrity metadata, and `THIRD_PARTY_NOTICES` in the same pull request.

## Commits and Pull Requests

Write concise [Conventional Commits](https://www.conventionalcommits.org/) messages:

```text
feat: add project capability discovery
fix: reject paths outside the approved project
test: cover OAuth refresh token replay
docs: clarify local build requirements
```

Each pull request should:

- Explain the problem and why the proposed solution fits it.
- Contain one coherent change.
- Call out security, permission, compatibility, and migration effects.
- Include automated tests where practical.
- List the automated and manual checks that were run.
- Include screenshots for visible UI changes.
- Update documentation and localization alongside the behavior they describe.

By submitting a contribution, you agree that it is licensed under the project's [Apache License 2.0](LICENSE).
