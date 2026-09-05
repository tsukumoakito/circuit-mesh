# circuit-mesh Makefile
# SPDX-FileCopyrightText: 2026 TSUKUMO Akito <tsukumoakito99@duck.com>
# SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-circuit-mesh-Commercial

ZIG_VER    ?= 0.15.2
PREFIX     ?= /usr
CONFDIR    ?= /etc/circuit-mesh
BINDIR      = $(DESTDIR)$(PREFIX)/bin
MANDIR      = $(DESTDIR)$(PREFIX)/share/man
DOCDIR      = $(DESTDIR)$(PREFIX)/share/doc/circuit-mesh
LICENSEDIR  = $(DESTDIR)$(PREFIX)/share/licenses/circuit-mesh
ETCDIR      = $(DESTDIR)$(CONFDIR)
SERVICEDIR  = $(DESTDIR)$(PREFIX)/lib/systemd/system

HAS_SYSTEMD = $(shell [ -d /usr/lib/systemd/system ] && echo yes || echo no)

.PHONY: all build check-zig install uninstall clean

all: build

check-zig:
	@ZIG_CURRENT=$$(zig version); \
	case $$ZIG_CURRENT in \
		$(ZIG_VER)*) \
			echo "✅ Zig version $$ZIG_CURRENT detected."; \
			;; \
		*) \
			echo "❌ Error: Current circuit-mesh version requires Zig $(ZIG_VER)."; \
			echo "   Currently using: $$ZIG_CURRENT."; \
			echo "   Please run your zig package manager such as 'zvm use $(ZIG_VER)' before building."; \
			exit 1; \
			;; \
	esac

build: check-zig
	zig build -Doptimize=ReleaseSafe

install:
	install -Dm755 zig-out/bin/circuit-mesh "$(BINDIR)/circuit-mesh"

	install -d "$(ETCDIR)"
	@if [ -f "$(ETCDIR)/config.json" ]; then \
		echo "⚠️  Existing config.json found. Installing as config.json.example"; \
		install -m644 config.json "$(ETCDIR)/config.json.example"; \
	else \
		install -m644 config.json "$(ETCDIR)/config.json"; \
	fi

	install -Dm644 zig-out/share/man/man1/circuit-mesh.1 "$(MANDIR)/man1/circuit-mesh.1"
	install -Dm644 zig-out/share/man/ja/man1/circuit-mesh.1 "$(MANDIR)/ja/man1/circuit-mesh.1"

	install -Dm644 doc/MANUAL.md "$(DOCDIR)/MANUAL.md"
	install -Dm644 doc/MANUAL_ja.md "$(DOCDIR)/MANUAL_ja.md"
	install -Dm644 doc/COMMERCIAL.md "$(DOCDIR)/COMMERCIAL.md"
	install -Dm644 README.md "$(DOCDIR)/README.md"
	install -Dm644 README_ja.md "$(DOCDIR)/README_ja.md"

	install -Dm644 LICENSE "$(LICENSEDIR)/LICENSE"
	install -Dm644 LICENSES/LicenseRef-circuit-mesh-Commercial.txt "$(LICENSEDIR)/LicenseRef-circuit-mesh-Commercial.txt"

	@if [ "$(HAS_SYSTEMD)" = "yes" ]; then \
		echo "✅ systemd detected. Installing service file..."; \
		install -Dm644 zig-out/share/circuit-mesh/circuit-mesh.service "$(SERVICEDIR)/circuit-mesh.service"; \
	else \
		echo "ℹ️  systemd not detected. Skipping service file installation."; \
	fi

uninstall:
	rm -f "$(BINDIR)/circuit-mesh"
	rm -f "$(MANDIR)/man1/circuit-mesh.1"
	rm -f "$(MANDIR)/ja/man1/circuit-mesh.1"
	rm -f "$(SERVICEDIR)/circuit-mesh.service"
	rm -rf "$(DOCDIR)"
	rm -rf "$(LICENSEDIR)"
	@echo "ℹ️  Note: $(ETCDIR) was preserved to protect your configuration."
	@echo "   To remove it manually, run: sudo rm -rf $(ETCDIR)"

clean:
	rm -rf zig-out .zig-cache
