# Public-preview quality review

Review scope: preparing 0.36.0 for public source distribution. This is an engineering review with regression evidence, not a professional security certification or a complete accessibility audit.

## Concrete changes

| Finding | Change and evidence |
| --- | --- |
| Flat files mixed domain, UI, devices and diagnostics | Grouped the two modules by ownership; split the score document/XML/library; moved native checks out of the app shell. Existing behaviour tests passed after relocation. |
| Inconsistent stop behaviour across transports | Shared cancellation boundary, keyboard shortcut and persistent footer. Regression covers simultaneous chord/improvisation preparation and local microphone state without opening a device. Pending results remain available. |
| Permanent “saved” wording and a decorative sidebar panel | Storage status now reflects failures; help replaces the non-interactive card. Settings opens on General and includes licenses/privacy/source links in About. |
| Score feedback reconstructed during cursor ticks | Cache the feedback input and only rebuild its bridge payload on changes. The small footer observes transport clocks directly. |
| Broad file navigation in renderer | Exact bundled entry-page policy and main-frame message checks. Tests reject remote URLs, other local files, hostile hosts and query variants. |
| AI credentials at an overly flexible boundary | Validate the HTTPS OpenRouter endpoint and POST method before any sender; refuse redirects; redact the key before truncating error detail. Negative request tests verify no send. |
| Unbounded persisted-file reads and saves | Stat/read/encode limits; preserve oversized originals and reject unsafe replacement. Regression tests cover both read and write failure. |
| Rebuilding into an old app bundle could leave retired files | Stage a fresh bundle, replace only a recognised Cadence destination, verify packaged resources/signature. Removed unused Smoosic/jQuery comparison assets. |
| Development material unsuitable for public Git | Excluded private research/model logs, old outputs and user documents. Only named original PDF/EPUB fixtures are allowed. Repeated redacted secret scans found no leaks in the prepared public tree. |
| License and dependency provenance unclear | AGPL first-party code, CC BY-SA docs/art/examples, preserved third-party notices including the pako zlib port, hash-checked inventory and schema-validated CycloneDX SBOM. |

## Automated evidence

On the final relocated source, **501 MusicCore tests and 191 Cadence integration tests passed**. Two opt-in timing tests are normally skipped and were run separately. Eight Python tests cover the verification/report and repository policy tools. Swift formatting and first-party JavaScript syntax checks passed. The only observed compiler warning came from ZIPFoundation's upstream watchOS deployment declaration, not Cadence's macOS source.

Measured line coverage: **MusicCore 94.93%; Cadence 10.94%**. The latter excludes much of the UI from direct unit execution. The repeatable workflow supplements it with native preview assertions, renderer editing checks and offline audio rendering. All 123 native workflow scenarios passed, followed by checks of the final packaged app and its General/MIDI/About panels. Screenshot evidence is local/generated, not committed user data.

Two debug-build timing observations on this arm64 Mac (macOS 27.0.1, Apple Swift 6.4): 128-bar score/MusicXML round trip averaged approximately **83 ms**; generating dominant-seventh guitar voicings across all roots averaged approximately **185 ms**. These are local observations, not universal response-time promises or comparative speedup claims.

The OSV query returned no advisories for the known ZIPFoundation revision, OSMD 2.2.1, VexFlow 1.2.93 and JSZip 3.10.1 at review time. It does not clear unresolved bundle versions.

## Visual and interaction review

Reviewed original-fixture screens for practice home, harmony on piano/guitar, the full score, editing, library, import/review and settings, including compact layouts. The app keeps full-score access and clear activity exits. Narrow PDF source columns now wrap navigation and zoom as groups, preserving readable page labels and accessible button names. Choice controls, assisted answers and independent returns remain distinguishable. Playback and storage status are visible across destinations.

The website uses the same identity and real original-fixture app imagery. Desktop and phone layouts, project-subpath links, harmony choice/play/stop, guide navigation/filtering and browser errors were checked. Guide search now includes content, so musical terms need not match a title. The site build checks all internal links and anchors.

## Remaining limits

- Physical keyboards, microphone permission flows, device switching, VoiceOver and Intel builds still need dedicated release testing. Virtual MIDI and rendered audio are not substitutes.
- Ad hoc signing is not notarisation. The current app is not isolated by App Sandbox.
- OSMD's prebuilt bundle lacks a resolved transitive lockfile. The inventory lists 13 unknown bundled versions and explicitly marks the graph incomplete. Supplied upstream source enables inspection; bit-identical upstream rebuilding is not claimed.
- AppState and several activity views remain large. Extract stable owners when changing them, retaining tested boundaries; avoid a generic exercise framework that erases musical differences.
- AI response collection still relies on URLSession and provider limits before task-specific parsing; the new persisted-file cap is not a general network-memory bound.
- Automated checks cannot establish the musical accuracy of arbitrary AI transcriptions or validate the pedagogy with actual learners. Keep original sources, review steps and independent attempts central.
