# Releasing Stackyard

Releases are built on GitHub by `.github/workflows/release.yml`:

- **Windows:** `Stackyard-Setup-<version>.exe`, a per-user installer (no administrator prompt) with Start menu entry, optional desktop shortcut and an uninstaller in Settings → Apps.
- **macOS:** `Stackyard-<version>.dmg`.

## Make a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow builds both, then attaches them to a **draft** release on GitHub. Check it, write the notes, and press **Publish**.

To try a build without releasing, open **Actions → Release → Run workflow**. The files appear under that run's **Artifacts**.

Signing turns on by itself once its secrets exist. Without them, the builds are unsigned: Windows shows "Windows protected your PC" and macOS refuses to open the app.

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
3. In GitHub → Settings → Secrets and variables → Actions, add:
   - `SIGNPATH_API_TOKEN`: an API token for a SignPath CI user with submitter rights on the project.
   - `SIGNPATH_ORGANIZATION_ID`: shown in SignPath's organization settings.
4. Add this section to the README, replacing the team names with real ones:

   > ### Code signing policy
   > Free code signing provided by [SignPath.io](https://signpath.io), certificate by [SignPath Foundation](https://signpath.org).
   > Committers and reviewers: [members of this repository](https://github.com/AqibJavedZeepalm/stackyard/graphs/contributors). Approvers: the repository owner.
   > Privacy: Stackyard only goes online to check for new versions of the tools it manages and to download the ones you choose to install. It sends nothing about you or your computer.

A newly signed app can still show a SmartScreen warning for its first downloads, until Microsoft's reputation system knows the certificate. The warning goes away as more people install it.

## macOS signing and notarization

You need a **Developer ID Application** certificate from your Apple Developer account.

1. In Xcode → Settings → Accounts → Manage Certificates, create a "Developer ID Application" certificate. Then, in Keychain Access, export it with its private key as a `.p12` file, with a password.
2. Create an app-specific password at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords.
3. Add these GitHub secrets:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | The `.p12` file as base64: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | The `.p12` password |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Your 10-character Team ID (Apple Developer → Membership) |
| `APPLE_APP_PASSWORD` | The app-specific password |

The workflow signs the app with the hardened runtime, builds the DMG, sends it to Apple for notarization, and staples the ticket. People can then open it with a double-click.
