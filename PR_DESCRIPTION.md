## Problem

The installer did not complete successfully when the repository directory had
the same name as the executable—the normal layout produced by cloning this
repository.

Running:

```sh
./install.sh install
```

built the Swift executable, but then failed during code signing with output
like:

```text
ZoomStupidWorkplaceAutominimizer: code object is not signed at all
In subcomponent: /path/to/ZoomStupidWorkplaceAutominimizer/install.sh
```

Because the script exits on the first error, it stopped before installing the
newly built binary or loading the LaunchAgent. In other words, the install
command looked as though it had made progress, but the application was not
actually installed and running.

There was a second confusing symptom: running `./install.sh status` while the
LaunchAgent was absent could exit without printing anything. This made it hard
to tell whether installation had failed, the agent had stopped, or the status
command itself was broken.

## Why it failed

The installer built and signed an executable using only the relative path
`ZoomStupidWorkplaceAutominimizer`. Because that name also matched the checkout
directory, `codesign` could resolve the wrong code object and treat the
repository—including `install.sh`—as a bundle being signed. Signing then failed
because the shell script appeared as an unsigned nested component.

Separately, `daemon_pid` expected `launchctl print` to fail when no LaunchAgent
was loaded, but `set -o pipefail` propagated that expected failure. Combined
with `set -e`, the whole status command exited before it could report
`Daemon: not running.`

## What changed

- Build the executable at an absolute path under `.build/`, avoiding the
  repository/executable name collision.
- Keep Swift's module cache under `.build/` as well.
- Sign and install that exact built executable.
- Ignore `.build/` in version control.
- Treat a missing `launchctl` service as the normal "not running" result rather
  than a fatal shell error.

With these changes, `./install.sh install` signs the intended Mach-O executable
and can continue to install it and load the LaunchAgent.

When the LaunchAgent is not running, `./install.sh status` now explicitly
prints `Daemon: not running.` If an installed binary exists, it also runs a
one-off diagnostic while explaining that the Accessibility result reflects the
terminal's context; if no binary exists, it reports that the program is not
installed. The status command does not start the agent.

## Testing

- `bash -n install.sh`
- `git diff --check`
- Compiled the executable successfully at
  `.build/ZoomStupidWorkplaceAutominimizer`
- Ad-hoc signed the built executable with identifier
  `com.example.ZoomStupidWorkplaceAutominimizer`
- Verified the signature with `codesign --verify --strict --verbose=2`
- Ran `./install.sh status` with no LaunchAgent loaded and confirmed it reports
  `Daemon: not running` instead of exiting silently
