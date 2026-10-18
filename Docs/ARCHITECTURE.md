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

The feature folders group files by ownership. This is not a new framework or a claim that every file has become small. `AppState` is the composition/navigation boundary. `LibraryWorkspace` owns scores, studies and their notebook; `PracticeWorkspace` owns the single practice snapshot. `WorkspaceAccess` provides temporary writable projections for existing feature bindings, without a second copy of the data. CourseWorkspace owns course content, source links and outline requests. Existing feature bindings project into that owner. SongJourney is a bounded content contract; its session planner reads the existing activity evidence, without a second gradebook or a generic exercise framework.

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

All first-party targets now use Swift 6 language mode, with Swift 6.2 as the minimum compiler. App state, UI adapters, credential storage and save callbacks are main-actor owned. Audio/MIDI callbacks are explicitly Sendable and copy framework-owned buffers before leaving their callback. Microphone owns permission/cancellation epochs and pitch state; MicrophoneInput owns the audio device. Synthetic input tests exercise the same callback from a background task. Calibration notifications hop to the owner actor; the local keyboard monitor has actor-isolated cleanup and explicit removal on dismantle. No unchecked Sendable, unsafe nonisolated state or actor assumptions are used to bypass this ownership.

AIModelCatalog is a separate Sendable client for bounded public model metadata. It receives no credential. SavedRequest keeps request orchestration and commit on its owner actor. WebKit delegates use the SDK's actor/Sendable completion signature, and layout values are validated before integer conversion or UI mutation. A source-book digest also gates EPUB illustration excerpts.

WorkspaceWindowLayout is pure window-sizing policy shared by the app and the graphical-host probe. Both the initial size and minimum fit the visible display. Native verification gives presence flags explicit values: macOS also parses process arguments, and an unpaired flag before an output option can leave its path as an OS open request instead of presenting SwiftUI's initial window. This belongs to the launch driver, not feature or model ownership.

The normal workspace opens its MIDI client before loading music or doing audio work and holds it until shutdown. Port/source disconnection does not dispose that client. Preview and isolated-storage states do not open a real client. The native self-check similarly holds one before audio work, and its virtual-input exercise disposes only a client it created. This avoids MIDIServer idle-exit invalidating an already-initialised framework connection during a listening-first session; see the [CoreMusic maintainer's reproduction](https://shakfu.github.io/coremusic/tutorials/midi_basics/).

## Next architectural work

Continue moving feature bindings and import preparation behind the tested owners. PDFImportQueue uses LibraryWorkspace, durable attempt identities and save-only recovery of received replies; navigation stays outside the queue. Convert feature callers from compatibility projections to focused owners as each workflow changes, keeping persisted drafts separate from transient activity state. Extend actual keyboard/accessibility journeys and failure cases as workflows change. Improve the renderer's transitive version provenance before claiming a complete dependency graph. Keep migrations and old-workspace fixtures with every persisted schema change.

## Flagship learning journey

`SongJourney` links the reviewed familiar and transfer passages to a stable eight-bar composition ID. `SongSessionPlanner` is pure, inspectable policy. The native adapter reads canonical ear, chord-change and play-along observations, with full-progression checks and delayed unassisted transfer kept separate. Content/preferences live in course format 3; results stay in PracticeState. On-screen recognition, MIDI performance and creative artifacts retain their distinct meanings. `SongOpeningInput` keeps pending answers across local save failure and navigation. Source edits invalidate current recommendations without deleting historical evidence.


## Four sections and contextual coaching

WorkspaceSection describes Learn, Library, Studio and Explore. Destination remains the internal activity route, with exactly one section per activity. Explicit entry points still open the complete requested piece or a deliberate passage. Selecting a section resumes its last route without starting a session or resetting evidence. The navigation map is transient; it introduces no persisted schema or duplicate content owner.

LibraryBrowserState retains filters and per-piece notebook controls. Explicit Show in Library uses the same matching rule as the browser to reveal a hidden target. EditorLocation retains the event, passage and bounded EditorSession undo history; explicit source-opening focus takes precedence. Music stays in LibraryWorkspace. Personal-plan drafts and SavedRequest owners also outlive their views, as do per-piece analysis requests. Transport still stops at navigation boundaries.

ContextCoachSession owns a pinned CoachContext, per-context drafts/recent exchanges and one SavedRequest. Opening/closing the inspector never submits or retargets a paid request. Explicit adoption computes a bounded symbolic snapshot once, outside the inspector's typing/rendering path. A reply is committed against its captured piece ID, scope and fingerprint, independently of the current destination. Earlier-version replies remain labelled as such. Failed saves retain the received result for save-only retry; explicit discard is a separate action and never records completion. Shared PieceExchange bounds keep questions and replies compatible with notebook validation.

The inspector observes its own owner rather than forwarding each keystroke through AppState. Editor shortcut/MIDI guards observe question focus; leaving the question restores normal music interaction. Recent history and cached contexts are bounded without silently evicting an unsent question. General conversations are session-only; supported piece replies use the existing notebook store. No new backend, runtime dependency or automatic AI request was added.

## Picking and microphone observations

PickingMaterial freezes source revision, harmonic scope, tuning/capo and explicit voicings. Relative pattern choices generate the canonical EditorDocument used for notation, tab, playback and the editable finish. Picking cues are bounded event metadata, exported as MusicXML direction text. Document format 9 and practice format 17 protect the new links/evidence from older writers. PickingPractice remains inside PracticeWorkspace's single atomic snapshot; it is not a parallel gradebook. A saved arrangement uses material/style identity rather than its editable title.

PickingInput owns a bounded pending action and local observation capture. Source/task changes, playback and navigation invalidate capture; failed persistence retains the exact result for save-only retry. PerformanceObservation preserves original audio sample/host clocks and signal quality before leaving the callback. MonophonicTake separates raw window observations from a cautious pitch summary. Neither queue delivery time nor RMS becomes an attack/velocity grade. The existing contextual coach pins the chosen take summary and source; opening it sends nothing. No raw samples are persisted or sent.


## Calibrated single-note phrases

MicrophonePhrasePlan freezes a reviewed 1–4-bar guitar voice, meter, absolute source origin and focused scope. MicrophonePhrasePractice owns bounded takes, non-graded practice encounters and delayed review inside PracticeWorkspace's atomic format-17 snapshot. Full opening passes, focused/context practice and independent returns retain distinct meanings. Interrupted or discarded practice delays the next independent return without inventing an answer. A failed encounter write blocks another microphone pass until save-only recovery. Historical evidence can be archived without current-source credit; changed music never receives an old take overlay.

AcousticCapturePipe copies only the selected input channel into a bounded FIFO and runs one analysis consumer. Its fixed hardware sample/host anchor, exact sample continuity and cumulative host residual are retained in AcousticClockEvidence. Queue overflow, invalid PCM, clipping, missing clocks and a count-in tail are explicit abstentions. AcousticAnalyzer measures envelope attacks and stable monophonic YIN pitch without quantisation. Original attack sample positions and host times survive persistence; queue arrival and display refresh do not become measurements.

MicrophonePhraseSession owns permission/start/cancellation, loopback calibration, silent-after-count-in output and pending takes. Calibration and count-in use TimedAudio's scheduled-render origin; the empirical input/output offset is applied once in comparison. The MIDI path retains its existing estimated-audible reference. Channel, device/rate/buffer configuration and sleep invalidate calibration. Calibration is session-only; a retained old profile is provenance for its take, never current device permission or calibration. Both calibration and take clock proof, target-window capture coverage and explicit uncertainty are necessary for timing assessment.

The view caches score and feedback outside cursor ticks, preserves full-piece access and asks for review before keeping a take. The contextual coach receives the selected symbolic source and bounded per-note summary only on an explicit send. It does not receive PCM, change observations or grant practice credit. No new runtime or cloud detector was added.

## Connected daily ear practice

EarDailySession freezes the journey, instrument, source and review invitation. It owns stages, sticky support, exposure and canonical attempt references; it does not duplicate measured results. EarDailyPractice stays in the single format-18 PracticeState snapshot. The core validates transitions and exact pitch/order comparisons. Guitar uses the existing attack detector and take store, with uncertainty/disputes abstaining; it does not inherit timed completion or octave-flexible singing rules. Piano uses physical MIDI releases and an explicit Check action. A persisted capture-start marker keeps re-arming supported even after cancellation or restart.

EarDailyInput retains a received MIDI answer across local write failure. The existing acoustic session pins a dailyOwnerID, so shared recovery routes cannot commit its pending take through another activity. Historical interruption exposure can save after a source change without granting current-source credit. Canonical takes, journal evidence, stage references and review updates publish in one practice transaction. The coordinator derives the map's hearing and transfer evidence from those references.

Source/coaching visits record bounded non-graded exposure even before a transfer session exists. Familiar recall starts without a demonstration; unfamiliar transfer supplies one initial stimulus, with further replays counted as support. Effective review eligibility is the maximum of the spaced due date and relevant exposure cutoffs. Early correct supported practice preserves an earned interval. Creative answers have stable per-session identities and use the existing composition/listen/finish contract. Composition and practice remain independently atomic; a saved draft survives a later practice-write failure. A short answer does not complete the separate eight-bar arrangement.
