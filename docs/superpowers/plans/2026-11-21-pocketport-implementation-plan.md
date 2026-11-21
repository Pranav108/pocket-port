# PocketPort Implementation Plan

**Goal** — Run `pocket-port ./PLAN.md` on a Mac, scan once in PocketPort, and read the saved file after the helper exits and the iPhone goes offline.

**Architecture** — A foreground Mac command snapshots one file and exposes it through a temporary HTTP endpoint. The SwiftUI app validates the QR, downloads and commits the original bytes to its private storage, then acknowledges the save. Imported Files and Reader both use the local store.

**Baseline** — The PocketPort workspace is empty. The paths below are proposed. The starting targets are iOS 17 and macOS 14, using Swift, Swift Package Manager, and Xcode. The supplied coding brief is the v1 spec.

**Scope** — One Markdown file per share, trusted local Wi-Fi, Terminal installation, and an iPhone app. Finder integration and transfer of linked assets are later features. The app stores imports on-device and excludes the import directory from backup. Internet access may be needed during setup to resolve Swift packages and provision the iPhone.

## Build order and exit criteria

| Milestone | Deliverable | Exit criterion |
| --- | --- | --- |
| 1. One offline import | Mac helper, scanner, transfer, local store, Imported Files, basic Reader | On a physical iPhone, scan a real terminal QR, see **Saved offline**, stop the helper, relaunch offline, and reopen the file. Verify ATS and both permission prompts on the device. |
| 2. Complete Reader | Native block layout and fixture-tested parser | Two real agent-generated plans pass the layout review. A focused fixture covers a table, a nested checklist, and long fenced code. |
| 3. v1 acceptance | Fault handling, device matrix, and install instructions | Two same-named plans import with router internet disconnected, reopen separately in airplane mode, and pass the expiry, retry, and interrupted-download checks. |

## Proposed project layout

| Path | Responsibility |
| --- | --- |
| `Package.swift`, `Sources/PocketPortProtocol/`, `Tests/PocketPortProtocolTests/` | Shared v1 link grammar, response metadata, constants, and protocol tests |
| `Sources/PocketPortCLI/`, `Tests/PocketPortCLITests/` | File snapshot, listener, terminal QR, power assertion, and command tests |
| `PocketPort/PocketPort.xcodeproj`, `PocketPort/App/Info.plist` | iPhone target, signing, capabilities, and display name `PocketPort` |
| `PocketPort/App/ImportedFiles/`, `PocketPort/App/Scanner/` | Library navigation, scan sheet, permission actions, and import status |
| `PocketPort/App/Import/`, `PocketPort/App/Storage/` | Request lifecycle, errors, atomic file commits, and reopen |
| `PocketPort/App/Reader/`, `PocketPort/Tests/Fixtures/` | Block mapping, SwiftUI rendering, and real and focused Markdown fixtures |
| `PocketPort/Tests/`, `PocketPort/UITests/` | App tests and UI tests with injectable scanner and transport |
| `README.md` | Install and launch instructions, troubleshooting, and device acceptance commands |

Keep the root Swift package’s protocol target Foundation-only and usable on both platforms. Link iOS to the protocol product only. Scope the CLI and its SwiftNIO dependencies to the Mac executable. Check in the app scheme and the resolved versions used by the CLI and Xcode builds. Set the iPhone app’s development team and bundle identifier when signing the device build.

## 1. Lock the v1 transfer contract

Use a single versioned link format in both targets. This example uses placeholders.

```text
http://pranavs-mac.local:49152/share-md/v1/<share-uuid>/file#token=<token>&expires=<unix-seconds>
```

- [ ] Implement `ShareLink.init(scannedValue:)`, `qrString`, `downloadURL`, and `acknowledgmentURL` in `Sources/PocketPortProtocol/ShareLink.swift`. Accept only `http`, one DNS label under `.local`, an explicit port from 1 to 65535, the exact v1 path with a canonical lowercase UUID, and the two canonical fragment fields shown above. Reject credentials, query strings, encoded path or host components, duplicate or unknown fields, extra suffixes, IP literals, and oversized input. Rebuild the request URLs with URL components from validated fields. Request URLs omit the fragment.
- [ ] Generate a new UUID and 32 cryptographically random bytes per invocation. Encode the token as canonical unpadded base64url (43 characters). Set a 180-second server lifetime from listener readiness using a monotonic clock. Put the wall-clock expiry in the QR for iPhone messaging. The server deadline governs access. The app rejects a scan locally after the advertised deadline plus 30 seconds for clock skew, and uses the advertised deadline to explain expiry when the listener has already exited. Keep token and full QR values out of diagnostics and persistent metadata.
- [ ] Use `Authorization: Bearer <token>` on both requests. Give the server only these two routes for the active share ID. Map a wrong ID or token to a generic `404`. Use `410` for an authorized GET or unaccepted ACK observed after the deadline while teardown is in progress. Once the process exits, classify expiry from the scanned deadline on connection failure. Use a fixed-time comparison for the token.

| Request | Success | Contract |
| --- | --- | --- |
| `GET /share-md/v1/<share-uuid>/file` | `200 OK` | Raw UTF-8 Markdown bytes, `Content-Type: text/markdown; charset=utf-8`, mandatory `Content-Length`, and `Cache-Control: no-store`. |
| `POST /share-md/v1/<share-uuid>/ack` | `204 No Content` | Empty request body. The app sends this only after the local commit succeeds. Accept duplicate ACKs during a bounded response drain. Disable downloads as soon as the first valid ACK is accepted. |

- [ ] Define `ShareMetadata` in `Sources/PocketPortProtocol/ShareMetadata.swift`. The GET includes `X-ShareMD-Filename` and optionally `X-ShareMD-Project`, each unpadded base64url over UTF-8 text, plus `X-ShareMD-SHA256` as 64 lowercase hex digits over the raw body. Reject missing or malformed required fields, invalid UTF-8, and over-limit metadata. Bound the filename and label to 1 KiB and 256 UTF-8 bytes respectively. The filename is a basename and the label is display text. Neither becomes a local path. Set a 5 MiB inclusive file limit. Preserve original bytes, including a UTF-8 BOM, CRLF, and empty content. The digest checks byte integrity. HTTP provides no peer authentication or confidentiality.
- [ ] Verify QR round-trip, hostile and malformed inputs, expiry arithmetic, Unicode filename and label round-trip, and exact metadata bounds with `swift test --filter PocketPortProtocolTests`. Include one checked-in wire example with fixed bytes and digest so both targets can test against the same contract.

## 2. Deliver the Mac command

- [ ] Implement `FileSnapshot.load(path:projectLabel:)` in `Sources/PocketPortCLI/FileSnapshot.swift`. Resolve relative paths from the caller’s working directory and accept absolute paths. Accept regular, readable `.md` and `.markdown` files case-insensitively, including symlinks to regular files. Open in nonblocking mode, check the descriptor with `fstat`, then perform a bounded read. Reject directories, special files, invalid UTF-8, and oversized files before opening the listener. Use the selected basename and default the project label to its parent folder’s basename. Support `--project <label>` for nested plans and duplicate folder names, and `--` for filenames starting with a dash. The snapshot is immutable for the session. Filesystem paths stay on the Mac.
- [ ] Implement `ShareServer` in `Sources/PocketPortCLI/ShareServer.swift` with SwiftNIO HTTP/1 parsing and a single serialized session state. Obtain the Mac’s Bonjour local hostname with System Configuration and advertise its `.local` URL. Bind an OS-assigned TCP port reachable on the trusted LAN. Verify that the listener handles IPv4 and IPv6 addresses the hostname advertises, starting with an IPv6 socket configured for dual-stack. If the address and listener behavior differ on a supported Mac, fix that binding before device acceptance and keep the QR format unchanged. Bound request headers, reject request bodies, close each connection after responding, and use a short request timeout. Build responses from the in-memory snapshot. Keep serving GET after an interrupted download. Reject new GET requests on ACK or expiry, bound the ACK write/flush drain to one second, and close child connections, listener, and event loop during teardown.
- [ ] Implement `TerminalQR.render(_:)` in `Sources/PocketPortCLI/TerminalQR.swift` with Core Image QR generation. Render high-contrast modules with a four-module quiet zone, explicit foreground and background, and enough terminal width to prevent wrapping. Print filename, project label, expiry, and Ctrl-C guidance. Check legibility in light and dark Terminal profiles on the phone camera. Report a narrow terminal or unusable local hostname before presenting a share.
- [ ] Acquire a macOS `PreventUserIdleSystemSleep` power assertion before displaying the QR. Release it on ACK, expiry, Ctrl-C, SIGTERM, and startup failures after acquisition. Keep the Mac’s lid open during sharing. Give readable failures for bind, input, QR rendering, or power assertion setup.
- [ ] Verify the helper with `swift test --filter PocketPortCLITests`. Exercise wrong token and route, source edit after snapshot, early connection drop with retry, parallel GET/ACK, expiration while streaming, ACK followed by listener shutdown, signal cleanup, and files in two directories with identical basenames. Use an injectable timeout/clock or short-lived test session, then smoke-test the actual terminal QR and verify the assertion appears and disappears with `pmset -g assertions`.
- [ ] Document a one-time install and smoke-test it from another project directory. Install in a user-owned PATH directory. Build and install once during setup, then run the binary directly for each share.

```sh
swift build -c release --product pocket-port
mkdir -p "$HOME/.local/bin"
install -m 755 "$(swift build -c release --show-bin-path)/pocket-port" "$HOME/.local/bin/pocket-port"
export PATH="$HOME/.local/bin:$PATH"
pocket-port --help
pocket-port ./PLAN.md
```

Persist the PATH entry in the user’s shell configuration if needed. The last command runs from the project containing the plan. Help and errors should work without opening a listener.

## 3. Import and reopen one file on a physical iPhone

- [ ] Build `ImportedFilesView` around `NavigationStack` and `List`, with an empty state, toolbar **Scan** button, and `navigationDestination` to Reader. Sort newest first with a stable ID tie-breaker. Show filename, optional project label, and import date. Use the share UUID as row identity so distinct sessions remain separate even when their filenames, bytes, and labels match.
- [ ] Build `ScannerSheet` and `CameraScanner` around `AVCaptureSession`, `AVCaptureMetadataOutput` with `.qr`, and a preview layer. Check or request camera permission when Scan opens. Start and stop capture on a dedicated serial queue. Pause while validating and downloading, debounce repeated metadata callbacks, stop when dismissed or backgrounded, and release the camera between scans. Offer **Open Settings** for denial and show an unavailable state for a restricted or missing camera.
- [ ] Add the following keys to the app’s effective Info.plist. Make the first local request while the app is foregrounded so the system can show its permission prompt. The app connects to the named host in the QR. This flow uses no Bonjour service discovery or service registration on iPhone.

| Key | Value |
| --- | --- |
| `CFBundleDisplayName` | `PocketPort` |
| `NSCameraUsageDescription` | Scan the QR code shown by pocket-port on your Mac. |
| `NSLocalNetworkUsageDescription` | Connect to your Mac over Wi-Fi to import Markdown files. |
| `NSAppTransportSecurity.NSAllowsLocalNetworking` | `YES`. Keep the broad arbitrary-loads exceptions off. |

- [ ] Implement `TransferClient.download(_:) async throws -> DownloadedMarkdown` and `acknowledge(_:) async throws`. Use an ephemeral `URLSession` with no caches or cookies, `waitsForConnectivity`, and a redirect delegate that refuses every redirect. Use bounded requests (20 seconds overall for GET, 3 seconds per ACK attempt), cancellation, and a 5 MiB streaming cap. Check status, media type, and the required headers before accepting bytes. Require exact length, matching SHA-256, and valid UTF-8 before calling storage. Send the same GET on explicit retry while the share is active. Treat short, oversized, mismatched, or cancelled bodies as incomplete imports. Probe the same host and port with `NWConnection` on a connectivity wait or failure to identify `.localNetworkDenied`; avoid reporting denial while the system prompt is pending. Wrong host, missing permission evidence, or timeout goes through the general connection error. Avoid a separate foreground permission alert before the system prompt.
- [ ] Implement an actor-backed `ImportStore` with `commit(_:shareID:)`, `list()`, and `read(id:)` in `PocketPort/App/Storage/ImportStore.swift`. Under Application Support, create a backup-excluded `Imports` directory. Write `document.md` and a versioned `metadata.json` into a staging directory under the same parent, then rename it into the final UUID directory as the commit point. Metadata records the original filename, optional project label, import timestamp, byte count, and digest. Index committed directories only, remove abandoned staging directories on launch, and keep readable rows when another record is damaged. A retry of an already committed ID returns the existing record and keeps its timestamp. The store alone decides when the import is durable for app relaunch.
- [ ] Implement the import coordinator as one task per scan. Drive UI through scanning, connecting/downloading, saving, committed, or recoverable failure. After commit, dismiss the sheet, show accessible **Saved offline** feedback in the Reader, and start ACK. On an ambiguous ACK failure, make one bounded retry while within the share window. If ACK still fails or the app closes immediately after commit, the file stays in Imported Files and the helper expires. A rescan of an active, already committed share reopens the saved copy and can ACK again. Cancellation before commit produces no visible import. A completed commit remains visible if cancellation arrives afterward.
- [ ] Verify with app unit tests and a simple local-text Reader first. Inject response and disk failures, an ACK failure after commit, and two simultaneous commits for the same ID. Assert that the two different IDs with filename `PLAN.md` stay distinct. Recreate the store from disk, assert byte-for-byte equality, and open a stored item through normal navigation with networking disabled. Assert that a cancelled or truncated transfer produces neither a row, a success message, nor an ACK.
- [ ] Prove the vertical slice on a signed physical iPhone. Scan the actual `.local` HTTP QR after a fresh install, accept both prompts, and capture app errors and sanitized Mac logs if it fails. Test from a clean permission state and after revoking each access in Settings. If `.local` fails, isolate hostname resolution, TCP binding and firewall, Local Network permission, and ATS before proceeding. Keep the scoped ATS configuration as the device acceptance baseline.

### Import error copy

| Condition | Message and action |
| --- | --- |
| QR format or version is invalid | **This QR code isn’t a PocketPort link.** Continue scanning. |
| Camera denied | **Allow Camera access to scan a PocketPort code.** Open Settings. |
| Local Network denied | **Allow Local Network access so PocketPort can reach your Mac.** Open Settings, then Retry. |
| DNS, TCP, or timeout with an active link | **Couldn’t reach your Mac.** Check that both devices are on the same Wi-Fi and the helper is running. Retry. |
| Expired | **This share link expired.** Run `pocket-port` again and scan the new code. |
| Live listener rejects share | **This share is no longer available.** Scan a fresh code. |
| Body interrupted or invalid | **The download didn’t finish or couldn’t be verified.** Retry while the link is active. |
| Disk write fails | **Couldn’t save this file on your iPhone.** Check available storage and retry. |

## 4. Validate the parser and build the native Reader

- [ ] Gather two real agent-generated plans before selecting the parser. Use this implementation plan as one and a recent actual project plan as the other. Keep private plans local or use a sanitized copy for checked-in fixtures. Add a focused `ReaderStress.md` fixture for missing cases. Include mixed ordered and unordered nesting, checked and unchecked tasks, long cell content, inline links, a quote, raw HTML, remote and relative images, and a long fenced shell command. The focused fixture supplements both real plans.
- [ ] Spike [Swift Markdown](https://github.com/swiftlang/swift-markdown) in a small native preview using both plans. Inspect its cmark-gfm-backed AST for table headers and alignment, list start numbers, task states, nested list structure, and fenced code whitespace. Render those nodes at an iPhone width and at an accessibility text size before committing the dependency. Compare a second maintained GFM AST parser only if the candidate fails the fixture or toolchain gate. Record the fixture results and pin the passing compatible tagged release in Xcode.
- [ ] Implement `MarkdownBlockMapper.blocks(from:)` and `ReaderView(importID:)`. Read bytes from `ImportStore`; parse off the main actor and present a lazy vertical stack of native views. Render semantic heading levels, selectable paragraphs and inline emphasis, quotes with nested children, lists with starting numbers and recursively nested items, and read-only task indicators with VoiceOver value. Use a leading-aligned grid in a horizontal scroll container for tables and monospace selectable text in a separate horizontal scroll container for fenced code. Preserve code indentation and line breaks. Keep prose within the screen width, use semantic text styles, cap visual indentation at large sizes without flattening list semantics, and use system colors in light and dark modes.
- [ ] Render ordinary `http`, `https`, and `mailto` links as user-initiated actions. Represent relative links as text, use image alt text only, and omit raw HTML nodes from formatted output. Keep original bytes available in storage. Keep formatting and its previews independent of network access. Handle an empty file with an empty document message and a missing import with a local read error.
- [ ] Verify parsed block types and nesting in unit tests, including that unsafe link schemes, images, and HTML produce no loadable destinations. Check rendered output in the simulator and on a phone. Test default and accessibility text sizes, light and dark modes, VoiceOver heading navigation and checklist state, and horizontal scrolling for tables and code without shifting the rest of the Reader.

## 5. Run the physical acceptance matrix

Install a signed build on an iPhone and the release helper on a Mac. Keep both on the same trusted Wi-Fi SSID with client-to-client traffic available. Disconnect the router’s WAN connection while leaving its Wi-Fi network running. Turn off cellular data for this transfer run to establish the offline condition. Use two different project folders with distinguishable `PLAN.md` fixtures and record each source SHA-256.

| Check | Exercise | Pass condition |
| --- | --- | --- |
| Two distinct offline imports | From Folder A, run `pocket-port ./PLAN.md`. Share Folder B using an absolute path, from another working directory. Scan each QR. | Each import says **Saved offline**, opens Reader, and causes the helper to exit after ACK. Imports show two `PLAN.md` rows with their respective project labels. Verify bytes against the source digests. |
| Reopen offline | Stop any helper, force-quit the app, enable airplane mode with Wi-Fi off, and relaunch. | Both rows remain and each opens its own content. Reader performs no transfer request. |
| Expired link | Use a second display to retain the QR for an unused share. Scan after the advertised lifetime and clock-skew window. Also test an authorized request crossing expiry in automated tests. | Phone shows the expired message. No row appears and the helper has exited. |
| Interrupted download and retry | Serve a reasonably large Markdown fixture with debug-only server pacing. Interrupt Wi-Fi after receiving body bytes. Rejoin before expiry and tap Retry. | Interrupted attempt shows an error with no success or new row. Retry saves exactly one complete copy and closes the helper. |
| Failure after local commit | Drop the ACK response, or kill the app immediately after committing and reopen it. | Saved file remains readable and no duplicate appears. The helper exits after an accepted ACK or the normal timeout. |
| Permissions and reachability | Deny Camera, deny Local Network, and try an active QR with the Mac unreachable in separate runs. Restore permissions or reachability and retry. | The app gives the matching error and recovery action. A restored connection imports successfully within the share window. |
| Reader layout | Open the realistic plan on device at default and accessibility sizes in light and dark modes. | Nested checklist state is legible, table cells stay aligned, long code scrolls horizontally, and surrounding text wraps. |

- [ ] Record the Mac and iPhone OS versions, app revision, and acceptance results in the testing section of `README.md`.
  - [ ] Run `swift test` for the protocol and CLI, and the shared Xcode scheme for app tests and simulator UI tests.
  - [ ] For the signed development build, download the app container in Xcode and compare each committed `document.md` with its original using `shasum -a 256`.
  - [ ] Attach physical-device results for camera, `.local` ATS and privacy behavior, WAN-disconnected transfer, and airplane-mode reopen.

## Shared and untrusted Wi-Fi release gate

Keep the HTTP prototype on trusted Wi-Fi. Before expanding support, design a separate protocol version with standard TLS and per-session server authentication. A candidate is a short-lived server certificate and a public-key fingerprint carried in the QR. The phone would verify the presented key against that fingerprint and send the random token only after successful verification. Review the trust model and test wrong pins, altered QR content, token replay, and downgrade attempts before claiming support for untrusted networks.

## Platform references

- [Apple’s local network privacy technote](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple’s scoped App Transport Security setting for local networking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
- [AVFoundation capture authorization](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media) and [metadata capture](https://developer.apple.com/documentation/avfoundation/avcapturemetadataoutput)
- [macOS idle sleep assertion](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep) and [Bonjour local hostname API](https://developer.apple.com/documentation/systemconfiguration/scdynamicstorecopylocalhostname(_:))
- [SwiftNIO HTTP server example](https://github.com/apple/swift-nio/tree/main/Sources/NIOHTTP1Server) and [Swift Markdown releases](https://github.com/swiftlang/swift-markdown/releases)
