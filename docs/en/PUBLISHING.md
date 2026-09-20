# Publishing to GitHub

> [Versión en español](../es/PUBLISHING.md)

Before the first public push, review `LICENSE`, `SECURITY.md` and the asset-rights note in `ASSETS.md`. The MIT license covers project code; it does not automatically grant rights to unrelated artwork or reference material.

Recommended pre-push validation:

```bash
make release-check
```

Then, on the target macOS Sequoia build, also run the full build and manual smoke tests:

```bash
make all
```

Do not commit `build/`, `dist/`, compiled dylibs/apps/packages, generated headers, local logs, backups or machine-specific paths. `scripts/audit-repository.py` is part of `make release-check` and checks common privacy/path/metadata leaks.

A typical first push is:

```bash
git init
git add .
git commit -m "Initial public source import"
git branch -M main
git remote add origin git@github.com:YOUR-USER/Snow-Leopard-Menu-Bar-Tweak.git
git push -u origin main
```

For binary distribution, create the `.pkg` from a tagged commit with `make package` and upload the generated package from `dist/` to GitHub Releases. Record the tested macOS build, architectures and known limitations in the release notes.
