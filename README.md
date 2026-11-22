# PocketPort

Share Markdown, plain text, HTML, PDFs, and images from your Mac to your iPhone over trusted Wi-Fi. The helper opens a temporary HTTP share, and the iPhone keeps a byte-for-byte copy for offline viewing.

## Install the Mac helper

### One-line install from GitHub

Paste this into Terminal on macOS 14 or later, on Apple Silicon or Intel. The command installs `pocket-port` from GitHub’s `main` branch into `~/.local/bin`. Rerun it to update.

```sh
curl -fsSL https://raw.githubusercontent.com/Pranav108/pocket-port/main/install.sh | bash -s -- --add-to-path
```

Open a new Terminal window and verify the install.

```sh
command -v pocket-port
pocket-port --help
```

The `--add-to-path` flag adds `~/.local/bin` to your zsh or Bash startup file when needed. If you have neither Xcode nor the Command Line Tools, run the following command first and wait for Apple’s installer to finish. [Read the installer script](install.sh)

```sh
xcode-select --install
```

### macOS installer package

Download the signed `pocket-port-<version>-macos-universal.pkg` when it is available on [GitHub Releases](https://github.com/Pranav108/pocket-port/releases). Open it to install or update `pocket-port`. The installer works on Apple Silicon and Intel, and it installs to `/usr/local/bin`. It requires neither Xcode nor Homebrew. Check the install in Terminal with `pocket-port --help`.

### Manual build from source

This option is available before the first installer release. It requires Xcode or the Xcode Command Line Tools.

```sh
git clone https://github.com/Pranav108/pocket-port.git pocket-port
cd pocket-port
swift build -c release --product pocket-port && mkdir -p "$HOME/.local/bin" && install -m 755 "$(swift build -c release --show-bin-path)/pocket-port" "$HOME/.local/bin/pocket-port"
```

If Terminal cannot find the source-built command, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and reopen Terminal. To update from source, pull the branch you use and repeat the build and install command. If you switch from a source build to a package, use `command -v pocket-port` to check which copy your shell runs.

## Share a file

Connect your Mac and iPhone to the same trusted Wi-Fi network. The iPhone app requires iOS 17 or later. Run the command from any folder.

```sh
pocket-port
```

Run `pocket-port` without arguments to share the only eligible file in the current folder. If several files are eligible, pass the filename or path. Use a relative path for a file in a subfolder, and quote paths that contain spaces.

```sh
pocket-port PLAN.md
pocket-port report.pdf
pocket-port report.html
pocket-port "designs/App Icon.png"
pocket-port --project "Release planning" "/path/to/another/PLAN.md"
```

Supported extensions are `.md`, `.markdown`, `.txt`, `.htm`, `.html`, `.pdf`, `.bmp`, `.gif`, `.heic`, `.heif`, `.jpeg`, `.jpg`, `.png`, `.tif`, `.tiff`, and `.webp`. A file named `README` also works. Markdown, text, and HTML files must be UTF-8 and can be up to 5 MiB. PDFs and images can be up to 25 MiB. PocketPort also accepts QR codes from earlier versions of the Mac helper.

HTML files open as offline previews. Use a self-contained page with HTML and embedded styles. JavaScript, automatic network requests, and external navigation are disabled.

## Share directly with a paired device

Keep PocketPort open on the receiving iPhone or iPad. Both devices need a trusted Wi-Fi network that permits local peer connections and Bonjour.

1. Run `pocket-port pair` on your Mac. In PocketPort, open **Settings → Paired Computers → Add Computer**.
2. Select the Mac, enter the six-digit code from Terminal, and compare the Mac fingerprint shown on both screens. Tap **Trust Computer**.
3. Send a file after Terminal confirms pairing.

```sh
pocket-port devices
pocket-port send "docs/Release Notes.md" --to iphone
pocket-port default iphone
pocket-port send README.md
pocket-port send -t iphone,ipad README.md
pocket-port send README.md -t all
```

If you omit the file, `send` uses the only eligible file in the current folder. If you omit the target, PocketPort uses the default or the only paired device. When several devices are paired without a default, Terminal prompts you to select one. A noninteractive session needs an explicit target or a default.

Use `pocket-port rename iphone personal-phone` to change an alias, `pocket-port default --clear` to clear the default, and `pocket-port unpair personal-phone` to remove trust locally. On the iPhone, tap a computer in **Paired Computers** to rename its alias or remove it. Removing a device on either side prevents future transfers until you pair it again.

The one-line installer adds `pocketport` and `pp` shortcuts when those names are available. After a package or manual install, you can add `alias pp=pocket-port` to your shell profile if the name is free. Existing QR sharing still starts with `pocket-port <file>`.

If a transfer is interrupted or Terminal can’t confirm the receipt, run the same command again with the same file and target. PocketPort retains the transfer ID for 24 hours so an already saved copy can be acknowledged without importing it twice. For multiple targets, Terminal prints a result for each device and exits with an error if any transfer is unconfirmed.

The app receives files while active in the foreground. Guest Wi-Fi can block local communication even when both devices use the same network. See the [pairing and direct transfer protocol](docs/direct-transfer-protocol.md).

## Install the iPhone app

PocketPort is currently available as source. A TestFlight invitation or App Store listing will let users install it directly on their iPhone once an iOS build is distributed. See the [release guide](docs/distribution.md) for how to publish each part.

For local development, open `PocketPort/PocketPort.xcodeproj` in Xcode. In the **PocketPort** target’s **Signing & Capabilities**, select your Apple development team. If you are building with a separate team, use a bundle identifier registered to your team. Select your iPhone and press Run.

On the phone, open **PocketPort**, tap **Scan**, and point the camera at the QR in Terminal. Allow Camera and Local Network access on the first use. The app opens the file after saving it, and the helper exits when it receives the acknowledgment. Each new share makes a separate import. Folder names appear as project labels unless the helper is given `--project`.

## Troubleshooting

- If the phone can’t reach the Mac, check that both devices joined the same Wi-Fi and that the helper is still running. Guest networks may isolate devices. If macOS asks whether to allow incoming connections, allow access for the helper on your trusted network.
- If Camera or Local Network access is denied, turn it on in iPhone Settings for **PocketPort**, then try again.
- A share expires after three minutes. Run `pocket-port` again for a fresh QR. Keep the Mac’s lid open while sharing.
- Local linked assets are outside v1. PocketPort displays Markdown image alt text and keeps the source file as imported.

## Mermaid diagrams

Markdown code blocks tagged `mermaid` render as diagrams in the iPhone reader. The renderer is bundled with the app, so diagrams work offline. Expand **Diagram source** to see the original code. If rendering fails, PocketPort shows that code directly.

## Verify on an iPhone

1. Join the same trusted Wi-Fi with both devices. Disconnect the router’s WAN connection while leaving local Wi-Fi on. Turn off cellular data on the phone.
2. Share two different files named `PLAN.md`, one from each project folder. Use a relative path for one and an absolute path for the other. Confirm that each opens after **Saved offline** and that the library shows both labels.
3. Close any running helper, force-quit the app, enable airplane mode with Wi-Fi off, and reopen the app. Open both files and check their contents.
4. Leave an unused share open until it expires, then scan its QR. Confirm the phone reports expiry. Run a fresh share and interrupt Wi-Fi during the download. Confirm there is no **Saved offline** message or new row for the interrupted attempt. Restore Wi-Fi and retry while the share is active. To give yourself time to interrupt a large test file, run `POCKETPORT_SLOW_TRANSFER=1 swift run pocket-port "/absolute/path/to/PLAN.md"` from this project root.
5. Open a plan with a wide table, a nested checklist, and a long fenced code block. Check horizontal scrolling, light and dark modes, and large text.

Use `swift test` for the Mac package. The shared **PocketPort** Xcode scheme includes app tests. See the [implementation plan](docs/superpowers/plans/2026-11-21-pocketport-implementation-plan.md) for the full device matrix.

The CLI uses Apple’s Network framework. The app uses Foundation’s Markdown parser and native SwiftUI block views, with Mermaid.js 12.3.0 for diagrams. Both builds include a small, vendored Mbed TLS EC J-PAKE implementation for pairing and need no external Swift package.

[Privacy Policy](https://pranav108.github.io/pocket-port/privacy.html) · [Terms of Use](https://pranav108.github.io/pocket-port/terms.html) · [Support](https://pranav108.github.io/pocket-port/)
