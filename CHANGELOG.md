# Changelog

## Unreleased

- Added “Make a song your own”: an opening check, connected listening/chord/groove activities, an eight-bar arrangement and an independent return.
- Organised the app into Learn, Library, Studio and Explore, with a contextual coach, retained drafts and score position/undo across navigation.
- Migrated all first-party targets to Swift 6 and strengthened course ownership, import cancellation, save-only recovery and device callback boundaries.
- Added app-wide native execution coverage, regression gates and actual accessibility journeys alongside unit-only coverage.
- Made the website’s G7/D♭7 comparison easier to hear with a fuller bass sound and a Bass only option.
- Updated the workspace guides, learning screenshot and explicit hardware/accessibility testing limits.

## 0.36.1 — a clearer path into your music

- Added local Developer ID signing, notarisation, stapling and verified release packaging. Credentials stay in the maintainer's Keychain; release metadata comes from the signed artifact.
- Bound app builds to their source/resource inputs and made CI drafts wait for locally notarised assets.
- Extracted library and practice owners, preserving atomic practice progress and transactional score/metadata saves.
- Rejected late updates to removed library pieces; added regressions for failed saves, corruption, migration, observation and first-install pathway persistence.
- Clarified the website's learning journey, made the harmony demo's G/D♭ bass visible, and added a social preview.
- Added signing and silent website interaction tests, plus a coverage gate for the new workspace owners.

## 0.36.0 — first public preview

- Organised the native app by feature, platform service and musical domain; separated the score document, MusicXML adapter and library.
- Added a new original icon and visual identity, task-based guide, open-source project site and useful sidebar help.
- Added global playback stopping and truthful storage status; reduced repeated score-feedback work during cursor playback.
- Hardened AI endpoint/redirect handling, renderer navigation/message boundaries and persisted-file size limits, with regression tests.
- Retired the unused experimental second renderer; retained linked notation/tab editing through OSMD.
- Added copyleft licensing, third-party inventory, SBOM/hygiene checks, public CI, Pages and release packaging.

This first public release includes the existing library, composition, piano/guitar practice, reviewed book pathways, score analysis and reharmonisation work. It remains a preview: see the guide for musical and device limitations.
