# ClearSpace

An iPhone-only SwiftUI storage cleaner. Everything runs on-device using Apple frameworks only:
no backend, no login, no cloud, no payments, no third-party packages.

- Bundle ID: `com.rohittkr.clearspace` (widget: `com.rohittkr.clearspace.widget`)
- Minimum iOS: 17.0, iPhone only
- Language / UI: Swift 5 mode, SwiftUI

## Important honesty note
This project was written and statically reviewed in an environment with **no Xcode, no Swift compiler and no iOS
device**, so it has **not been compiled or run**. The code targets real, current APIs and was checked by hand,
but you may still see a few compiler warnings or, less likely, an error on first build. If Xcode shows one, copy the
exact message back and it can be fixed quickly.

## How to run on your iPhone 13
1. Unzip and double-click `ClearSpace.xcodeproj`.
2. In Xcode click the blue **ClearSpace** project in the left sidebar.
3. For **each of the two targets** (`ClearSpace` and `ClearSpaceWidget`): open **Signing & Capabilities**, keep
   **Automatically manage signing** ticked, and choose your **Personal Team** under *Team*.
4. If Xcode says a bundle ID is unavailable, change `com.rohittkr.clearspace` to something unique
   (e.g. `com.rohittkr.clearspace1`) on the app target, and `<same>.widget` on the widget target.
5. Plug in the iPhone, unlock it, tap **Trust** if asked. On the iPhone enable
   **Settings > Privacy & Security > Developer Mode** (it restarts the phone).
6. Choose your iPhone in the device menu at the top of Xcode and press **Run** (Cmd+R).
7. First launch: on the iPhone go to **Settings > General > VPN & Device Management**, trust your developer
   profile, then open ClearSpace again.
8. Free Personal Team apps expire after 7 days; just press Run again to reinstall.

To add the widget: long-press the Home Screen, tap **+**, search **ClearSpace**, add **Free Storage**.

## Features implemented
Required
- Storage Dashboard: total / used / free space (real device values), per-category counts and sizes, reclaimable estimates
- Similar Photos: Vision feature-print grouping, keep-best recommendation, sensitivity control, scan limit
- Screenshots: grid of screenshots, multi-select, review, delete
- Large Videos: sorted by size with thumbnail, date, duration, size, in-app preview
- Duplicate Contacts: matched on phone, email and normalized name, keep-best recommendation
- Review before delete for every destructive flow: "Will be removed", item list, counts, estimated space,
  "Confirm & Delete", then a "Space Freed" summary
- Photos permission states: not determined, authorized, limited (with manage-selection button), denied, restricted
- Contacts permission states, including iOS 18 `.limited` behind an availability check so it still compiles for iOS 17

Bonus
- Blurry photo detection (on-device sharpness heuristic with adjustable threshold)
- Swipe Cleanup (right = keep, left = mark, undo, still goes through Review)
- Video compression (creates a compressed copy; never deletes the original)
- Private Vault (Face ID / passcode via LocalAuthentication; photos copied into file-protected app storage)
- Calendar Cleanup (EventKit, old events, review before delete)
- Cleanup Summary (lifetime totals stored locally)
- WidgetKit widget showing free storage (small and medium)

## Known limitations (be upfront about these in your demo)
- **Not compiled or run** in the environment that produced it (see note above).
- Deleted photos go to Photos' *Recently Deleted* for 30 days; free space is fully released only afterwards.
  Apple does not let apps skip this.
- iOS shows its own confirmation dialog when an app deletes photos or videos. This is expected.
- Sizes for iCloud-only photos are estimates.
- Vault files live inside the app; deleting ClearSpace deletes the vault. Only photos (not videos) are supported.
- Similar Photos scans the most recent 1000 / 2000 / 5000 photos (your choice) to keep scans quick and memory-safe.
- Calendar cleanup on a recurring event removes only the chosen occurrence.
- The widget measures storage itself (same volume) rather than sharing data with the app, so no App Group is needed.
  It refreshes about every 30 minutes; iOS decides the exact timing.
- No unit tests are included.

## Testing steps (on the iPhone)
1. **Dashboard**: open the app, allow Photos. Ring, free/used/total and category cards should fill in.
   Compare free space with Settings > General > iPhone Storage.
2. **Permissions**: In Settings > ClearSpace > Photos choose *Limited*, reopen the app: a limited-access banner appears.
   Choose *None*: a permission screen with Open Settings appears. Restore *Full Access* afterwards.
3. **Screenshots**: open Screenshots, Select All, Review Selected. Check the "Will be removed" list and counts,
   then tap **Confirm & Delete**, accept the iOS prompt, and see "Space Freed". Try Cancel too: nothing is deleted.
4. **Large Videos**: confirm sort order largest first, tap one to preview, select one and go through Review.
   Try Compress on a short clip and confirm a new copy appears in Photos and the original remains.
5. **Similar Photos**: take 3 near-identical photos first. Run a scan, check the group shows a Keep badge,
   long-press another photo to change the keep photo, select the others and Review.
6. **Duplicate Contacts**: first create two test contacts with the same phone number. Allow Contacts, run scan,
   check the group and reason, review and delete only the duplicate.
7. **Blurry / Swipe / Calendar**: run each once. In Calendar create a test event dated over a year ago, select it,
   review, delete.
8. **Vault**: open Private Vault, authenticate, add one test photo, remove the original when Review appears,
   then Restore it. Background the app and reopen: it should require unlock again.
9. **Summary**: open Cleanup Summary and confirm the totals reflect what you deleted.
10. **Widget**: add the Free Storage widget and compare against the dashboard.

Use test data (not your real photos or contacts) when trying deletion for the first time.

## Project layout
```
ClearSpace.xcodeproj
ClearSpace/
  ClearSpaceApp.swift   Info.plist   Assets.xcassets
  Core/        Models, AppModel, PhotoServices, Theme, Utilities
  Components/  shared UI, ReviewView (the mandatory review screen)
  Features/    Home, Screenshots, Videos, SimilarPhotos, Contacts, Blurry, Swipe, Calendar, Vault, Summary
ClearSpaceWidget/  ClearSpaceWidget.swift  Info.plist  Assets.xcassets
```

## 2 to 3 minute demo script
- 0:00 Introduce: "ClearSpace is an on-device iPhone storage cleaner. No server, no account, nothing leaves the phone."
- 0:15 Dashboard: show the ring and free/used/total, point to category cards.
- 0:35 Screenshots: select a few, tap Review. Point out "Will be removed", the list, counts and estimated space.
  Confirm and show the iOS prompt and the **Space Freed** screen.
- 1:05 Large Videos: show the largest-first list and preview one. Mention compression keeps the original.
- 1:25 Similar Photos: run a scan, show a group with the Keep badge and sensitivity control.
- 1:50 Duplicate Contacts: show a group and why it matched, delete only the duplicate through Review.
- 2:10 Bonus tour: Swipe Cleanup, Private Vault with Face ID, Calendar Cleanup.
- 2:35 Widget on the Home Screen and Cleanup Summary.
- 2:50 Close: mention permissions handling, the review-before-delete rule, and the honest limitations above.
