# Recording and HUD authorization repair

Confirmed causes: tccd rejected the installed development app's changed ad-hoc code requirement; HUD checked Accessibility in the XPC helper although the main app owns the event tap.

Changes: capture preflight before background ScreenCaptureKit enumeration, explicit settings authorization/retry, separate capture failure from permission denial; query/request Accessibility in the main app, monitor throughout app lifetime, stop on revocation, show tap creation failure, recover disabled taps and avoid retaining borrowed events.

Checks: `python3 scripts/check-permission-paths.py` guards permission ownership and background call paths. MusicEdgeChecks passed. Full final Debug build passed, including the cancellation guard. `git diff --check` passed.

Local development signing: `python3 scripts/sign-development.py /absolute/path/to/boringNotch.app` reuses a private identity in `~/Library/Application Support/InterestingNotch/Signing`. Never commit this directory or replace a missing identity silently. The script does not install trust or grant TCC permissions. Do not re-sign installed development updates ad-hoc: that changes the designated requirement again. The locally generated certificate needs current-user code-signing trust, explicitly approved by the user on 2026-09-12. It is not an Apple Developer ID distribution certificate.

Current-user code-signing trust was approved and installed. Signed build and installed app passed deep strict signature verification. A second build with a changed CFBundleVersion retained the identical certificate-bound designated requirement (leaf F2A6F3A41C4E69CDA693B3CFFD052E59E1CD379F), rather than a changing cdhash. The original keychain search list is restored after signing.

Installed to ~/Applications/InterestingNotch Development.app and restarted. A subsequent HUD report was traced to a stale Accessibility grant bound to the original author's Apple Development signature; switching the existing toggle had not replaced that requirement. The app-specific Accessibility record was reset with `tccutil reset Accessibility theboringteam.boringnotch`, and the user was directed to add the current installed application again. Other services and other applications' grants were not reset. The user subsequently accepted the result and requested publication. Protected audio capture and physical media-key behavior were not independently re-measured after that manual authorization step.
