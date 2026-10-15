# Stackyard

See every SDK, toolchain and framework version on your machine, which projects use each one, and what's safe to remove. Then fix what's wrong with one click.

Version managers like FVM, nvm, pyenv and SDKMAN are great at installing versions. None of them tells you that you have six Flutter SDKs, three Android NDKs and a 13 GB emulator you haven't started in a year. Stackyard does.

- **One window for every tech.** A sidebar entry appears only for techs found on your machine.
- **Get tools.** A marketplace of SDKs and CLIs (Flutter, Android command-line tools, Node.js, Python, Java, .NET, Go, Rust, Deno, Bun, Gradle, and the Angular, Expo, NestJS, Firebase, Vercel, Ionic, Nx, TypeScript, pnpm and Yarn CLIs). Every version is listed from the publisher's own release feed. Downloads come straight from the publisher and are checked against their published hash. Before installing, you choose the folder and which environment variables to set (`PATH`, `JAVA_HOME`, `GOROOT`…): your user variables or everyone's on Windows, a marked block in `~/.zprofile` on macOS. Installed versions can be made the default or removed later, which cleans up their variables too.
- **Knows who uses what.** It reads `.fvmrc`, `.nvmrc`, `package.json`, `gradle-wrapper.properties`, `build.gradle`, `local.properties`, `.python-version`, `global.json` and more across your project folders.
- **Problems come with a fix button.** Missing versions a project needs, two setups fighting over a folder, a broken `JAVA_HOME`: each is explained in plain words, with a button that fixes it. You never type a command.
- **Environment doctor.** Finds `JAVA_HOME` / `ANDROID_HOME` pointing at folders that are gone, dead and duplicate PATH entries (it saves a backup first), and a Java that's too new or too old for a Flutter app's Gradle and Android Gradle Plugin.
- **Project cleanup.** Shows the `node_modules`, `build`, `.dart_tool`, `.gradle`, `Pods` and other rebuildable folders in your projects, with a one-click clean for projects you haven't touched in months.
- **Emulator manager.** Start, cold boot, wipe data, delete snapshots or delete each Android emulator, with its size and when it last ran.
- **Safe removal.** Things go to the Recycle Bin / Trash by default, or you can choose to delete permanently. Installed programs are removed with their own uninstaller. Links are removed as links; what they point to is never touched. You see every step before it runs, and a spinner wherever work is happening.
- **Runs in the background.** Closing the window keeps Stackyard in the system tray (Windows) or menu bar (macOS). It checks your setup daily or weekly and notifies you only when there's something new. It can start at sign-in.
- **Move your setup.** Export your toolchain versions to a file and import it on another computer to install what's missing.
- **Never edits your projects.** It doesn't change a project's pinned versions, because that can break builds.
- **Native feel.** Windows 11 Fluent design with Mica, Fluent motion and your accent color.

## What it detects

| Tech | Where it looks | How it knows a project uses it |
|---|---|---|
| Flutter | FVM (`fvm api list`), standalone SDK on PATH | `.fvmrc`, `.fvm/fvm_config.json`; unpinned projects use the global version |
| Node.js | nvm-windows, fnm, Volta, Node.js installer | `.nvmrc`, `.node-version`, `package.json` `volta` / `engines` |
| Android SDK | Platforms, build tools, NDKs, system images, emulators, duplicate SDK folders | `compileSdk`, `ndkVersion` (including Flutter's defaults per SDK version), `local.properties` `sdk.dir`, emulator `config.ini` |
| Gradle | `~/.gradle/wrapper/dists`, caches | `gradle-wrapper.properties` |
| Java | Program Files vendors, `~/.jdks`, SDKMAN, Android Studio JBR | `.java-version` |
| Python | `py` launcher, pyenv-win, uv, python.org and Microsoft Store installs | `.python-version`, `requires-python` |
| .NET SDK | `dotnet --list-sdks` | `global.json` |
| React, React Native, Expo, Next.js, Vue, Nuxt, Angular, Svelte, Astro, Electron, Vite, TypeScript | Each project's `node_modules` | `package.json` |

Installs use each tech's own manager (FVM, nvm / fnm / Volta, `sdkmanager`). Tools without one are installed with `winget` on Windows and Homebrew on macOS.

## Run it

Needs Flutter 3.47 or later.

- **Windows:** Visual Studio 2022 with the "Desktop development with C++" workload.
- **macOS:** Xcode. The app runs outside the App Sandbox (see `macos/Runner/*.entitlements`), like other developer tools: it reads SDK folders across your home folder and runs tools such as `fvm`, `brew` and `sdkmanager`.

```bash
fvm install
fvm flutter run -d windows   # or -d macos
```

If the project sits in a very long path on Windows, MSBuild fails with `FTK1011`. `tool/dev.ps1` mirrors the project to a short path and runs Flutter there:

```bash
powershell -File tool/dev.ps1 run -d windows
```

Install a release build for the current user (Start menu entry, desktop shortcut, uninstall from Settings → Apps):

```bash
powershell -File tool/dev.ps1 build windows --release
powershell -ExecutionPolicy Bypass -File tool/install.ps1
```

Tests:

```bash
fvm flutter test
fvm flutter test test/scan_smoke_test.dart --dart-define=SMOKE=true   # scans your real machine
```

## Adding a tech

Each tech is one class in `lib/core/techs/` that extends `TechAdapter`:

1. `detect()` finds installed versions and returns a `TechSnapshot`, or `null` if the tech isn't on the machine (then no sidebar entry appears).
2. In `detect()`, link each `InstalledItem` to the projects that use it with `item.usedBy.add(project.toUsage())`. Report problems with `snap.problem(text, [NoteFix(...)])` so each one comes with its fix.
3. Optionally implement `planInstall`, `planSetGlobal`, `planRemove`, `planInstallFromStack` and `availableVersions`. Actions return a `PlannedChange` (commands, file edits, Recycle Bin moves) that the user reviews before anything runs.
4. Register it in `lib/core/registry.dart`.

If a tech only lives inside projects, like a JS framework, add a `FrameworkTech` line to the registry.

## Layout

```
lib/
  core/            scanning and tech knowledge (no UI)
    techs/         one adapter per tech
    doctor.dart    environment checks and their fixes
    project_junk.dart, stack_file.dart, installers.dart, installed_apps.dart, autostart.dart
  state/           app state, settings, job queue, background (tray, checks)
  ui/              Fluent UI: shell, pages, dialogs, motion
```

## Privacy

Everything runs locally. Stackyard only goes online to check for new versions (Flutter releases, nodejs.org, the npm registry). No accounts, no telemetry.

## License

MIT
