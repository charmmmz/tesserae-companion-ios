# Synthetic Live Photo

`Sample.jpg` and `Sample.mov` were generated on 27 October 2026 using the moving
circle and coloured background from `SharedUI/MediaFrameFixtures.swift`.
They contain no camera footage or household data. The JPEG's Apple maker-note
asset identifier matches the movie's QuickTime content identifier; the movie
also includes a timed still-image marker at 1.5 seconds.

Import both files in one `simctl addmedia` call to create a genuine paired Live
Photo in the simulator's Photos library. `Scripts/test_system_photos_share.sh`
uses this asset to exercise Photos' real legacy item provider, which an in-app
fixture provider cannot reproduce.
