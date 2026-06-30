# hep-feedstocks / hep-forge feedstock Makefile
#
# Self-detecting: works at the meta-repo root AND when copied into a single feedstock.
#   - Root level  (feedstocks/ dir present):  targets operate on ALL feedstocks
#   - Feedstock   (recipe/ dir present):       targets operate on THIS feedstock
#
# Meta-repo usage:
#   make forge          Install conda-smithy + tools
#   make render         Rerender all feedstocks (or: make render FEEDSTOCK=fastjet-feedstock)
#   make readme         Regenerate all README.md files (hep-forge badges/links)
#   make list           List all built .conda packages across feedstocks
#   make anaconda       Upload all built packages to hep-forge channel
#   make bot-check      Dry-run upstream version check (hep-bot)
#   make distribute     Copy this Makefile into every feedstock
#   make debug FEEDSTOCK=<name>  Debug one feedstock build
#
# Per-feedstock usage (after 'make distribute' or cp):
#   make forge          Install conda-smithy + tools
#   make render         Rerender this feedstock
#   make list           List built packages from this feedstock
#   make anaconda       Upload this feedstock's packages
#   make debug          Debug this feedstock build

IS_META     := $(shell [ -d feedstocks ] && echo 1 || echo 0)
FEEDSTOCKS  := $(wildcard feedstocks/*-feedstock)
ANACONDA_TOKEN := $(HOME)/.conda-smithy/anaconda.token

# ─────────────────────────────────────────────────────────────────────────────
ifeq ($(IS_META),1)
# META-REPO LEVEL
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: all forge render readme list anaconda bot-check distribute debug

all: forge render readme

forge:
	@conda install -c conda-forge -y \
	    conda-smithy conda-verify conda-package-handling anaconda-client

# Rerender all feedstocks, or one: make render FEEDSTOCK=fastjet-feedstock
render:
ifdef FEEDSTOCK
	@echo "=== Rerendering feedstocks/$(FEEDSTOCK) ==="
	@cd feedstocks/$(FEEDSTOCK) && \
	    conda smithy rerender --no-check-uptodate && \
	    echo "!Makefile" >> .gitignore && \
	    echo "!.github"  >> .gitignore && \
	    git add .gitignore 2>/dev/null || true && \
	    find . -maxdepth 2 -name conda-build.yml -delete
else
	@for dir in $(FEEDSTOCKS); do \
	    echo "=== Rerendering $$dir ==="; \
	    (cd $$dir && \
	        conda smithy rerender --no-check-uptodate && \
	        echo "!Makefile" >> .gitignore && \
	        echo "!.github"  >> .gitignore && \
	        git add .gitignore 2>/dev/null || true && \
	        find . -maxdepth 2 -name conda-build.yml -delete \
	    ) || echo "WARNING: rerender failed for $$dir"; \
	done
endif

readme:
	@python3 scripts/rerender_all.sh hep-forge

list:
	@find feedstocks -name "*.conda" ! -path "*/pkg_cache/*"

anaconda:
	@if [ ! -f "$(ANACONDA_TOKEN)" ]; then \
	    echo "Error: Anaconda token not found at $(ANACONDA_TOKEN)"; exit 1; \
	fi
	@for PKG in $$(find feedstocks -name "*.conda" ! -path "*/pkg_cache/*"); do \
	    conda-verify $$PKG && \
	    anaconda -t $$(cat $(ANACONDA_TOKEN)) upload --force $$PKG --label hep-forge; \
	done

bot-check:
	@python3 scripts/hep_bot/check_versions.py --dry-run

# Copy this Makefile into every feedstock directory
distribute:
	@for dir in $(FEEDSTOCKS); do \
	    cp Makefile $$dir/Makefile; \
	    echo "Distributed Makefile → $$dir"; \
	done

debug:
ifndef FEEDSTOCK
	$(error Usage: make debug FEEDSTOCK=<feedstock-name>)
endif
	@cd feedstocks/$(FEEDSTOCK) && \
	OUTPUT_ID=$$(conda render . --output 2>&1 \
	    | grep -E '\.(tar\.bz2|conda)$$' | sort | tail -1 | xargs -r basename); \
	if [ -n "$$OUTPUT_ID" ]; then \
	    conda debug . --output-id "$$OUTPUT_ID"; \
	else \
	    conda debug .; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
else
# FEEDSTOCK LEVEL  (this file was distributed into a single feedstock)
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: all forge render list anaconda debug

all: forge render list

forge:
	@conda install -c conda-forge -y \
	    conda-smithy conda-verify conda-package-handling anaconda-client

render:
	@conda smithy rerender --no-check-uptodate
	@echo "!Makefile" >> .gitignore
	@echo "!.github"  >> .gitignore
	@git add .gitignore 2>/dev/null || true
	@find . -maxdepth 2 -name conda-build.yml -delete

list:
	@find build_artifacts -name "*.conda" ! -path "*/pkg_cache/*" 2>/dev/null || echo "(no build_artifacts yet)"

anaconda:
	@if [ ! -f "$(ANACONDA_TOKEN)" ]; then \
	    echo "Error: Anaconda token not found at $(ANACONDA_TOKEN)"; exit 1; \
	fi
	@for PKG in $$(find build_artifacts -name "*.conda" ! -path "*/pkg_cache/*" 2>/dev/null); do \
	    conda-verify $$PKG && \
	    anaconda -t $$(cat $(ANACONDA_TOKEN)) upload --force $$PKG --label hep-forge; \
	done

debug:
	@OUTPUT_ID=$$(conda render . --output 2>&1 \
	    | grep -E '\.(tar\.bz2|conda)$$' | sort | tail -1 | xargs -r basename); \
	if [ -n "$$OUTPUT_ID" ]; then \
	    conda debug . --output-id "$$OUTPUT_ID"; \
	else \
	    conda debug .; \
	fi

endif
