SHELL := /bin/sh
.DEFAULT_GOAL := help

# Override as needed, e.g. make deploy PIO=./venv/bin/pio CHANNEL=stable VERSION=v1.2.3
PIO ?= pio
NPM ?= npm
PYTHON ?= python3
CHANNEL ?= dev
VERSION ?= dev-$(shell git rev-parse --short HEAD 2>/dev/null || printf local)
DATE ?= $(shell date -u +%Y-%m-%d)
URL ?=
BUILD_DIR ?= .build
PLATFORMIO_ENVS := devkitv1_e22 heltec_v3 HTIT-WB32LAF tbeam lilygo_t3_v161 tbeam_supreme_433

ifeq ($(CHANNEL),stable)
CHANNEL_SUBDIR :=
else ifeq ($(CHANNEL),dev)
CHANNEL_SUBDIR := dev/
else
$(error CHANNEL must be 'dev' or 'stable')
endif

FIRMWARE_ROOT := website/public/firmware
FIRMWARE_OUTPUT := $(FIRMWARE_ROOT)/$(CHANNEL_SUBDIR)
ARTIFACTS_DIR := $(BUILD_DIR)/artifacts
SITE_DIST := website/.vitepress/dist

.PHONY: help firmware site build deploy

help: ## Show available targets
	@printf '%s\n' \
	  'make firmware  Build all supported device images and manifests into website/public/firmware' \
	  'make site      Build the VitePress website' \
	  'make build     Build firmware images, manifests, index, then the website' \
	  'make deploy    Build everything and publish to origin/gh-pages (no force push)' \
	  '' \
	  'Options: CHANNEL=dev|stable (default: dev), VERSION=..., URL=..., PIO=..., BUILD_DIR=...'

firmware: ## Build firmware images and web-installer manifests for every device
	@command -v "$(PIO)" >/dev/null 2>&1 || { echo "PlatformIO CLI not found: $(PIO) (install with: python3 -m pip install platformio, or set PIO=./venv/bin/pio)" >&2; exit 1; }
	@mkdir -p "$(ARTIFACTS_DIR)" "$(FIRMWARE_OUTPUT)"
	@set -eu; \
	for env in $(PLATFORMIO_ENVS); do \
	  echo "==> Building $$env"; \
	  "$(PIO)" run -e "$$env"; \
	  src=".pio/build/$$env"; \
	  dst="$(ARTIFACTS_DIR)/firmware-$$env"; \
	  test -f "$$src/firmware.bin" || { echo "Missing firmware image: $$src/firmware.bin" >&2; exit 1; }; \
	  rm -rf "$$dst" "$(FIRMWARE_OUTPUT)$$env"; \
	  mkdir -p "$$dst"; \
	  for image in firmware.bin bootloader.bin partitions.bin; do \
	    if test -f "$$src/$$image"; then cp "$$src/$$image" "$$dst/$$image"; fi; \
	  done; \
	done
	@$(PYTHON) scripts/gen_manifest.py --artifacts "$(ARTIFACTS_DIR)" --output "$(FIRMWARE_OUTPUT)" --version "$(VERSION)"
	@$(PYTHON) scripts/update_index.py --index "$(FIRMWARE_ROOT)/index.json" --channel "$(CHANNEL)" --version "$(VERSION)" --date "$(DATE)" --url "$(URL)"

site: ## Build the VitePress site
	@if test ! -x website/node_modules/.bin/vitepress; then \
	  echo 'Installing locked website dependencies (npm ci)...'; \
	  "$(NPM)" ci --prefix website; \
	fi
	@$(NPM) --prefix website run build

build: firmware ## Build firmware and website
	@$(MAKE) --no-print-directory site

deploy: build ## Build everything and push the website and firmware to gh-pages
	@set -eu; \
	test -d "$(SITE_DIST)" || { echo "Website output not found: $(SITE_DIST)" >&2; exit 1; }; \
	tmp_root=$$(mktemp -d "$${TMPDIR:-/tmp}/axloratnc-gh-pages.XXXXXX"); \
	deploy_dir="$$tmp_root/site"; \
	cleanup() { git worktree remove --force "$$deploy_dir" >/dev/null 2>&1 || true; git worktree prune >/dev/null 2>&1 || true; rm -rf "$$tmp_root"; }; \
	trap cleanup EXIT HUP INT TERM; \
	remote_url=$$(git remote get-url origin); \
	if git ls-remote --exit-code origin refs/heads/gh-pages >/dev/null 2>&1; then \
	  git fetch --quiet origin refs/heads/gh-pages; \
	  git worktree add --detach "$$deploy_dir" FETCH_HEAD >/dev/null; \
	else \
	  status=$$?; \
	  test "$$status" -eq 2 || { echo 'Cannot query origin/gh-pages; refusing to initialize a new deployment.' >&2; exit 1; }; \
	  mkdir -p "$$deploy_dir"; \
	  git -C "$$deploy_dir" init -b gh-pages >/dev/null; \
	  git -C "$$deploy_dir" remote add origin "$$remote_url"; \
	fi; \
	find "$$deploy_dir" -mindepth 1 -maxdepth 1 ! -name .git ! -name firmware -exec rm -rf -- {} +; \
	find "$(SITE_DIST)" -mindepth 1 -maxdepth 1 ! -name firmware -exec cp -a -- {} "$$deploy_dir"/ \;; \
	mkdir -p "$$deploy_dir/firmware/$(CHANNEL_SUBDIR)"; \
	for env in $(PLATFORMIO_ENVS); do \
	  src="$(FIRMWARE_OUTPUT)$$env"; \
	  test -f "$$src/manifest.json" || { echo "Missing firmware manifest: $$src/manifest.json" >&2; exit 1; }; \
	  rm -rf "$$deploy_dir/firmware/$(CHANNEL_SUBDIR)$$env"; \
	  cp -a -- "$$src" "$$deploy_dir/firmware/$(CHANNEL_SUBDIR)"; \
	done; \
	$(PYTHON) scripts/update_index.py --index "$$deploy_dir/firmware/index.json" --channel "$(CHANNEL)" --version "$(VERSION)" --date "$(DATE)" --url "$(URL)"; \
	git -C "$$deploy_dir" config user.name "$${GIT_AUTHOR_NAME:-$$(git config user.name || printf 'AXLoRaTNC deploy')}"; \
	git -C "$$deploy_dir" config user.email "$${GIT_AUTHOR_EMAIL:-$$(git config user.email || printf 'deploy@localhost')}"; \
	git -C "$$deploy_dir" add -A; \
	if git -C "$$deploy_dir" diff --cached --quiet; then \
	  echo 'gh-pages is already up to date; no push needed.'; \
	else \
	  git -C "$$deploy_dir" commit -m "deploy: $(CHANNEL) $(VERSION)"; \
	  git -C "$$deploy_dir" push origin HEAD:gh-pages; \
	fi
