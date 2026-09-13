# Publishing to GitHub

> [Versión en español](../es/PUBLISHING.md)

This repository is distributed under the **MIT License**. Review [`LICENSE`](../../LICENSE) before publishing, and keep the copyright and permission notice with copies or substantial portions of the software.

A typical first push is:

```bash
git init
git add .
git commit -m "Initial public source import"
git branch -M main
git remote add origin git@github.com:YOUR-USER/Snow-Leopard-Menu-Bar-Tweak.git
git push -u origin main
```

Do not add `build/` or compiled dylibs to normal commits. For binary distribution, build from a tagged commit and upload the artifacts to a GitHub Release. Record the exact commit, macOS version tested, architectures, and known limitations in the release notes.

Recommended pre-push checks:

```bash
./scripts/check-project.sh
./tests/run-menubar-regressions.sh
```

The second command requires macOS Sequoia and the Xcode Command Line Tools.
