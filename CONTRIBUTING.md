# Contributing

Bug reports and pull requests are welcome. This is a small project for one
specific setup, so please open an issue before starting anything large.

## Before you open a pull request

* **Test it on real hardware.** Nothing here can be tested without a rooted
  webOS TV and an Asuswrt-Merlin router. Say in the pull request what you ran
  it on (TV model and webOS version, router model and firmware) and what you
  didn't test.
* **Keep the router scripts POSIX `sh`.** The router runs BusyBox `ash`, so no
  bash-isms. CI runs ShellCheck on `router/` and `tools/`; run it locally
  with `shellcheck router/*.sh tools/*.sh`. Suppress a warning only when the
  behaviour is intended, with a comment saying why.
* **Keep the app dependency-free.** `app/index.html` is the whole app, plain
  HTML and ES5 JavaScript for the TV's browser engine, with no build step.
* **Bump `version` in `app/appinfo.json`** if you change the app.
* **Never include your NordLynx private key or access token** in an issue,
  log or commit. Remove the `private key` line from any `wg show` output.

## Style

* British English in code comments, docs and on-screen text.
* Comments explain why, not what.
* Commit messages start with an area or type, for example `Router: …`,
  `App: …`, `Fix: …`, `Docs: …`, `CI: …`.

## Security issues

Don't open a public issue; see [SECURITY.md](SECURITY.md).

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
