# Contributing

Thanks for helping improve Codex Vitals.

Before opening a pull request:

- Keep the app local-first. Do not add remote sync, account sharing, or automation hooks.
- Do not log tokens, bearer headers, OAuth responses, or full auth JSON.
- Keep sensitive files owner-only and preserve the documented storage contract.
- Keep saved Claude credentials in the app-specific macOS Keychain service; never persist them in account metadata, logs, snapshots, or command arguments.
- Claude switches must preserve non-account settings, copy only allowlisted live shared fields, verify the destination, and roll back both Keychain and config state on failure.
- For macOS changes, run `swift test`; for UI or packaging changes, also run `./build-app.sh`.
- For Windows changes, set `PYTHONPATH=windows` and run `python -m unittest discover windows\tests`.

Security reports should follow [SECURITY.md](SECURITY.md).
