# Security

This project injects code into selected macOS processes through Ammonia and uses private AppKit/WindowServer behavior. Treat every release as system-modifying software and test it on the exact macOS build you intend to use.

## Reporting a problem

For crashes, unsafe process coverage, installer problems, or unexpected system changes, open a GitHub issue with the macOS version/build, affected process, reproduction steps, and a minimal log excerpt when available. Remove usernames, home-directory paths, window titles, file names, and other private data before attaching logs or screenshots.

## Project safeguards

The repository intentionally:

- validates the target macOS major version and process scope before installing runtime hooks;
- validates private method encodings before replacing implementations where practical;
- keeps the menu-bar and BlueSelection runtime components separate;
- signs and verifies locally built artifacts before installation;
- rejects machine-specific paths and common document/XMP metadata during repository checks;
- avoids network access and does not bundle Ammonia.

Private APIs are not stable contracts. A future macOS update can invalidate runtime assumptions even when the project still compiles.
