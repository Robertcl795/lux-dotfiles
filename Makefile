.PHONY: help install test test-lux theme fastfetch ai-deploy ai-scaffold backup clean

# Default target
help:
	@echo "Dotfiles — make targets"
	@echo ""
	@echo "  make install                     Run the full bootstrap (install/run.sh)"
	@echo "  make test                        Run every checkpoint (tests/99_smoke.sh)"
	@echo "  make test-lux                    Run isolated Lux alpha tests and ShellCheck"
	@echo "  make theme THEME=<name>          Switch prompt theme"
	@echo "                                   (default|tron|cyber|eva01|minimal)"
	@echo "  make fastfetch                   Reinstall/relink the fastfetch greeting"
	@echo "  make ai-deploy                   Deploy the AI development standard globally"
	@echo "  make ai-scaffold TARGET=<path>   Scaffold the AI standard into a repo"
	@echo "  make backup                      Back up shell/git configs from \$$HOME"
	@echo "  make clean                       Remove local backup/ contents"
	@echo ""

install:
	@echo "🚀 Installing dotfiles..."
	@bash install/run.sh

test:
	@echo "🧪 Running checkpoints..."
	@bash tests/99_smoke.sh

test-lux:
	@command -v bats >/dev/null || { echo "Missing bats" >&2; exit 1; }
	@command -v shellcheck >/dev/null || { echo "Missing shellcheck" >&2; exit 1; }
	@shellcheck -x -P lux lux/bin/lux lux/lib/*.sh lux/install.sh lux/hooks/* lux/tests/helpers/*
	@bats lux/tests
	@python3 -B -m unittest discover -s lux/tests -p 'test_*.py'

theme:
	@test -n "$(THEME)" || (echo "Usage: make theme THEME=default|tron|cyber|eva01|minimal" && exit 1)
	@DOT_THEME=$(THEME) bash install/prompt/starship.sh --run

fastfetch:
	@bash install/fastfetch.sh --run

ai-deploy:
	@echo "🤖 Deploying AI development standard..."
	@bash install/ai.sh --run

ai-scaffold:
	@test -n "$(TARGET)" || (echo "Usage: make ai-scaffold TARGET=/path/to/repo" && exit 1)
	@bash ai/scaffold.sh "$(TARGET)"

backup:
	@echo "💾 Creating backup..."
	@mkdir -p backup
	@for file in .zshrc .zshrc.local .gitconfig .config/starship.toml .config/fastfetch/config.jsonc; do \
		if [ -f "$$HOME/$$file" ]; then \
			cp "$$HOME/$$file" "backup/$$(basename $$file).$(shell date +%Y%m%d-%H%M%S)"; \
			echo "✓ Backed up $$file"; \
		fi \
	done
	@echo "✓ Backup complete"

clean:
	@echo "🧹 Cleaning backup files..."
	@rm -rf backup/*
	@echo "✓ Backup files cleaned"
