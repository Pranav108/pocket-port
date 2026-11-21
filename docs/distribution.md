# Distributing PocketPort

Publish the landing page and source in this GitHub repository. Users install the Mac helper from GitHub Releases and the iPhone app through TestFlight or the App Store. Sharing requires both installs and a trusted local Wi-Fi network.

## Mac installer

The maintainer needs a Mac with Swift and Xcode’s tools, the team’s **Developer ID Application** and **Developer ID Installer** identities in Keychain, and a saved `notarytool` Keychain profile. Create the profile on the release Mac with `xcrun notarytool store-credentials pocket-port` and follow the prompts. See [Apple’s signing and notarization instructions](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

From the checkout you intend to tag, set the identities and build the package. Use the certificate names from Keychain Access.

```sh
export POCKETPORT_APPLICATION_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export POCKETPORT_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
export POCKETPORT_NOTARY_PROFILE=pocket-port
bash scripts/package-macos.sh 1.1.1
```

The script compiles both architectures for macOS 14 or later, signs the universal binary and installer, waits for notarization, and verifies the stapled ticket. The result is `.build/distribution/pocket-port-1.1.1-macos-universal.pkg`. For local package assembly tests, pass `--unsigned`. That output has an `-unsigned.pkg` suffix and is for development.

Before publishing, open the signed package on a Mac with a clean user account and run `pocket-port --help` to verify installation. Use `command -v pocket-port` to confirm it resolves to `/usr/local/bin/pocket-port`. Test a file transfer on a physical iPhone and reopen the imported file offline. Verify the Intel install on an Intel Mac when available.

Create a draft GitHub Release with a version tag such as `v1.1.1` targeting the commit you built. Attach the signed `.pkg`, include the macOS requirement and the iPhone app install link, then publish the release. Users can upgrade by running a newer installer. See [GitHub’s release instructions](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

## iPhone app

1. In your Apple Developer account, register the bundle identifier `dev.pocketport.app` and create the PocketPort iOS record in App Store Connect using that identifier. Use the release team in Xcode.
2. In `PocketPort.xcodeproj`, set the version and increment the build number before each upload. Archive the `PocketPort` scheme for a generic iOS device and use **Distribute App** in Xcode Organizer to upload to App Store Connect.
3. Start with an external TestFlight group. Add the uploaded build, submit it for TestFlight review as required, and share a public TestFlight invitation link. Testers install Apple’s TestFlight app and accept the link on their iPhone.
4. For a public launch, prepare the App Store listing, screenshots, support URL, privacy disclosures, and any export compliance answers in App Store Connect. Use the published [privacy policy](privacy.md) for the privacy policy URL. Select the build and submit it for App Review. After Apple approves it, release the app and add its App Store link to the README and Mac release notes.

### App Review instructions

Explain that PocketPort requires the Mac helper on the same trusted Wi-Fi and provide the GitHub release link. Provide a video showing a physical iPhone scanning the Terminal QR, saving and opening a sample file, and reopening it offline. Reviewers can generate a fresh QR with `pocket-port sample.pdf` on the Mac. A QR from a previous recording expires after three minutes.

Apple’s guides cover [creating an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/), [uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), [external TestFlight testing](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/), and [App Review submission](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/).
