# PocketPort

Share Markdown, plain text, PDFs, and images from your Mac to your iPhone over trusted Wi-Fi. The helper opens a temporary HTTP share, and the iPhone keeps a byte-for-byte copy for offline viewing.

## Requirements

- Mac with macOS 14 or later, Apple Silicon or Intel.
- iPhone with iOS 17 or later.
- A trusted Wi-Fi network that lets the Mac and iPhone reach each other.

## Install the Mac helper

Download the signed `pocket-port-<version>-macos-universal.pkg` when it is available on [GitHub Releases](https://github.com/Pranav108/pocket-port/releases). Open it to install or update `pocket-port`. The installer works on Apple Silicon and Intel, and it installs to `/usr/local/bin`. It requires neither Xcode nor Homebrew. Check the install in Terminal with `pocket-port --help`.

### Build from source

This option is available before the first installer release. It requires Xcode or the Xcode Command Line Tools.

```sh
git clone https://github.com/Pranav108/pocket-port.git pocket-port
cd pocket-port
swift build -c release --product pocket-port && mkdir -p "$HOME/.local/bin" && install -m 755 "$(swift build -c release --show-bin-path)/pocket-port" "$HOME/.local/bin/pocket-port"
```

If Terminal cannot find the source-built command, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and reopen Terminal. To update from source, pull the branch you use and repeat the build and install command. If you switch from a source build to a package, use `command -v pocket-port` to check which copy your shell runs.

## Share a file

Run the command from any folder.

```sh
pocket-port
```

Run `pocket-port` without arguments to share the only eligible file in the current folder. If several files are eligible, pass the filename or path. Use a relative path for a file in a subfolder, and quote paths that contain spaces.

```sh
pocket-port PLAN.md
pocket-port report.pdf
pocket-port "designs/App Icon.png"
pocket-port --project "Release planning" "/path/to/another/PLAN.md"
```

Supported extensions are `.md`, `.markdown`, `.txt`, `.pdf`, `.bmp`, `.gif`, `.heic`, `.heif`, `.jpeg`, `.jpg`, `.png`, `.tif`, `.tiff`, and `.webp`. A file named `README` also works. Markdown and text files must be UTF-8 and can be up to 5 MiB. PDFs and images can be up to 25 MiB. PocketPort also accepts QR codes from earlier versions of the Mac helper.

## Install the iPhone app

PocketPort is currently available as source. A TestFlight invitation or App Store listing will let users install it directly on their iPhone once an iOS build is distributed. See the [release guide](docs/distribution.md) for how to publish each part.

For local development, open `PocketPort/PocketPort.xcodeproj` in Xcode. In the **PocketPort** target’s **Signing & Capabilities**, select your Apple development team. If you are building with a separate team, use a bundle identifier registered to your team. Select your iPhone and press Run.

On the phone, open **PocketPort**, tap **Scan**, and point the camera at the QR in Terminal. Allow Camera and Local Network access on the first use. The app opens the file after saving it, and the helper exits when it receives the acknowledgment. Each new share makes a separate import. Folder names appear as project labels unless the helper is given `--project`.

## Troubleshooting

- If the phone can’t reach the Mac, check that both devices joined the same Wi-Fi and that the helper is still running. Guest networks may isolate devices. If macOS asks whether to allow incoming connections, allow access for the helper on your trusted network.
- If Camera or Local Network access is denied, turn it on in iPhone Settings for **PocketPort**, then try again.
- A share expires after three minutes. Run `pocket-port` again for a fresh QR. Keep the Mac’s lid open while sharing.
- Local linked assets are outside v1. PocketPort displays Markdown image alt text and keeps the source file as imported.

## Verify on an iPhone

1. Join the same trusted Wi-Fi with both devices. Disconnect the router’s WAN connection while leaving local Wi-Fi on. Turn off cellular data on the phone.
2. Share two different files named `PLAN.md`, one from each project folder. Use a relative path for one and an absolute path for the other. Confirm that each opens after **Saved offline** and that the library shows both labels.
3. Close any running helper, force-quit the app, enable airplane mode with Wi-Fi off, and reopen the app. Open both files and check their contents.
4. Leave an unused share open until it expires, then scan its QR. Confirm the phone reports expiry. Run a fresh share and interrupt Wi-Fi during the download. Confirm there is no **Saved offline** message or new row for the interrupted attempt. Restore Wi-Fi and retry while the share is active. To give yourself time to interrupt a large test file, run `POCKETPORT_SLOW_TRANSFER=1 swift run pocket-port "/absolute/path/to/PLAN.md"` from this project root.
5. Open a plan with a wide table, a nested checklist, and a long fenced code block. Check horizontal scrolling, light and dark modes, and large text.

Use `swift test` for the Mac package. The shared **PocketPort** Xcode scheme includes app tests. See the [implementation plan](docs/superpowers/plans/2026-11-21-pocketport-implementation-plan.md) for the full device matrix.

The CLI uses Apple’s Network framework. The app uses Foundation’s Markdown parser and native SwiftUI block views. Neither build needs an external Swift package.

[Privacy policy](docs/privacy.md)
