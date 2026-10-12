# macOS release

1. Increment `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in both configurations. Run Debug tests normally; run Release tests in a separate macOS test account or VM so an unsigned test host cannot replace the installed app's privacy records.
2. Archive for `generic/platform=macOS` with `ONLY_ACTIVE_ARCH=NO` and the distribution team’s Developer ID Application certificate.
3. **Export the archive with `xcodebuild -exportArchive`.** An archive alone can leave Sparkle’s nested helpers ad-hoc signed, even when `codesign --verify --deep` passes.

Export options:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>YOUR_TEAM_ID</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
```

```sh
xcodebuild -exportArchive   -archivePath "$ARCHIVE"   -exportPath "$EXPORT"   -exportOptionsPlist ExportOptions.plist
```

4. Verify the exported app recursively. Check Developer ID, team, secure timestamp and hardened runtime on the main executable, `LutiProcessHost`, Sparkle framework, `Updater.app`, `Autoupdate`, `Downloader.xpc` and `Installer.xpc`.
5. ZIP the **exported** app with `ditto -c -k --keepParent`. Submit with `notarytool`; require `Accepted`. Staple and validate the app, then require `spctl --assess --type execute` to pass.
6. Create a compressed DMG containing the stapled app and an `/Applications` symlink. Sign the DMG with Developer ID and a secure timestamp. Notarize it, require `Accepted`, then staple and validate it.
7. Generate the Sparkle appcast from the final stapled DMG with the existing Keychain account `com.aouos.luti`. Keep `SUPublicEDKey` unchanged. Use the versioned GitHub release download URL.
8. Check appcast build/version, download URL, byte length and EdDSA signature. Mount the final DMG and verify its app version, architectures, signatures and notarization ticket. Run package smoke tests in an isolated test configuration. With App Management disabled, open and reopen an owned Chrome session and check for app-bundle denials in the system log. Verify restart and upgrade preserve the installed app's settings and permissions.
9. Push the release tag, publish `Luti.dmg` and `appcast.xml`, and mark the release latest. Download the public assets again and compare their hashes with the tested files; check the latest appcast URL.

If Apple reports an expired or unsigned agreement, the distribution team’s Account Holder must accept it in the Apple Developer account. Retry after the agreement takes effect. Do not rotate credentials for this error.

A working appcast and valid signatures do not prove an installed older app completed an update. Report that separately when tested.

Reference: [Sparkle distribution instructions](https://sparkle-project.org/documentation/#4-distributing-your-app).
