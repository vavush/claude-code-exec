.PHONY: install uninstall check test

PREFIX ?= /usr/local

install:
	@echo "Installing claude-code-exec scripts to $(PREFIX)/bin..."
	install -m 755 bin/cc-executor.sh $(PREFIX)/bin/cc-executor.sh
	install -m 755 bin/cc-orchestrate.sh $(PREFIX)/bin/cc-orchestrate.sh
	install -m 755 bin/cc-monitor.sh $(PREFIX)/bin/cc-monitor.sh
	@echo "Done."
	@echo ""
	@echo "Prerequisites (must be installed separately):"
	@echo "  - tmux"
	@echo "  - ollama (with ollama launch claude working)"
	@echo "  - npm install -g @anthropic-ai/claude-code"
	@echo ""
	@echo "Quick test: cc-executor.sh --help"

uninstall:
	rm -f $(PREFIX)/bin/cc-executor.sh
	rm -f $(PREFIX)/bin/cc-orchestrate.sh
	rm -f $(PREFIX)/bin/cc-monitor.sh
	@echo "Uninstalled."

check:
	@for script in bin/cc-executor.sh bin/cc-orchestrate.sh bin/cc-monitor.sh; do \
		bash -n $$script && echo "  $$script: syntax OK" || { echo "  $$script: SYNTAX ERROR"; exit 1; }; \
	done

test: check
	@echo "All checks passed."