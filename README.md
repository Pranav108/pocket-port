# Share.md for Mac

Share a Markdown file from Terminal to Share.md on your iPhone. The helper shows a QR code and serves one file over trusted local Wi-Fi. The iPhone saves the original file for offline reading.

## Build and install

Use macOS 14 or later with Swift 5.9 or later. In Terminal, run:

```sh
git clone https://github.com/Pranav108/share.md.git
cd share.md
swift build -c release --product share-md
mkdir -p "$HOME/.local/bin"
install -m 755 "$(swift build -c release --show-bin-path)/share-md" "$HOME/.local/bin/share-md"
```

Make sure `$HOME/.local/bin` is on your PATH.

## Share a file

From any folder, run:

```sh
share-md
```

Choose a README by number. If there is only one matching README, the helper displays its QR right away. To share a specific Markdown file, pass its path directly:

```sh
share-md ./PLAN.md
share-md --project "Release planning" "/path/to/another/PLAN.md"
```

Open **Share.md → Scan** on the iPhone and point it at the terminal QR. Keep both devices on the same trusted Wi-Fi and leave the terminal open. Each share is available for up to three minutes and closes when the phone confirms the save. The helper accepts UTF-8 Markdown files up to 5 MiB.

## Run the tests

```sh
swift test
```
