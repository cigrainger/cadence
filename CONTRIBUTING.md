# Contributing to Cadence

Help make a useful musical instrument for learning. Small, focused contributions are easiest to review. Teaching examples, clearer explanations, accessibility reports and documentation matter as much as code.

## Before changing code

Read the [architecture](Docs/ARCHITECTURE.md), [testing workflow](Docs/TESTING.md), and the relevant [user guide](https://cigrainger.github.io/cadence/docs/). For substantial behaviour changes, open an issue describing the musical goal, the learner's action and the observable result. Keep examples original or explicitly redistributable.

Use a branch and a pull request. Describe the problem, the resulting behaviour, meaningful validation and known limitations. Include a screenshot for a visual change and a short reproduction for a bug. Never attach a private book, personal practice history, API key or unredacted model response.

## Development expectations

- Keep musical rules and serialisable models in MusicCore; keep device/UI state in Cadence.
- Share invariants, not merely similarly shaped code. Avoid adding a generic framework for one activity.
- Write comments for musical assumptions, timing, ownership and failure behaviour; avoid narrating obvious syntax.
- Add regression tests at meaningful boundaries: malformed input, cancellation, persistence failure, review/independence rules and the successful musical task.
- Preserve cancellation, storage error feedback, keyboard operation and access to the full score.
- Run `python3 Scripts/check_repository.py`, `./verify.sh --tests-only` and the relevant native previews. Run full verification for a release.
- Format Swift with `xcrun swift-format format --configuration .swift-format --in-place --recursive Sources Tests`. Do not change vendored/minified code by hand.
- The formatter permits wire-format field names and labelled trailing closure callbacks; the two corresponding stylistic lint rules are intentionally disabled.
- Update the guide when the user's workflow changes. Document limits honestly.

Cadence is developed with AI assistance. Such contributions are welcome, but the person submitting them remains responsible for understanding the change, testing it and checking permissions. Do not submit generated code or musical claims you have not reviewed.

## Rights and sign-off

Contribute code under AGPL-3.0-or-later and original docs/art/examples under CC-BY-SA-4.0, as described in `LICENSING.md`. Retain third-party notices. No copyright assignment or proprietary relicensing CLA is required.

Sign off commits with `git commit -s`. This records your certification under the [Developer Certificate of Origin 1.1](https://developercertificate.org/): you have the right to submit the work under the project's license. Use a public or GitHub-provided email you are comfortable recording permanently. Do not sign on someone else's behalf.

## Dependencies and releases

New dependencies need a reason, a license review, a source location, a pinned version and an update to `Dependencies/components.json`. Run the inventory/SBOM check. Unknown bundle versions must remain visible; do not turn an unknown into an invented version to make a check green.

Release instructions are in `Docs/RELEASING.md`. Releases use GitHub assets; the site and docs use GitHub Pages from this repository.
