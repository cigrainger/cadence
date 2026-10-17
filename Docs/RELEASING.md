# Releases and hosting

The application and website live in one repository. GitHub Pages hosts the static site and user guide; GitHub Releases hosts app binaries, source, SBOM, checksums and notes. No hosted backend, paid web service or account is required to use the ordinary app features.

## Prepare

1. Update `Resources/Info.plist`, `CHANGELOG.md`, `Docs/Releases/VERSION.md` and the explicit preview download links in `README.md` and the site generator/template as needed.
2. Run `python3 Scripts/check_repository.py`, `Scripts/scan_secrets.sh`, `./verify.sh` and the manual checks in `Docs/TESTING.md`. Review all changed dependencies and license records.
3. Use a clean committed checkout. Match the tag `vVERSION` to Info.plist. Do not include private library data or verification output in source.
4. Push the tag. The release workflow reruns headless checks, builds a fresh app and verifies its signature, then creates an **empty draft prerelease** with notes. Unsigned CI assets remain workflow artifacts. Upload the locally notarised assets below before publishing. Inspect the draft and publish from GitHub when satisfied. Stable releases should deliberately change that status after broader testing.

## Local packaging

```sh
./build.sh
python3 Scripts/package_release.py --app dist/Cadence.app --output dist/release
```

The packager requires a clean Git tree and a version-matched app. A signed build-input digest binds the app to the source, scripts and resources in that checkout; a stale matching-version binary is rejected, and the build fails if its inputs change during compilation. It checks repository policy, downloads checksum-pinned dependency source archives over HTTPS, and includes them beside a Git archive of the exact commit in `Cadence-VERSION-source.tar.gz`. The SF2 is already its editable source. It writes a CycloneDX inventory and SHA-256 checksums. The app ZIP is architecture-labelled from its actual Mach-O binary.

The upstream OSMD bundle does not expose a complete resolved transitive lockfile. Its source archive and package manifest are supplied; the SBOM labels unknown bundled versions rather than fabricating them. This permits inspection/rebuilding but does not promise a byte-for-byte reproduction of the upstream minifier output.

## Developer ID and notarisation

Use the paid Apple Developer Program's **Developer ID Application** certificate, including its private key, in the signing Mac's Keychain. An Apple Development certificate cannot sign a release for distribution outside the App Store. No Developer ID Installer certificate is needed for our app ZIP.

Create the certificate in Xcode → Settings → Accounts → your paid team → Manage Certificates → +. Then create an app-specific password at account.apple.com and store notarisation credentials interactively:

```sh
xcrun notarytool store-credentials cadence-notary
```

The prompts ask for your Apple ID, developer Team ID and app-specific password, validate them with Apple and store them in Keychain. Never paste them into chat, Git, a command argument or a workflow file. Use a local signing machine; exporting the private key into GitHub secrets is unnecessary.

After the release checks pass, build and notarise:

```sh
CADENCE_SIGNING_IDENTITY='Developer ID Application: YOUR CERTIFICATE NAME (TEAMID)' ./build.sh
python3 Scripts/notarise.py --app dist/Cadence.app --profile cadence-notary
python3 Scripts/package_release.py --app dist/Cadence.app --output dist/notarised-release --require-notarised
```

Use the complete identity from `security find-identity -v -p codesigning`. A requested Developer ID build fails rather than falling back to ad-hoc signing. The helper checks hardened runtime, timestamp, identity and entitlements before upload. It prints the submission ID before waiting; after interruption or timeout, use `--submission ID` to resume without submitting again. For an Apple rejection, inspect `xcrun notarytool log ID --keychain-profile cadence-notary` locally, fix the issue and make a new build.

Only Apple's **Accepted** result proceeds to stapling. The ticket is retrieved for the app's actual signature, validated, and checked by Gatekeeper. Package **after** stapling and never rebuild or modify that app afterwards. The packager derives `BUILD.json` signing/notarisation fields from the artifact; `--require-notarised` refuses a missing ticket or Gatekeeper failure. A successful mock test does not establish notarisation.

Upload the complete `dist/notarised-release/` contents to the matching draft release, including the matching source, SBOM, checksums, BUILD.json and notes. Download that ZIP into a clean folder, verify its checksum/signature/ticket and run the packaged self-check before publishing. Keep the previous release available. Do not upload an untested architecture under a universal label.

Apple references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [notarisation workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [app-specific passwords](https://support.apple.com/en-us/102654), [Team ID](https://developer.apple.com/help/glossary/team-id/).

## Pages

The Pages workflow builds the same versioned content and deploys `site/dist`. It uses read-only repository permissions for building and Pages/id-token permissions only for deployment. Set repository Pages to GitHub Actions. Review docs alongside the app change so a release does not leave stale instructions.
