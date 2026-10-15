# Releasing Stackyard

Releases are built on GitHub by `.github/workflows/release.yml`:

- **Windows:** `Stackyard-Setup-<version>.exe`, a per-user installer (no administrator prompt) with Start menu entry, optional desktop shortcut and an uninstaller in Settings → Apps.
- **macOS:** `Stackyard-<version>.dmg`.

## Where the signing secrets live

Signing secrets on GitHub (SignPath's, and Apple's only if you sign on CI) are **environment secrets** in the `release` environment, never repository secrets. That environment only serves `v*` tags and waits for the owner to approve each run, so no other workflow, branch or pull request can read them. Every action in the workflows is pinned to an exact commit, so a hijacked action tag can't run inside a signing job.

If a secret might have leaked: revoke the Developer ID certificate in the Apple Developer portal and the app-specific password at account.apple.com, rotate the SignPath API token, then replace the secrets.

## Make a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow builds and tests both, and attaches the Windows installer to a **draft** release on GitHub. Then add the notarized Mac DMG from your Mac with `tool/release-mac.sh` (see below). Check the draft, write the notes, and press **Publish**.

To try a build without releasing, open **Actions → Release → Run workflow**. The files appear under that run's **Artifacts**.

Windows signing turns on by itself once the SignPath secrets exist; until then the installer is unsigned and Windows shows "Windows protected your PC". An unsigned Mac DMG is never attached to a release, because macOS would refuse to open it.

## Windows signing: SignPath Foundation (free for open source)

SignPath Foundation gives open-source projects a free code-signing certificate. Signing runs in their cloud, started from GitHub Actions, so no one handles a certificate file.

What they ask for:

- The repository is **public**, with an OSI-approved license (Stackyard is MIT).
- The project is built from source on CI. This workflow does that.
- A code signing policy is shown on the project page (see below), and the people who can release use two-factor authentication on GitHub.

Steps:

1. Make the repository public. Then apply at <https://signpath.org/apply>. The site lists their current conditions; read them first.
2. Once approved, sign in to SignPath and set up the project:
   - Project slug: `stackyard`, linked to this GitHub repository as a trusted build system.
   - Signing policy slug: `release-signing`.
   - Two artifact configurations:
     - `app`: a ZIP artifact; sign `stackyard.exe` and every `*.dll` in it with Authenticode.
     - `installer`: a ZIP artifact containing one `Stackyard-Setup-*.exe`; sign it with Authenticode.
3. In GitHub → Settings → Environments → **release** → Environment secrets, add:
   - `SIGNPATH_API_TOKEN`: an API token for a SignPath CI user with submitter rights on the project.
   - `SIGNPATH_ORGANIZATION_ID`: shown in SignPath's organization settings.
4. Add this section to the README, replacing the team names with real ones:

   > ### Code signing policy
   > Free code signing provided by [SignPath.io](https://signpath.io), certificate by [SignPath Foundation](https://signpath.org).
   > Committers and reviewers: [members of this repository](https://github.com/AqibJavedZeepalm/stackyard/graphs/contributors). Approvers: the repository owner.
   > Privacy: Stackyard only goes online to check for new versions of the tools it manages and to download the ones you choose to install. It sends nothing about you or your computer.

A newly signed app can still show a SmartScreen warning for its first downloads, until Microsoft's reputation system knows the certificate. The warning goes away as more people install it.

## macOS signing and notarization

The DMG is signed and notarized on the maintainer's Mac with `tool/release-mac.sh`, so the Apple certificate and notarization credentials never leave that Mac. The release workflow still builds and tests macOS, but it attaches a DMG only if it signed one itself (see "Signing on CI instead" below).

One-time setup:

1. A **Developer ID Application** certificate in your keychain (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application). `security find-identity -v -p codesigning` lists it.
2. A notarization profile, saved in your keychain:

   ```bash
   xcrun notarytool store-credentials notary --apple-id you@example.com --team-id TEAMID
   ```

   It asks for an app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords.

Each release, after pushing the tag (the workflow creates the draft release with the Windows installer):

```bash
SIGN="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary tool/release-mac.sh 1.0.1
```

It builds that version, signs it with the hardened runtime, makes the DMG, notarizes and staples it, checks it with Gatekeeper, and attaches it to the `v1.0.1` draft release. `UPLOAD=0` does everything except the upload. Then check the draft and press **Publish**.

### Signing on CI instead

If you'd rather sign on GitHub, add these as environment secrets in the `release` environment; the workflow then signs, notarizes and attaches the DMG itself:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | The Developer ID certificate and its private key, exported from Keychain Access as `.p12`, as base64: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | The `.p12` password |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Your 10-character Team ID |
| `APPLE_APP_PASSWORD` | An app-specific password |
