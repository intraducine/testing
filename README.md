# Synthetic Iridium Live Activity captures

An isolated simulator demo for the exact production Iridium commit
[`f9187c8eeeda4f2b986744f4a003ec6d5643708d`](https://github.com/intraducine/iridium/tree/f9187c8eeeda4f2b986744f4a003ec6d5643708d).
It uses the unchanged Activity attributes, presentation, widget and app Activity
coordinator. A small synthetic job model replaces the Steam engine. No account,
real download, commercial artwork, game save, private credential or runtime build
is involved. Original Iridium code and this derived harness use AGPL-3.0-only;
the unchanged license is included in LICENSE.

The app provides native buttons for preparing, downloading, checking/verifying,
finishing, paused, foreground handoff, stale, failed, completed, long-title and
large-text fixtures, plus cancellation. The real coordinator requests local
ActivityKit activities, forces updates and applies its terminal dismissal policy.
The production Cancel intent resolves only to the synthetic model. No private
signing credentials are used: the simulator targets use anonymous ad-hoc signing.

## What the images establish

- **Components:** 66 PNGs from real production SwiftUI views; three contact sheets.
  These are not system containers. The expanded component is the Island's bottom
  card; compact/minimal components are also saved separately. A magenta 160-point
  clipping probe exposes overflow. No rows are shrunk or hidden to pretend they fit.
- **App screenshots:** real simulator app with synthetic controls and production card.
  This is a small demo host, not the full Iridium library screen/runtime.
- **Home Screen / expanded Island attempts:** native XCTest screenshots after Home
  and a touch-and-hold at the Island. Registration/status and accessibility probes
  are recorded. Inspect pixels before claiming the requested presentation is visible.
- **Notification Center:** native screenshots after a pull-down, showing the system
  Lock Screen-style presentation when supported. The device is not actually locked;
  passcode authentication, redaction and locked-screen cancellation are not tested.

The coordinator uses its production 80-character title limit and 30-second stale
deadline. The stale capture waits 35 seconds without updates. Terminal activities
can disappear from Dynamic Island while remaining on the Lock Screen-style surface
for the production 60-second dismissal period. Those absences are relevant results,
not replaced with component mockups. App/component large text uses accessibility3;
system Dynamic Type is unchanged. Minimal Island placement is a component diagnostic,
not a multi-app system test. StandBy, iPad, Watch and physical devices are untested.

Apple describes these system-selected presentations in its
[ActivityKit documentation](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

## One bounded Actions run

Only pushes that change capture files on **activity-capture-f9187c8** trigger the
workflow. There is no schedule, PR trigger or auto-retry. Permissions are
`contents: read`; checkout credentials are not persisted. Official checkout and
artifact actions are pinned to immutable SHAs. The macos-26 job has a 25-minute
limit and artifacts expire after three days. It uses only an already-installed
iOS 18+ runtime and a new disposable Dynamic Island iPhone simulator, then attempts
both shutdown and deletion. No SDK or third-party tool installation is attempted.

The launcher verifies all four source SHA256 values and the upstream checkout
commit before generating the Xcode project. No upstream file is edited.

```sh
python3 -B -m unittest discover -s scripts -p 'test_*.py'
python3 -B scripts/capture.py --upstream /path/to/exact/iridium --output .artifacts
```

Local Python tests validate pins, target boundaries, Info plists, scheme, PNG checks,
attachment naming and the Linux guard. They do not establish Swift compilation or
ActivityKit availability. Native build, UI interaction and screenshot export happen
in the reviewed Actions run. A failed native command remains a failed job; partial
artifacts and commands.log are retained where available.

## Retrieve and view

Open the run's artifact list. First download **activity-preview-COMMIT**, which
contains the small component contact sheets, selected scaled native screenshots,
manifest, environment, full compiler/test command log and checksums. Preview PNGs
are bounded to 20 MiB total. Use **activity-captures-COMMIT** for original component
and native screenshot PNGs plus XCTest observations and app events. No .app,
Apple SDK, signing material or full xcresult is uploaded.

Download the small preview artifact first and inspect the PNGs alongside the manifest. Each image is labeled as a component, app screenshot, or requested system surface. A requested Island or Notification Center capture does not establish visibility until its pixels are inspected.
