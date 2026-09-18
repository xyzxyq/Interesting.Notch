# Automatic updates

Interesting Notch uses its existing Sparkle dependency to check the latest stable
GitHub Release once per day. Settings → About offers automatic checks and automatic
download/installation separately. Checks default to on; automatic installation is
opt-in. Preferences are persisted by Sparkle, and manual checks remain available
when automatic checks are off. Installation completes at app quit or via Sparkle's
restart action; playback controls and lyrics are not restarted by a version poll.

The feed is the `appcast.xml` asset on the latest stable release:
`https://github.com/xyzxyq/Interesting.Notch/releases/latest/download/appcast.xml`.
Drafts and prereleases are not the update channel. Each stable release must include
its own signed feed and the exact archive referenced by that feed. Existing
3.0.6-and-earlier installations with the link-only updater require one manual upgrade.
A missing feed or failed download is reported by Sparkle and leaves the installed app intact.

## Prepare a release

1. Increase `CFBundleVersion` / `CURRENT_PROJECT_VERSION` monotonically and update
   the marketing version. Build Release and sign the final app with the existing
   signing workflow. Keep `SUPublicEDKey`, bundle identity and the update URL intact.
2. Run `scripts/package-release-dmg.sh <signed.app> <archive.dmg> <volume-name>`.
   This now creates `<archive.dmg>.update/appcast.xml` and a copy of the DMG, verifies
   the Ed25519 signature against the public key embedded in the source Info.plist,
   and checks release tag, URL and archive length. Use filenames without spaces.
   Set `SPARKLE_BIN` if the resolved Sparkle tools are outside `build/*/SourcePackages`.
3. Upload the verified DMG and `appcast.xml` together to a draft GitHub Release
   whose tag matches the app's `vX.Y.Z`, then publish it as the latest stable release.
   Publishing is deliberately not performed by the packaging script.

For an existing signed ZIP or DMG:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/prepare-update.py \
  /path/InterestingNotch-3.0.7.dmg v3.0.7 /path/update-assets \
  --sparkle-bin /path/Sparkle/bin
```

Only the public key belongs in Git. The private key is held in the macOS login
Keychain under Sparkle account `xyzxyq.Interesting.Notch`. Back it up securely before
moving release machines; do not regenerate it for each version. A CI deployment can
supply `--key-file` from a protected secret file, never from a command-line key string.
The inherited upstream `/release` workflow is restricted to its upstream repository;
this fork uses the local signing/packaging flow above.

Ed25519 update verification is independent of Apple notarization. Current local
builds use the project's existing development signing and are not notarized.

## Verification

```sh
python3 scripts/check-release-updates.py
python3 scripts/check-energy.py
```

Release delivery is not complete until the public `appcast.xml` URL resolves and a
previous supported build successfully checks, downloads, validates, installs and
relaunches against that release. Local signed-archive validation does not substitute
for this final published-channel test.
