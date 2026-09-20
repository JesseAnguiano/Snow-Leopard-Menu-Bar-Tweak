SHELL := /bin/bash

.PHONY: all check audit build helper package test test-sidebar install install-helper install-all verify release-check clean help

all: check build helper

check:
	./scripts/check-project.sh

audit:
	./scripts/audit-repository.py

build: check
	./scripts/build.sh

helper: check
	./scripts/build-wallpaper-source.sh

package: check
	./scripts/build-package.sh

test: check
	./tests/run-menubar-regressions.sh

test-sidebar: build
	./tests/run-sidebar-harness.sh

install: build
	./scripts/install.sh

install-helper: helper
	./scripts/install-wallpaper-source.sh

install-all: build helper
	./scripts/install-wallpaper-source.sh
	./scripts/install.sh

verify:
	./scripts/verify.sh
	./scripts/verify-blueselection.sh

release-check: check test

clean:
	rm -rf build dist

help:
	@printf '%s\n' \
		'make all           - validate and build both dylibs + wallpaper helper' \
		'make test          - run deterministic regression tests' \
		'make test-sidebar  - build and run the optional sidebar harness' \
		'make package       - build a release .pkg under dist/' \
		'make release-check - repository audit + deterministic tests' \
		'make clean         - remove generated build/release output'
