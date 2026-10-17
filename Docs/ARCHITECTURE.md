# Architecture

Cadence is a Swift package with a native SwiftUI/AppKit application and a portable musical domain module. It uses AVFoundation/AudioToolbox for sound, CoreMIDI for input, PDFKit for source viewing, Keychain for credentials, and bundled OpenSheetMusicDisplay in WKWebView for notation. ZIPFoundation reads EPUB archives. The website is static HTML/CSS/JavaScript with a small Python build step.

## Boundaries

| Area | Owns | Does not own |
| --- | --- | --- |
| `Sources/MusicCore/Theory`, `Score`, `Harmony` | Pitches, intervals, chord spelling/voicings, score documents, analysis | Views, device handles |
| `MusicCore/Practice`, `Learning`, `Ear` | Exercise plans, evidence, review and progression rules | Permissions, UI clocks |
| `MusicCore/Import`, `AI`, `Infrastructure` | Validated formats, bounded persistence and request contracts | Arbitrary rendering or automatic publication |
| `Sources/Cadence/Features` | Activity views, workflow-specific state and user actions | Duplicated musical invariants |
| `Cadence/Infrastructure` | Audio/MIDI, storage adapters, imports, AI sessions, renderer bridges | New pedagogical policy |
| `Cadence/App` and `Design` | Composition root, navigation, shared visual controls | Hidden feature-specific scoring rules |
| `Cadence/Diagnostics` | Isolated previews and executable native checks | A user's library, key or microphone |

The feature folders group files by ownership. This is not a new framework or a claim that every file has become small. `AppState` is the composition/navigation boundary. `LibraryWorkspace` owns scores, studies and their notebook; `PracticeWorkspace` owns the single practice snapshot. `WorkspaceAccess` provides temporary writable projections for existing feature bindings, without a second copy of the data. Course state and activity orchestration still need incremental extraction; there is no generic exercise framework.

## Score and source ownership

`EditorDocument` is the editable value model. `EditorXML` is the MusicXML adapter; `EditorLibrary` owns collections and migration. The renderer receives serialised data and sends bounded selections back; it does not become the source of truth. Imports retain source references and review status. Opening a library piece opens the full score; practice passages are linked, intentional selections.

Imported sources and original compositions remain distinguishable. A saved alternative or creative answer has a link to its inspiration; it does not overwrite the source. Unsupported notation is surfaced rather than silently represented as supported editing.

## Practice and timing

Hearing, explaining, playing and creating are separate evidence dimensions. Assisted success and independent returns are distinct. Review scheduling belongs to tested core policy. Device events flow through MIDI/input owners to activity state; audio rendering and timed transport are separate from musical judgment.

`stopAllPlayback` centralises playback/count-in/recording cancellation. Individual activities still own their pending results and input phases. The footer observes transport owners directly, avoiding forwarding high-frequency playback ticks through the whole app. Score feedback is rebuilt only when feedback changes; cursor ticks do not reserialise the whole result.

## Persistence and failure

`JSONFileStore` validates sizes, keeps atomic save/backup semantics and preserves unreadable originals. A failed write leaves pending work visible for retry. AppState exposes storage warnings; the sidebar never claims “saved” simply because the app is open. Repositories stage, validate and commit a value before reporting success. `PracticeWorkspace.commit` publishes one snapshot after the evidence and review schedule have been written together. `LibraryWorkspace` makes explicit score/notebook commits transactional, rejects late results for removed pieces, and leaves ordinary editing drafts visible if saving fails. The two owners are testable without audio, MIDI, Keychain or a view tree. Their observation is forwarded by AppState for existing bindings; transport clocks remain independently observed.

## External boundaries

AI requests use `OpenRouterRequest`/`OpenRouterTransport` with an endpoint allowlist, a deadline, cancellation and no redirects. EPUB/score parsers validate untrusted content. Renderer navigation uses `LocalDocumentPolicy`; message handlers accept the main frame only. Tests inject request senders and virtual MIDI events; paid models and physical instruments are separate manual validation.

## Next architectural work

Next, extract course ownership and cancellable import orchestration behind tested boundaries. Convert feature callers from compatibility projections to focused owners as each workflow changes. Separate persisted drafts from transient activity state before enabling Swift 6 strict concurrency. Add UI/accessibility automation around the most common learner journeys. Improve the renderer's transitive version provenance before claiming a complete dependency graph. Keep migrations and old-workspace fixtures with every persisted schema change.
