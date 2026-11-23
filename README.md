# Photo Drop

A small Mac app that watches one folder, and every folder inside it, and adds new photos and videos to an album in Apple Photos. If iCloud Photos is turned on in Photos, they then upload to iCloud like anything else in your library.

It was made for a folder of exports from Capture One and other photo editors on an external drive. The folder chooser opens at `/Volumes/T7 Shield/Photos`, and the album is "Camera Photos" unless you pick another.

You need a Mac with Apple Silicon, macOS 26 or later, and Xcode 26 or later to build it.

## Build and run

### In Xcode

1. Open `PhotoDrop.xcodeproj`.
2. At the top of the window, choose the `PhotoDrop` scheme and "My Mac".
3. Press Run (Cmd-R).

Signing is already set up for a free personal team. If Xcode shows a signing error, click the project in the sidebar, pick the `PhotoDrop` target, open Signing & Capabilities and choose your own team (the "Personal Team" under your Apple ID). Do the same for `PhotoDropTests`.

To make that change stick, put your team ID in `DEVELOPMENT_TEAM` in `project.yml`. Otherwise it is lost the next time the project file is regenerated (see below).

### From Terminal

```
xcodebuild -project PhotoDrop.xcodeproj -scheme PhotoDrop -configuration Debug -derivedDataPath build build
```

The app ends up at `build/Build/Products/Debug/Photo Drop.app`.

### Install it for daily use

Quit Photo Drop if it is running, then copy the built app to Applications:

```
rm -rf "/Applications/Photo Drop.app"
cp -R "build/Build/Products/Debug/Photo Drop.app" /Applications/
```

Run it from there. "Open at login" remembers the copy you switched it on from, so only switch it on in the Applications copy.

Every copy of the app shares the same settings and the same record of imported files, so only one copy runs at a time. If you open a second copy (for example one from Xcode while the Applications copy is running), it brings the running one to the front and quits. To switch copies, quit the running one first.

### After adding, removing or renaming source files

`PhotoDrop.xcodeproj` is generated from `project.yml`, so regenerate it rather than editing it by hand:

```
xcodegen generate
```

If you do not have the tool: `brew install xcodegen`.

## Using it

The window has:

- **Watched folder** and a **Choose Folder…** button.
- **Photos album**: pick an existing album, or "New album…" to name a new one. The album is created in Photos when watching starts.
- **Watch for new photos**: the on/off switch. It stays off until you have chosen a folder.
- **Import a file after it has been unchanged for 60 seconds**: how long Photo Drop waits to be sure a file has finished copying. Click the arrows to change it, in steps of 5 from 5 to 600 seconds. A change takes effect straight away.
- A status line next to the switch, for example "Watching • 12 imported today", "Waiting for 3 files to finish copying", "Drive not connected" or "Photos access needed".
- A list of the last 100 imports and failures, with file, folder, time and result. Failures are shown in red with the reason.
- **Open at login**.

Closing the window does not quit the app; it keeps watching. Click the Dock icon to get the window back, and use Cmd-Q to quit.

The File menu has one more command, **Reset Import Record…**, explained below.

### The first time you watch a folder

Photo Drop asks "What about the photos already in this folder?" Pick one:

- **Treat everything already in this folder as imported**: skips everything that is there now and only adds what arrives from then on. Choose this if those pictures are already in Photos.
- **Import everything now**: adds every photo and video in the folder to Photos.

It asks once per folder, and again after the record of imported files is reset.

## Photos access

Turn on "Watch for new photos". The first time, macOS asks whether Photo Drop may use your Photos library. Allow full access.

Photo Drop needs full access because it has to find your album as well as add to it. Anything less (a limited selection, add-only, or "Don't Allow") counts as no: the status reads "Photos access needed" and nothing is imported.

To fix it later:

1. Open System Settings › Privacy & Security › Photos. The **Open Photos Privacy Settings…** button, which appears in the window next to the status when access is missing, takes you straight there.
2. Give Photo Drop full access.
3. Switch back to Photo Drop. It checks again and carries on by itself.

To be asked from scratch, quit Photo Drop and run:

```
tccutil reset Photos com.briancolclough.PhotoDrop
```

Open the app and turn the switch on, and macOS asks again.

## Reset the record of imported files

Photo Drop keeps a record of every file it has imported or been told to skip. To wipe it and start over, choose **File › Reset Import Record…** and confirm with **Reset**.

- Photo Drop forgets which files it has already imported, and the list in the window empties.
- Watching is switched off.
- The next time you switch watching on, it asks the first-time question again.

Nothing in Photos or in the folder is changed.

**Read this before you answer that question.** The record is the app's only memory. It does not look inside Photos to see what is already there.

- "Treat everything already in this folder as imported" rebuilds the record and adds nothing.
- "Import everything now" adds everything to Photos again, as duplicates of whatever is already there.

### Deleting the record by hand

You should not need this, but it works too:

1. Quit Photo Drop with Cmd-Q. Closing the window is not enough.
2. Delete the record in Terminal:

   ```
   rm ~/Library/Containers/com.briancolclough.PhotoDrop/Data/Library/Application\ Support/PhotoDrop/ledger.sqlite*
   ```

   macOS guards each app's data, so it may ask whether Terminal may access data from other apps. Allow it. If the command still says "Operation not permitted", use the menu command instead.
3. Open Photo Drop.

When Photo Drop finds the record gone, it asks the first-time question again, just as it does after the menu command. The difference is that the watching switch is left as it was, so if it was on, the question comes up as soon as the app opens.

## The rules it follows

- **File types.** Photos: `jpg`, `jpeg`, `heic`, `heif`, `png`, `tif`, `tiff`. RAW: `dng`, `arw`, `cr2`, `cr3`, `nef`, `raf`, `orf`, `rw2`. Videos: `mov`, `mp4`. Capital letters make no difference. Everything else is ignored.
- **Hidden files and folders are skipped.** That means anything whose name starts with a dot, and everything inside such a folder.
- **It waits until a file has finished copying.** A file is imported once its size and date have stayed the same for 60 seconds, or however long you set in the window. Empty files wait until they have something in them; one that stays empty for 10 minutes is left alone until it changes.
- **JPEG + RAW become one item.** A JPEG and a RAW file with the same name in the same folder are added to Photos as a single photo. Both must have stopped changing first.
- **Originals are never moved, changed or deleted.** Photos makes its own copy. Photo Drop only has permission to read the folder.
- **A file counts as already imported when its name, size and first 1 MB of contents all match.** So:
  - moving a file to another folder, or renaming or moving folders, never imports it again;
  - exporting a picture again with different edits does import it again, as a new photo;
  - renaming the file itself also imports it again.
- **Failed imports are tried again, less and less often.** The wait starts at a minute and doubles after each failure, up to once a day. When the wait is over, the file is tried the next time any file changes in the folder, or at the next 10-minute check. Whenever watching starts, every failed file is tried straight away.
- **Unplugged drive.** The status shows "Drive not connected". Plug the drive back in and Photo Drop carries on by itself.
- **It catches up.** Whenever watching starts (the app opens, the switch goes on, the drive comes back) it checks the whole folder for anything not yet imported.

### Changing the 60-second wait

Use the arrows next to "Import a file after it has been unchanged for 60 seconds" in the window. The wait can be anything from 5 to 600 seconds, and the app remembers it.

A change takes effect straight away, even for files that are already waiting. While watching is on, the log confirms it with a line like "Files must now be unchanged for 30s".

Changing it from Terminal with `defaults write` is not reliable: macOS may block Terminal from touching the app's settings.

## The log

Look in `~/Library/Logs/PhotoDrop.log`, or follow it live:

```
tail -f ~/Library/Logs/PhotoDrop.log
```

It notes when watching starts and stops, when the drive comes and goes, each file imported, and each failure with the reason.

## Running the tests

The rules on their own:

```
cd Core && swift test
```

The whole import flow:

```
xcodebuild -project PhotoDrop.xcodeproj -scheme PhotoDrop -configuration Debug -derivedDataPath build test
```

The tests use temporary folders and a stand-in for Photos. Nothing is added to your library.

## Where things are

In this repository:

```
project.yml                  Project settings. PhotoDrop.xcodeproj is generated from this.
PhotoDrop/                   The app
  PhotoDropApp.swift         Starts the app; keeps it running when the window is closed; one copy at a time
  MainView.swift             The window
  AppModel.swift             Ties it together: settings, status text, the first-time question
  FolderAccess.swift         Remembers the chosen folder; notices the drive coming and going
  FolderWatcher.swift        Hears from macOS when files in the folder change
  ImportCoordinator.swift    Checks the folder, waits for files, imports them, retries failures
  ImportRecord.swift         Remembers which folders have had the first-time question; resets the record
  PhotosImporter.swift       Finds or creates the album and adds files to Photos
  LoginItem.swift            Open at login
  FileLog.swift              Writes the log
  Info.plist                 The wording macOS shows when asking for Photos access
  PhotoDrop.entitlements     The permissions the app asks macOS for
PhotoDropTests/              Tests for the import flow and for resetting the record
Core/                        The rules, as a separate Swift package with its own tests
  Sources/PhotoDropCore/
    MediaFilter.swift        Which files count
    AssetPairing.swift       Pairing JPEG with RAW
    FileFingerprint.swift    Name + size + first 1 MB, used to recognise a file
    ImportLedger.swift       The record of imported files
    SettleTracker.swift      Waiting until a file stops changing
  Tests/PhotoDropCoreTests/
build/                       Output of the Terminal build (not in git)
```

On your Mac:

- Record of imported files: `~/Library/Containers/com.briancolclough.PhotoDrop/Data/Library/Application Support/PhotoDrop/ledger.sqlite`
- Settings: `~/Library/Containers/com.briancolclough.PhotoDrop/Data/Library/Preferences/com.briancolclough.PhotoDrop.plist` (macOS may block Terminal from changing these; use the window and the menu command)
- Log: `~/Library/Logs/PhotoDrop.log`

## Known limits

- A file that always fails is tried again for as long as it stays in the folder, slowing down to once a day. It never gives up. The red row in the list and the log say why it fails.
- "Open at login" opens the copy of the app it was switched on from. If you move the app, switch it off and on again.
- A RAW file is only joined to its JPEG when both arrive together. If the JPEG was already imported and the RAW turns up later, the RAW becomes a separate photo. Only JPEG pairs with RAW; HEIC, TIFF and PNG do not.
- A photo you delete from Photos is not added again, because the file is still in the record.
- Two files with the same name, the same size and the same first 1 MB are treated as the same file, even if they differ further in.
- Changing the album only affects files imported from then on.
- One folder is watched at a time.
- The log is never trimmed.
