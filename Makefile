# AutoADHD vault developer tasks. Run from the vault root.
VAULT_DIR ?= $(CURDIR)
FOCUS ?= overview
export VAULT_DIR

.PHONY: check validate canvas health install-hooks help
help:           ## list targets
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## / - /'
check:          ## syntax + compile + shellcheck + frontmatter
	bash Meta/scripts/ci-check.sh
validate:       ## frontmatter schema report (add ARGS=--fix to auto-fix)
	python3 Meta/scripts/validate-frontmatter.py $(ARGS)
canvas:         ## rebuild Obsidian canvas (FOCUS=people|actions|overview)
	bash Meta/scripts/build-canvas.sh $(FOCUS)
health:         ## vault health check
	bash Meta/scripts/run-health.sh
install-hooks:  ## install pre-commit-guard.sh (blocks Canon deletions) — run once after cloning
	@printf '#!/bin/sh\nexec "$$(git rev-parse --show-toplevel)/Meta/scripts/pre-commit-guard.sh" "$$@"\n' \
		> .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "installed: .git/hooks/pre-commit -> Meta/scripts/pre-commit-guard.sh"
