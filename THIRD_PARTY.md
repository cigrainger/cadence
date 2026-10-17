# Third-party software and assets

The checked-in [inventory](Dependencies/components.json) records versions, source locations, license choices, notices and SHA-256 hashes for shipped vendor files. `python3 Scripts/check_repository.py` verifies it and produces a CycloneDX 1.5 SBOM. Changing a dependency requires a deliberate inventory/license review.

| Component | Version | License / role |
| --- | --- | --- |
| ZIPFoundation | 0.9.20, commit `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | MIT; EPUB ZIP reading |
| OpenSheetMusicDisplay | 2.2.1, commit `6e3cbd412274a0cc56ffac87e268d44e9b11ebb0` | BSD-3-Clause; bundled offline notation renderer |
| VexFlow | 1.2.93 | MIT; inside OSMD, including upstream's VexFlow patches |
| JSZip | 3.10.1 | MIT option selected; inside OSMD |
| loglevel, typescript-collections | unresolved bundled versions | MIT; notices supplied by the renderer distribution |
| JSZip browser dependencies | unresolved bundled versions | MIT/ISC/Zlib; full list and notices retained |
| TimGM6mb sound bank | 1.3 | GPL-2.0-only; separate unmodified editable SF2 data asset |

## Notices and source

- OSMD: `Resources/ScoreViewer/OSMD-LICENSE.txt`.
- Renderer components: `Resources/ScoreViewer/opensheetmusicdisplay.min.js.LICENSE.txt`. Includes VexFlow, JSZip, loglevel, TypeScript Collections, pako, lie, immediate, setimmediate, readable-stream, core-util-is, inherits, process-nextick-args, safe-buffer, string_decoder and util-deprecate.
- ZIPFoundation: `Resources/Third-party notices.txt`; exact source is pinned by SwiftPM and supplied with source releases.
- Sound bank: `Resources/SoundBanks/Copyright.txt`, `GPL-2.0.txt` and `Source.txt`. The shipped `.sf2` is itself editable source. It remains separately licensed; see `LICENSING.md`.

The pako zlib-port notice is retained in addition to its MIT wrapper notice.

The minified OSMD file was compared byte-for-byte with the upstream 2.2.1 npm distribution. The source-release packager includes the checksum-pinned upstream source archives for OSMD and ZIPFoundation. macOS frameworks, system fonts and system symbols are not redistributed in the repository.

## Inventory limits

Upstream OSMD does not ship a resolved transitive lockfile with its prebuilt bundle. We know the bundle hash and the listed components, but not every transitive version. The SBOM is deliberately marked **incomplete**, and unknown versions remain absent with an explanation. It is not a complete supply-chain attestation or a promise of bit-identical upstream rebuilding.

The advisory checker queries OSV for the known package versions and ZIPFoundation revision. It explicitly excludes unresolved versions, the independent sound bank and Apple frameworks. A “no advisories returned” result is not proof that a component is vulnerability-free. Resolve this provenance gap before claiming a complete dependency graph.

## Updating

Keep vendor changes separate from application changes. Verify an official source, retain full licenses, update the manifest/hash, run the advisory query, run renderer/import regression checks and inspect representative scores. Do not patch minified vendor code manually or infer a version from a loose semver range.
