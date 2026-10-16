# Security policy

Stackyard deletes files, runs installers and changes environment variables on people's machines, so security reports get priority over everything else.

## Supported versions

Only the [latest release](https://github.com/AqibJavedZeepalm/stackyard/releases/latest) gets fixes. Please check that the problem still happens there.

## Reporting a vulnerability

Please don't open a public issue. Report it privately, so it can be fixed before it's widely known:

- **Preferred:** the repository's [Security → Report a vulnerability](https://github.com/AqibJavedZeepalm/stackyard/security/advisories/new) form.
- Or the [private contact form](https://aqibjaved.dev/contact/).

Examples of what counts: Stackyard deleting or moving the wrong files, running something you didn't confirm, downloading something that isn't checked against the publisher's hash, or writing secrets or private paths somewhere they could leak.

Include the Stackyard version, your OS, and the steps or the job log (open the job in Activity and select its log).
