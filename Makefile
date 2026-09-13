SHELL := /bin/bash

.PHONY: all check build helper package test test-sidebar install install-helper install-all verify clean

all: check build helper

check:
	./scripts/check-project.sh

build: check
	./scripts/build.sh

helper: check
	./scripts/build-wallpaper-source.sh

package:
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

clean:
	rm -rf build dist
