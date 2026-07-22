# Infinite Notes iPad client

This directory is the SwiftPM/xtool native iPad client.

## Build and install

From the repository root:

```bash
./scripts/build-ipad.sh
```

Or directly:

```bash
cd ipad
rm -rf .build xtool
./validate-package.sh
xtool dev
```

The corresponding computer server is already integrated under `../computer`; no separate patch step is required.

The bundle identifier remains `com.captainhottub.InfiniteNotesStrokeLab`, so development builds update the existing installed app and retain local app preferences.
