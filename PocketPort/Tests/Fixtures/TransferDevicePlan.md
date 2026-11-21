# PocketPort on-device transfer test plan

Run this plan after installing a development build on the phone. Keep the router’s Wi-Fi on while disconnecting its internet connection. Leave the Mac lid open until the helper reports the save.

## Prepare two projects

1. Create two project folders with different names.
2. Put a different `PLAN.md` in each folder.
   - [x] Use the same basename in both folders.
   - [ ] Write a sentence that identifies each project clearly.
     - [ ] Put the identifying sentence near the top of the document.
3. Record the source digests before sharing. Compare these values with the copies in the iPhone app’s development container.

| Run | Input path | Expected outcome |
| :--- | :--- | :--- |
| First share | `./PLAN.md` | The project label matches the first folder. The Mac helper exits after it receives the acknowledgment. |
| Second share | An absolute path ending in `PLAN.md` | A second row appears and opens the document from the other folder. |
| Offline relaunch | Both rows in Imported Files | The documents still open after airplane mode and a full app relaunch. |

> If the Mac can’t be reached, confirm that the devices are on the same trusted Wi-Fi and that the router allows clients to communicate.

## Commands on the Mac

```sh
  swift build -c release --product pocket-port
  shasum -a 256 "$PWD/Acceptance Fixtures/Project One/PLAN.md" "$PWD/Acceptance Fixtures/Project Two/PLAN.md"
```

Run the first share from inside the first folder. Start the second from an unrelated working directory so the absolute-path case gets exercised.

## Verify recovery

- [ ] Scan the QR from an unused share after it expires. Confirm the app asks for a new code and the list contains the two saved files.
- [ ] Interrupt Wi-Fi while a new download is in flight. Confirm the failed attempt adds no row.
  - [ ] Restore Wi-Fi before the expiry window closes.
  - [ ] Tap **Retry** and verify one new saved copy.

See the [local network privacy technote](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) when investigating device permission behavior.
