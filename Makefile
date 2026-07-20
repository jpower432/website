# Makefile for the Gemara website (gemara.openssf.org)
#
# The site content lives at the repository root. Schema reference pages,
# the definitions table, and term cross-links are GENERATED from the Gemara
# specification repo (github.com/gemaraproj/gemara), which provides both the
# CUE schemas and the `gemara-docs` CLI under cmd/.
#
# GEMARA_DIR points at a checkout of the spec repo. By default it is a
# shallow clone under .gemara-spec/ at GEMARA_REF; set GEMARA_DIR=../gemara
# to build against a local sibling checkout instead.

GEMARA_REPO ?= https://github.com/gemaraproj/gemara
GEMARA_REF  ?= main
GEMARA_DIR  ?= .gemara-spec

SPEC_ABS      := $(abspath $(GEMARA_DIR))
SITE_ABS      := $(abspath .)
GENERATED_DIR := generated
OPENAPI_YAML  := $(GENERATED_DIR)/openapi.yaml
MANIFEST_JSON := $(GENERATED_DIR)/schema-manifest.json
SPEC_MD_DIR   := $(GENERATED_DIR)/spec
SCHEMA_DIR    := schema
SCHEMA_NAV    := schema-nav.yml

.PHONY: all fetch-spec genopenapi genmd gendocs serve build test-links cleanup cleanup-links check-jekyll deps

all: gendocs test-links cleanup

deps:
	@echo "  >  Running bundle install..."
	@bundle install

check-jekyll:
	@if ! bundle exec jekyll -v >/dev/null 2>&1; then \
		echo "ERROR: Jekyll not available. Install dependencies: make deps"; \
		exit 1; \
	fi

fetch-spec:
	@if [ ! -d "$(GEMARA_DIR)" ]; then \
		echo "  >  Cloning Gemara spec ($(GEMARA_REF)) into $(GEMARA_DIR)..."; \
		git clone --depth 1 --branch "$(GEMARA_REF)" "$(GEMARA_REPO)" "$(GEMARA_DIR)"; \
	else \
		echo "  >  Using existing spec checkout at $(GEMARA_DIR)"; \
	fi

genopenapi: fetch-spec
	@echo "  >  Converting CUE schema to OpenAPI ..."
	@mkdir -p $(GENERATED_DIR)
	@cd $(SPEC_ABS)/cmd && go run . cue2openapi \
		--schema $(SPEC_ABS) \
		--output $(SITE_ABS)/$(OPENAPI_YAML) \
		--manifest $(SITE_ABS)/$(MANIFEST_JSON)
	@echo "  >  OpenAPI schema generation complete!"

genmd: genopenapi
	@echo "  >  Generating markdown from OpenAPI ..."
	@mkdir -p $(SPEC_MD_DIR)
	@cd $(SPEC_ABS)/cmd && go run . openapi2md \
		--input $(SITE_ABS)/$(OPENAPI_YAML) \
		--output $(SITE_ABS)/$(SPEC_MD_DIR) \
		--nav $(SITE_ABS)/$(SCHEMA_NAV)
	@echo "  >  Markdown generation complete!"

gendocs: genmd
	@echo "  >  Copying schema pages to $(SCHEMA_DIR)/ for website ..."
	@mkdir -p $(SCHEMA_DIR)
	@sh "$(SPEC_ABS)/cmd/scripts/parse-nav.sh" "$(SCHEMA_NAV)" list-pages | while IFS='|' read -r filename title; do \
		if [ -f "$(SPEC_MD_DIR)/$$filename.md" ]; then \
			{ \
				echo "---"; \
				echo "layout: page"; \
				echo "title: $$title"; \
				echo "---"; \
				echo ""; \
				cat "$(SPEC_MD_DIR)/$$filename.md"; \
			} > "$(SCHEMA_DIR)/$$filename.md"; \
		fi; \
	done
	@echo "  >  Updating schema list in $(SCHEMA_DIR)/index.md ..."
	@if [ -f "$(SCHEMA_DIR)/index.md" ]; then \
		schema_list_file="$(SCHEMA_DIR)/index.md.schema_list.tmp"; \
		sh "$(SPEC_ABS)/cmd/scripts/parse-nav.sh" "$(SCHEMA_NAV)" list-pages | while IFS='|' read -r filename title; do \
			[ -f "$(SCHEMA_DIR)/$$filename.md" ] && echo "- [$$title]($$filename.html)"; \
		done > "$$schema_list_file"; \
		awk -v list_file="$$schema_list_file" ' \
			BEGIN { \
				while ((getline line < list_file) > 0) { \
					schema_list = schema_list line "\n"; \
				} \
				close(list_file); \
			} \
			/<!-- SCHEMA_LIST_START -->/ { \
				print; \
				print ""; \
				printf "%s", schema_list; \
				print ""; \
				skip=1; \
				next \
			} \
			/<!-- SCHEMA_LIST_END -->/ { print; skip=0; next } \
			skip==0 { print } \
		' "$(SCHEMA_DIR)/index.md" > "$(SCHEMA_DIR)/index.md.tmp" && \
		rm -f "$$schema_list_file" && \
		mv "$(SCHEMA_DIR)/index.md.tmp" "$(SCHEMA_DIR)/index.md"; \
	fi
	@echo "  >  Generating definitions table from lexicon ..."
	@if [ -f "model/02-definitions.md.template" ]; then \
		cp "model/02-definitions.md.template" "model/02-definitions.md"; \
	fi
	@cd $(SPEC_ABS)/cmd && go run . lexicon2md \
		--lexicon $(SITE_ABS)/lexicon.yaml \
		--output $(SITE_ABS)/model/02-definitions.md
	@echo "  >  Linking defined terms across documentation ..."
	@cd $(SPEC_ABS)/cmd && go run . termlinker \
		--lexicon $(SITE_ABS)/lexicon.yaml \
		--docs $(SITE_ABS)
	@echo "  >  Documentation generation complete!"

serve: check-jekyll gendocs
	@echo "  >  Starting Jekyll documentation site..."
	@bundle exec jekyll serve --host 0.0.0.0 --livereload

build: check-jekyll gendocs
	@echo "  >  Building Jekyll documentation site..."
	@bundle exec jekyll build

test-links:
	@echo "  >  Validating all site pages and links with html-proofer..."
	@bundle exec htmlproofer _site \
		--allow-hash-href \
		--disable-external \
		--ignore-empty-alt \
		--only-4xx \
		--ignore-files '/model\/02-definitions\.html/' \
		--root-dir "$$(pwd)/_site"

cleanup-links:
	@echo "  >  Removing termlinker-generated links from documentation ..."
	@cd $(SPEC_ABS)/cmd && go run . termlinker \
		--lexicon $(SITE_ABS)/lexicon.yaml \
		--docs $(SITE_ABS) \
		--cleanup
	@echo "  >  Link cleanup complete!"

cleanup: cleanup-links
	@echo "  >  Removing generated documentation files and links..."
	@sh "$(SPEC_ABS)/cmd/scripts/parse-nav.sh" "$(SCHEMA_NAV)" list-pages | while IFS='|' read -r filename title; do \
		rm -f "$(SCHEMA_DIR)/$$filename.md"; \
	done
	@rm -f model/02-definitions.md
	@git checkout -- $(SCHEMA_DIR)/index.md 2>/dev/null || true
	@rm -rf $(GENERATED_DIR) _site .jekyll-cache .jekyll-metadata
	@echo "  >  Cleanup complete!"
