# Licensing

Copyright © 2026 Cadence contributors. This distribution is provided without warranty.

## Code

Except for the third-party material identified below, the application, tests, scripts, website JavaScript/CSS, configuration and build tooling are licensed under **GNU Affero General Public License, version 3 or (at your option) any later version**. See [LICENSE](LICENSE).

You may use, study, modify, redistribute and charge for the software. When distributing a covered modified program, preserve the required notices, provide its corresponding source and grant recipients the same freedoms. The AGPL also requires an offer of corresponding source to users interacting remotely with a modified covered program over a network. “Free” does not mean non-commercial. This summary does not replace the license.

Earlier copies distributed under another license retain the permissions already granted for those copies. This license applies to the first-party work in this release; it does not relicense third-party contributions.

## Documentation, music examples and identity

First-party prose in `README.md`, `Docs/`, the website's page content and project policies; original musical examples in `Resources/ImportExamples`; and original artwork in `Design/Brand`, `Resources/Brand`, `Resources/AppIcon.icns` and `site/assets` are **Creative Commons Attribution-ShareAlike 4.0 International**. Attribute “Cadence contributors”, link the license, identify changes and share adaptations under its terms. The full text is in `LICENSES/CC-BY-SA-4.0.txt`.

The website's code remains AGPL. Screenshots show Cadence's original examples, not a learner's private library. System fonts and system symbols are used through macOS APIs and are not redistributed as standalone font assets. Do not imply that a fork is endorsed by this project.

## Third parties and system libraries

`THIRD_PARTY.md` and `Dependencies/components.json` identify the separately licensed code and sound bank. Preserve their notices. The checked-in renderer is the upstream OSMD distribution; its components have permissive licenses. JSZip's MIT option is selected.

**TimGM6mb is GPL-2.0-only.** It is an independent, unmodified, editable SF2 data file delivered alongside the app, with its own source and GPLv2 text. It is not AGPL code and is not relicensed. GPLv2-only code could not simply be linked into this AGPLv3 program; the distribution relies on the sound bank remaining a separate data asset. Reassess licensing before embedding samples in code or replacing the bank.

The app uses Apple's macOS system frameworks. Those are supplied by macOS, not redistributed here. The AGPL's system-library provisions are relevant to those dependencies. No App Store distribution is currently offered.

## Your work

Your own compositions, performances and imported music do not become AGPL or CC-licensed merely because you use Cadence. You remain responsible for permissions to distribute other people's music and books. The public repository contains only original fixtures and third-party software/assets with redistribution terms.

For background, see the [GNU licensing FAQ](https://www.gnu.org/licenses/gpl-faq.en.html), [license compatibility guidance](https://www.gnu.org/licenses/license-compatibility.en.html), and [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). This is the project's licensing policy, not a legal opinion about every possible downstream distribution.
