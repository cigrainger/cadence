# Releases and hosting

The application and website live in one repository. GitHub Pages hosts the static site and user guide; GitHub Releases hosts app binaries, source, SBOM, checksums and notes. No hosted backend, paid web service or account is required to use the ordinary app features.

## Prepare

1. Update `Resources/Info.plist`, `CHANGELOG.md`, `Docs/Releases/VERSION.md` and the explicit preview download links in `README.md` and the site generator/template as needed.
2. Run `python3 Scripts/check_repository.py`, `Scripts/scan_secrets.sh`, `./verify.sh` and the manual checks in `Docs/TESTING.md`. Review all changed dependencies and license records.
3. Use a clean committed checkout. Match the tag `vVERSION` to Info.plist. Do not include private library data or verification output in source.
4. Push the tag. The release workflow reruns headless checks, builds a fresh app and verifies its signature, then creates a **draft prerelease** with notes and assets. Inspect it and publish from GitHub when satisfied. Stable releases should deliberately change that status after broader testing.

## Local packaging

```sh
./build.sh
python3 Scripts/package_release.py --app dist/Cadence.app --output dist/release
```

The packager requires a clean Git tree and a version-matched app. It checks repository policy, downloads checksum-pinned dependency source archives over HTTPS, and includes them beside a Git archive of the exact commit in `Cadence-VERSION-source.tar.gz`. The SF2 is already its editable source. It writes a CycloneDX inventory and SHA-256 checksums. The app ZIP is architecture-labelled from its actual Mach-O binary.

The upstream OSMD bundle does not expose a complete resolved transitive lockfile. Its source archive and package manifest are supplied; the SBOM labels unknown bundled versions rather than fabricating them. This permits inspection/rebuilding but does not promise a byte-for-byte reproduction of the upstream minifier output.

The current release is ad hoc signed, not notarised. Developer ID signing/notarisation needs a maintainer's Apple credentials and is a separate future step. Do not put signing identities, keys or credentials in Git. Do not upload an untested architecture under a universal label.

## Pages

The Pages workflow builds the same versioned content and deploys `site/dist`. It uses read-only repository permissions for building and Pages/id-token permissions only for deployment. Set repository Pages to GitHub Actions. Review docs alongside the app change so a release does not leave stale instructions.
