# Contributing to MXC for Ruby

Working with a coding agent? [AGENTS.md](AGENTS.md) has the commands, layout, and conventions. It is worth a read for humans too.

## Did you find a bug?

* **Check whether it is already reported** in [Issues](https://github.com/crmne/mxc/issues).
* **Check the host first.** Many failures are machine configuration: Bubblewrap missing or blocked, a container's seccomp profile, missing network tools. Include the output of `MXC.availability.inspect` and `MXC.availability.remediation`, your operating system, and, in a container, the runtime and its `--security-opt` flags.
* **Include a short Ruby snippet** that reproduces the problem.
* **Problems in MXC itself** belong upstream in [microsoft/mxc](https://github.com/microsoft/mxc).

## Did you find a security problem?

Do not open a public issue. Use GitHub's private vulnerability reporting on this repository. If the problem is in MXC itself, report it to Microsoft privately.

## Do you want to change something?

* **Keep pull requests focused.** One change, with tests and docs.
* **Keep the API small.** 0.x deliberately leaves out PTYs, long-lived containers, and UI policies. Open an issue before building something large.
* **Prove it.** Add a test that fails before your change. Tests that need a sandbox skip on machines that cannot start one, so also run them where they can, such as in the Docker test image (`docs/assets/docker/test.sh`).
* **Document it.** RDoc on public methods, and the matching guide in `docs/_guides/`.
* **Use whatever tools you like, AI included.** You are responsible for every line you submit.

## Quick start

```sh
gh repo fork crmne/mxc --clone && cd mxc
bin/setup              # bundle install, compile the extension
overcommit --install   # pre-commit hooks
bundle exec rake       # compile, tests, Rust unit tests, RuboCop
```

You need Ruby 3.2 or later and a Rust toolchain; `rust-toolchain.toml` pins the version rustup installs. On Linux, install `bubblewrap`, plus `slirp4netns`, `iptables`, and util-linux to run the network tests.

Preview the docs with:

```sh
cd docs && bundle install && bundle exec jekyll serve
```
