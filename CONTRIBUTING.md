# Contributing to Stackyard

Thanks for helping. Stackyard runs on people's own machines, deletes files and changes environment variables, so a few rules matter more here than in most projects. Please read them before you start; a pull request that breaks one can't be merged, however good the rest is.

## Ways to help

- **Report a bug.** In the app: Settings → Report a problem, or the button on a failed job in Activity. It opens a GitHub issue with your Stackyard and OS versions and the job's log filled in. Check the log for anything private before you submit.
- **Suggest a feature or a new tech.** Open an issue first and describe the problem it solves. Wait for a reply before writing a lot of code, so your time isn't spent on something that can't be merged.
- **Fix something.** Issues labelled `good first issue` are a good place to start. Comment on the issue so two people don't work on the same thing.
- **Test on your setup.** Every machine is different. A report like "on Windows 10 with Scoop, Java shows twice" is genuinely useful.

## The rules

### Safety: Stackyard must never surprise anyone

1. **Show before doing.** Every change to the machine is a `PlannedChange` (commands, file edits, moves to the Trash, environment changes) that the user sees and confirms before it runs. No silent writes, ever.
2. **Never edit a user's project.** Stackyard reads `.fvmrc`, `package.json`, `build.gradle` and the rest; it does not change them, not even to fix a pin.
3. **Recoverable by default.** Removal goes to the Recycle Bin / Trash unless the user picks "delete permanently". Installed programs are removed with their own uninstaller. Links are removed as links; what they point to is never touched.
4. **Never remove shared or system folders.** Anything under Homebrew, system folders or folders other programs share is marked not removable (see `Sys.isSharedFolder`). Don't work around it.
5. **Downloads come from the publisher and are checked.** A marketplace tool downloads from the publisher's own site or release page and is verified against the publisher's published hash or checksum file. No mirrors, no unchecked downloads.
6. **No telemetry, no accounts, no new servers.** Stackyard only goes online for version lists and the downloads people choose. Adding any other network call needs an issue and agreement first.
7. **Environment changes are reversible.** Windows: the user's or machine's variables, through the plan. macOS: a marked block in `~/.zprofile`, plus `launchctl` for apps started from the Dock. Removing a tool removes its variables.

### Both platforms

8. **Windows and macOS are equal.** A change has to work on both, or be clearly limited to one (`Sys.isWindows`, `Platform.isMacOS`) with the other left as it was. Say in the pull request which systems you tested on; CI builds and tests both.
9. **No hard-coded paths or labels from one OS.** Use `Sys.home`, `Sys.trashName`, `Sys.fileManager` and `path` instead of `C:\…`, "Recycle Bin" or "Finder".

### Code

10. **Small and plain.** Fix the cause, not the symptom. Prefer the standard library and what's already in the codebase over a new package or abstraction. A new dependency needs a reason in the pull request.
11. **Match the code around you.** Same naming, comment style and structure. Comments explain *why*, not *what*.
12. **Words people understand.** UI text says what happens in plain words ("Moves Flutter 3.22 to the Trash"), not jargon. Every problem shown to the user comes with a button that fixes it.
13. **Tests.** New logic gets a unit or widget test in `test/`. Anything that touches the real machine (downloads, `launchctl`, the registry, simulators) is a live test behind `--dart-define=LIVE=true` and must clean up after itself. Tests must never change the real machine by default.

## Set up

Follow [Run it](README.md#run-it) in the README: FVM picks the pinned Flutter version from `.fvmrc`. Then, before you open a pull request:

```bash
fvm flutter analyze
fvm flutter test
```

Both must pass with no new warnings. For changes that affect what the app does on a real machine, also run the matching live or integration test from [Tests](README.md#tests).

To support a new tech, see [Adding a tech](README.md#adding-a-tech): one class in `lib/core/techs/`, registered in `lib/core/registry.dart`.

## Pull requests

- One change per pull request, on a branch of your fork. Link the issue it closes.
- Describe what changed and why, which OS you tested on, and how. Add a screenshot or short recording for anything visible.
- Keep commits focused, with messages that say what they do ("Detect Java from SDKMAN on macOS").
- CI (analyze, tests and a build on macOS and Windows) must be green.
- Be patient and kind in review. Suggestions are about the code, never the person.

By contributing, you agree that your contribution is released under the project's [MIT License](LICENSE).

## Security

If you find a way Stackyard could delete the wrong files, run something unexpected or download something unchecked, please don't open a public issue. Report it privately as described in [SECURITY.md](SECURITY.md), so it can be fixed before it's widely known.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Support the project

Stackyard is free and every feature stays in the free app. If you'd like to support it without writing code, you can [buy me a coffee](https://aqibjaved.dev/coffee). Thank you.
