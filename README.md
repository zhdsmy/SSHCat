# SSHCat

**English** · [简体中文](README.zh-Hans.md)

A macOS menu bar app for long-running SSH port forwarding. SSHCat runs the system `ssh -N` as a child process and supervises it, reconnecting with backoff after an unexpected exit, wake from sleep, or a network change. It does not implement the SSH protocol.

Each rule runs one SSH connection and can combine local (`-L`), remote (`-R`), and dynamic (`-D`) forwards to the same host.

![SSHCat: the menu bar panel and the management window](docs/screenshots/overview-en.png)

The screenshot uses temporary sample data and a fake SSH process. It contains no real configuration or connections.

## Requirements

- macOS 13 or later, on Apple silicon or Intel.
- The system `/usr/bin/ssh`, or another executable selected in Settings.
- Key-based or ssh-agent authentication already working for the destination. SSHCat uses `BatchMode=yes` and does not show password prompts.
- Connect to a new host once in Terminal and verify its host key before using it in SSHCat. With `BatchMode=yes`, an unknown host key causes the connection to fail instead of asking for confirmation.

## Installation

1. Download `SSHCat-<version>.dmg` from [Releases](https://github.com/zhdsmy/SSHCat/releases), open it, and drag SSHCat into Applications.
2. The app is ad-hoc signed and has not been notarized by Apple. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/SSHCat.app`.
3. Optionally download the matching `.sha256` file and verify the DMG with `shasum -a 256 -c SSHCat-<version>.dmg.sha256` from the download directory.

**Check for Updates** in Settings contacts GitHub only when clicked. Download the new DMG and replace the app to upgrade; updates are not installed automatically.

## Languages

The app supports English, Simplified Chinese, and Traditional Chinese. It follows the system language by default and falls back to English for unsupported languages. Select a language in **Settings → General → Language** to override it. The change takes effect the next time SSHCat starts, without restarting or interrupting your current forwards.

Menus, the management window, the guide, validation messages, notifications, and diagnostics share the localization resources. User data such as rule names, SSH commands, and raw SSH output are preserved. Changing languages does not rewrite saved rules.

## Build

```bash
./scripts/bundle.sh                # build/SSHCat.app
open build/SSHCat.app
UNIVERSAL=1 ./scripts/make-dmg.sh  # Universal DMG and SHA-256 file
```

`bundle.sh` builds for the current architecture by default. `UNIVERSAL=1` builds both arm64 and x86_64 and verifies that both are present. `make-dmg.sh` runs `bundle.sh` first and reads the version from `Resources/Info.plist`. Both the app and its localization resource bundle are included in the DMG.

Tests and icons:

```bash
swift build
swift build --product SSHCatPackageTests && swift test --skip-build
swift scripts/make-icon.swift
```

With only Command Line Tools installed, build the test product before running `swift test --skip-build`. With Xcode, `swift test` can run directly. The app icon is generated in `Resources/AppIcon.icns`; the menu bar icon is drawn in `Sources/SSHCat/MenuBarIcon.swift`.

Safe UI snapshots:

```bash
./scripts/snapshot.sh --language=en
./scripts/snapshot.sh --language=zh-Hans
./scripts/snapshot.sh --language=zh-Hant --dark
```

Snapshots are available only in debug builds. They use temporary rules, isolated preferences, and `/bin/sh` as fake SSH. They do not read real rules or `~/.ssh/config`, change login items, or establish real SSH connections. Images are written to `build/snapshots-<language>[-dark]/`; English is the default. Set `SSH_CAT_SCRATCH_PATH` and `SSH_CAT_SNAPSHOT_ROOT` to use temporary build and image directories. Scenarios include target failures, changed host keys, remote SOCKS and effective-configuration previews.

The scenes also cover field errors, state filters, the host picker, import preview, quit confirmation, and system permission states. The isolated harness checks actual port text editing, draft restoration after switching rules, both quit-confirmation outcomes, and first/subsequent import sheets after cancellation. Scrollable pages produce additional `-scroll-N` images. Snapshots exclude title bars and toolbars and do not replace full interaction testing of native file dialogs or System Settings. Switches in unfocused windows may look gray. Sample rule names stay the same across languages for comparison.

For development:

```bash
swift run SSHCat
```

A plain `swift build` executable is not an app bundle and may show a Dock icon. Use the bundled `SSHCat.app` for the menu bar app experience.

## Create a forward

1. Choose **New Forward** in the menu bar and select a local forward, remote forward, local SOCKS proxy, or remote SOCKS proxy. You can also use the management window's add menu or the built-in guide.
2. Enter a `Host` alias from `~/.ssh/config`, a hostname, or an IP address. The host picker supports search and refresh, including aliases in `Include` files. Leave user, port, and key blank to use that host's SSH configuration, including `ProxyJump`.
3. Set a port (`-p`) or an identity file (`-i`, with `IdentitiesOnly=yes`) only when you need an override.
4. Add one or more forwards:
   - **Local:** a local listening address and port forward to a destination reachable from the SSH server.
   - **Remote:** an address and port on the SSH server forward to a destination reachable from your Mac. Listening on a non-loopback address requires `GatewayPorts` on the server.
   - **Dynamic:** a local SOCKS proxy.
   - **Remote SOCKS:** a SOCKS listener on the SSH server whose destinations are reached from your Mac (`-R address:port`, without a fixed target). Requires an OpenSSH 7.6+ client; SSHCat checks the selected binary before connecting.
5. Choose **Save and Connect**, or save and turn on the rule. Turning it off releases its listeners. Closing the management window leaves forwards running; quitting SSHCat stops the processes it owns.

Search rules by name, host, or port, and filter the menu or sidebar to running or failed rules. The menu shows forwarding endpoints; listener-conflict warnings identify the affected rules. **Create Copy** in the **…** menu copies the saved configuration with new IDs and automatic startup disabled. Choose another listening port to avoid conflicting with the original rule.

Unsaved edits, including empty or invalid port text, survive switching rules or closing the management window. Errors appear beside their fields. Whitespace-only edits and equivalent port values do not count as pending changes. Quitting with unsaved changes lets you return to editing or explicitly discard them. Drafts are not persisted across app launches. A stopped rule with pending changes requires saving before starting; **Save and Connect** does both. Changes reach an active connection only after a successful save.

Use **Retry Now** on a failed connection or during a reconnect countdown to try immediately. **Copy First Connection Command** copies a command to run manually in Terminal, using the saved host, port, user, and key. It allows you to verify the host fingerprint and authenticate without starting forwards; SSHCat never runs this interactive command itself.

IPv6 works for SSH hosts and forwarding addresses, with or without brackets: for example, `2001:db8::1` or `[2001:db8::1]`. The app adds brackets in forwarding arguments such as `[::1]:8080:[2001:db8::2]:8080`. Enter the SSH port in its own field. Scoped addresses such as `fe80::1%en0` are also supported. Conflict checks distinguish IPv4 and IPv6 listeners without doing DNS lookups; `localhost` matches `127.0.0.1` and `::1`, while other addresses in `127.0.0.0/8` remain independent. They cannot predict every hostname alias or listener opened by another app.

Host suggestions expand relative `Include` paths from `~/.ssh`, plus absolute paths, `~/` paths, quoted paths, and globs. Cycles, unreadable files, and non-regular files are skipped; scanning is bounded to 16 include levels, 256 files, and 1 MiB. Suggestions do not evaluate `Host`/`Match` conditions or run `Match exec`; SSH still resolves the actual connection settings.

The menu displays connection states and scrolls when needed. Copy local addresses from the menu or rule details. Expand the equivalent command and connection log for troubleshooting; copy buttons briefly confirm success. **Running** indicates an established SSH session; the destination service and port still need to be available.

For example, forwarding the remote loopback port 8080 to local port 8080 for user `app` on host `devbox` produces a command like:

```text
ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes \
  -o ControlMaster=no -o ControlPath=none \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -o ConnectTimeout=10 -o LogLevel=VERBOSE \
  -L 127.0.0.1:8080:127.0.0.1:8080 app@devbox
```

`ControlMaster=no` keeps the connection under the app's ownership, so stopping a rule stops its forward. `ServerAlive*` lets a broken session exit so it can reconnect with backoff. `ExitOnForwardFailure=yes` prevents failed listeners from appearing to work. `ConnectTimeout=10` bounds connection setup, and `LogLevel=VERBOSE` reports authentication progress. SSHCat uses the authentication message to detect a running session, with a delayed fallback for SSH builds that log differently.

The equivalent command can be copied, but SSHCat itself always launches SSH using an argument array, never through a shell.

## SSH troubleshooting

SSHCat records failed forwarding attempts from SSH's existing logs without making probe connections. A remote `connect_to` error is shown beside a forward only when its target matches exactly one saved remote forward. Channel errors that omit an endpoint appear at rule level, including local and SOCKS errors. These warnings describe a past attempt, not continuous service health: no warning does not prove reachability, and later success may not be logged. Clear them manually; reconnecting also clears them. Target errors do not restart the SSH session.

Failure hints distinguish unknown and changed host keys, excessive agent keys, refused connections, timeouts, and remote listener failures. A remote listener may be held by an old sshd session or blocked by server forwarding policy; it remains eligible for backoff retries. A changed host key is a prominent warning. Verify the new fingerprint with the server administrator before removing any trusted entry.

Choose **Effective SSH Configuration**, then **Read Configuration**, to run `ssh -G` using the selected executable, current editor values, and the same command-line overrides as a connection. It shows User, HostName, Port, ProxyJump, IdentityFile, IdentityAgent and all effective forwards. Additional forwards inherited from SSH config are highlighted because their listener conflicts can fail the entire rule. Reading does not establish an SSH session, but **SSH config's `Match exec` commands may execute**. Reads are limited to five seconds and 256 KiB; closing the preview cancels its SSH process. For changed keys, SSHCat reconstructs a quoted `ssh-keygen -f ... -R ...` command from SSH's own removal suggestion, retaining the correct jump host when applicable. If no suggestion was logged, the preview can generate one from the offending file and effective HostName/HostKeyAlias and port for a direct connection. It does not guess which host failed on a proxy connection. SSHCat only copies the command; it does not execute it or edit trusted keys.

GUI apps do not inherit `.zshrc` exports. For 1Password, Secretive or another agent, set an absolute **Agent socket path** in Settings, or configure `IdentityAgent` under the relevant Host in `~/.ssh/config`. The global setting overrides every Host's IdentityAgent; leave it blank to preserve SSH configuration and `SSH_AUTH_SOCK`. Changes apply to the next connection and do not interrupt existing sessions. Equivalent commands and first-connection commands include the override. Copied diagnostics show the override, whether `SSH_AUTH_SOCK` is set and whether its path exists; path existence does not prove an agent is responding.

Remote SOCKS grants the server access through your Mac's network. Keep its listener on loopback and restrict destinations with the client-side `PermitRemoteOpen` option, which requires OpenSSH 8.5+. For example:

```sshconfig
Host devbox
    IdentityAgent "/Users/me/Agent Sockets/agent.sock"
    PermitRemoteOpen service.internal:443 192.168.1.10:5432
```

Existing v1 rules continue to load unchanged. Archives containing the new remote SOCKS type require a version of SSHCat that supports it.

## Import, export, and system permissions

Use the management toolbar's **Import and Export** menu to export the selected saved rule or all saved rules as v1 JSON. Complete invalid or unfinished rules before exporting. Import and export share a limit of 8 MiB and 1,000 valid rules per file. Export rejects oversized archives before writing, preserving any existing destination file; export individual rules if the full set exceeds the limit. Import shows the selected file’s rules in a preview before writing anything. Rules with an existing ID or identical configuration are duplicates; choose to skip them or import copies. Existing rules are preserved, imported rules receive fresh IDs, and automatic startup is disabled. Import never connects them automatically. Key paths remain local paths; private keys are not included.

Settings shows macOS notification authorization separately from SSHCat's notification switch, with a link to System Settings. Login-item status also shows when macOS approval is pending and provides the appropriate Settings link. Status refreshes when the app becomes active again.

## Data and privacy

Data lives in `~/Library/Application Support/SSHCat/`: directories use mode 0700, files use mode 0600, and writes are atomic.

| File | Contents |
| --- | --- |
| `forwards.json` | Forwarding rules |
| `pids.json` | Child process IDs used to clean up orphaned SSH processes after a crash |

Preferences use the `io.github.zhdsmy.SSHCat` UserDefaults suite: `customBinaryPath`, `notificationsEnabled`, and `language`. Existing installations without a language setting follow the system. Login items are managed by `SMAppService`. SSHCat does not save passwords or read private key contents; it passes only the key path to SSH.

Adding, editing, and deleting rules saves to disk before changing the UI or processes. A failed save preserves the original rules, running connections, and drafts. Read errors and unsupported file versions preserve the original file and prevent overwrites; fix the issue and choose **Reload Configuration**. Corrupt JSON is set aside only after a successful backup. A failed backup blocks saving. The data format remains v1 and existing rules remain compatible.

## Implementation and localization

- `SSHCatCore` contains models, argument construction, and process supervision without depending on SwiftUI. Tests use fake SSH shell scripts.
- Child output is read on a dedicated thread so long-running SSH sessions do not occupy GCD worker threads.
- Views avoid SwiftUI macros so the project can build with Command Line Tools alone.
- Native SwiftPM `.lproj/*.strings` catalogs live in `Sources/SSHCatCore/Resources/`. `Localizable.strings` contains UI copy, while `Core.strings` contains model, error, notification, and diagnostic messages. Both use the Foundation-only `L10n` entry point.

When adding text, use a stable semantic key and update all three catalogs: `en`, `zh-Hans`, and `zh-Hant`. Use `%@` or `%ld` for arguments and positional placeholders when a language needs a different word order; do not concatenate translated sentence fragments. Tests check locale selection, key coverage, format arguments, and source references. Run light and dark snapshots for affected languages to catch clipping, especially with longer English text.

## Contributing

See [AGENTS.md](AGENTS.md) for development conventions, safety requirements, commits, and releases, and [CHANGELOG.md](CHANGELOG.md) for changes. Pushing a `vX.Y.Z` tag triggers GitHub Actions to build and publish the universal DMG.

## License

[MIT](LICENSE)
