# =============================================================================
# CI entrypoint.
# =============================================================================
#   make ci          everything the GitHub workflow runs, in the same order,
#                    with the same pinned tools. This is the one command.
#   make ci-fast     the same minus the kind cluster (seconds, not minutes).
#   make tools       fetch the pinned helm / promtool / kind into ~/.cache
#
# Individual stages, for iterating on one thing:
#   make render negative promtool shell-syntax pvc-retention runtime-templates duplicate-names
#   make greenfield
#
# THE STAGES ARE ORDERED, NOT INDEPENDENT. `render` writes every rendered
# manifest to $(CI_RENDER_DIR), and pvc-retention, runtime-templates and
# promtool's third pass assert against those files rather than re-rendering.
# That is deliberate: a check that re-renders with its own values is checking
# something other than what CI proved renders. The stage targets below depend
# on `render` so running one by hand cannot silently assert against a stale or
# missing render.
#
# `ci` DOES NOT STOP AT THE FIRST FAILING STAGE. A run that stops at the first
# failure hides the other five, and these checks are cheap. Every stage runs,
# then the aggregate result is reported and the exit code is set from it.
#
# GNU make. Recipes are bash because the stage loop uses arrays.
# =============================================================================
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := ci

# Where the check scripts put values, renders and downloaded tools. Exported so
# a stage invoked on its own agrees with one invoked from `ci`. Kept OUTSIDE
# the repository: build artefacts inside the tree are one `git add -A` away
# from being committed.
# Keyed to THIS checkout so two copies of the repo can run CI at the same time
# without destroying each other's renders. Must stay byte-identical to the
# fallback in scripts/ci/lib.sh, or a stage invoked directly would look in a
# different directory from one invoked through make. See the long note there.
export CI_WORK_DIR ?= $(if $(TMPDIR),$(TMPDIR),/tmp)/ais-edge-ci-$(shell printf '%s' '$(CURDIR)' | cksum | cut -d' ' -f1)
export CI_TOOL_DIR ?= $(HOME)/.cache/ais-edge-ci/bin

# The stages that need no cluster and no docker. THE ORDER IS LOAD-BEARING:
# `render` is first because the three stages that read $(CI_RENDER_DIR) are
# after it.
FAST_STAGES := render negative promtool shell-syntax lua-syntax fingerprint-contract shared-files cli-contract pvc-retention runtime-templates duplicate-names reclaimer secret-contract values-consumers stanford
ALL_STAGES  := $(FAST_STAGES) loki-rules data-policy greenfield

# Prerequisite that makes `make promtool` on its own render first. run-stages
# clears it, because it has already run `render` as a stage and each stage is
# a separate `make` process — without this, render (the slowest stage, ~40
# helm invocations over two charts and five subcharts) would run four times
# per `make ci` instead of once.
RENDER_DEP := render

.PHONY: ci ci-fast tools tools-all clean help verify-live $(ALL_STAGES)

# -----------------------------------------------------------------------------
ci: tools-all
	@$(MAKE) --no-print-directory run-stages STAGES="$(ALL_STAGES)"

ci-fast: tools
	@$(MAKE) --no-print-directory run-stages STAGES="$(FAST_STAGES)"

# The aggregate runner. Each stage is a separate process so one stage's
# `set -e` cannot end the run, and its exit code is recorded rather than
# propagated immediately.
.PHONY: run-stages
run-stages:
	@failed=(); \
	for stage in $(STAGES); do \
	  printf '\n\033[1m##### %s\033[0m\n' "$$stage"; \
	  $(MAKE) --no-print-directory "$$stage" RENDER_DEP= || failed+=("$$stage"); \
	done; \
	printf '\n\033[1m##### result\033[0m\n'; \
	if [ $${#failed[@]} -eq 0 ]; then \
	  printf '  all stages passed: %s\n' "$(STAGES)"; \
	else \
	  printf '  FAILED STAGES: %s\n' "$${failed[*]}"; \
	  printf '  (scroll up: each stage prints its own failures by name)\n'; \
	  exit 1; \
	fi

# -----------------------------------------------------------------------------
# Tools, at the versions pinned in scripts/ci/lib.sh with a sha256 on the bytes.
tools:
	@scripts/ci/tools.sh

# kind as well. Only the greenfield stage needs it, and that stage skips
# loudly when docker is unavailable — but fetching it is cheap and a developer
# who has docker should get the full suite from `make ci` without a second
# command.
tools-all:
	@scripts/ci/tools.sh kind

# -----------------------------------------------------------------------------
# Stages.
render:
	@scripts/ci/render.sh

negative:
	@scripts/ci/negative.sh

# See the header: these read $(CI_RENDER_DIR), so they cannot be run against
# nothing. Depending on `render` is what makes `make pvc-retention` on its own
# mean the same thing as the stage inside `make ci`.
promtool: $(RENDER_DEP)
	@scripts/ci/promtool.sh

pvc-retention: $(RENDER_DEP)
	@scripts/ci/pvc-retention.sh

reclaimer:
	@tests/reclaimer/run-tests.sh

# Needs docker: runs the PINNED Loki version and evaluates the real rule
# expressions against fixture logs. promtool covers only the Prometheus rules,
# so without this the Loki rules have no test at all. Skips loudly without
# docker; CI_REQUIRE_LOKI_TESTS=1 turns that skip into a failure.
loki-rules:
	@tests/loki-rules/run-tests.sh

# Needs docker: runs the REAL engine under the REAL busybox image the chart
# deploys, over real directory trees, and asserts on WHAT SURVIVED rather than
# on log text. This is the component that deletes patient-derived data.
data-policy:
	@tests/data-policy/run-tests.sh

duplicate-names: $(RENDER_DEP)
	@scripts/ci/duplicate-names.sh

runtime-templates: $(RENDER_DEP)
	@scripts/ci/runtime-templates.sh

# The only stage that needs no render.
shell-syntax:
	@scripts/ci/shell-syntax.sh

lua-syntax:
	@bash scripts/ci/lua-syntax.sh

fingerprint-contract:
	@bash scripts/ci/fingerprint-contract.sh

shared-files:
	@bash scripts/ci/shared-files.sh

cli-contract:
	@bash scripts/ci/cli-contract.sh

# Renders both charts itself (with the EXAMPLE site values, which is the point)
# so it does not read $(CI_RENDER_DIR) and has no render dependency.
secret-contract:
	@scripts/ci/secret-namespaces.sh

# Reads values.yaml and greps the templates; no render, no cluster. Catches a
# values key that declares operator policy with nothing implementing it — Helm
# itself never warns about an unread value.
values-consumers:
	@scripts/ci/values-consumers.sh

# Needs docker + kubectl + kind. Skips, loudly, if any is missing — a skip is
# reported separately from a pass so a run without docker never reads as
# "the charts are installable". CI_REQUIRE_GREENFIELD=1 turns that skip into a
# failure, which is what the GitHub workflow sets.
greenfield:
	@scripts/ci/greenfield-kind.sh

# -----------------------------------------------------------------------------
# LIVE checks, not CI. Everything above this line reads the repository and needs
# no cluster; this reads the RUNNING deployment and changes nothing in it.
#   make verify-live SITE=<site>
verify-live:
	@test -n "$(SITE)" || { echo "usage: make verify-live SITE=<site-name>"; \
	  echo "  sites available:"; ls -1 sites/ | sed 's/^/    /'; exit 2; }
	@scripts/verify-live.sh "$(SITE)"

# -----------------------------------------------------------------------------
clean:
	@rm -rf "$(CI_WORK_DIR)"
	@echo "removed $(CI_WORK_DIR) (tools in $(CI_TOOL_DIR) are kept)"

help:
	@echo 'make ci          full suite, pinned tools, incl. the kind greenfield install'
	@echo 'make ci-fast     everything except the kind stage'
	@echo 'make tools       fetch pinned helm + promtool'
	@echo 'make tools-all   additionally fetch pinned kind'
	@echo 'make clean       remove $(CI_WORK_DIR)'
	@echo
	@echo 'make verify-live SITE=<site>   check the RUNNING deployment (read-only)'
	@echo
	@echo 'stages: $(ALL_STAGES)'
	@echo
	@echo 'useful env:'
	@echo '  CI_REQUIRE_GREENFIELD=1  a skipped kind stage is a failure'
	@echo '  CI_REQUIRE_LOKI_TESTS=1  a skipped Loki-rule stage is a failure'
	@echo '  CI_REQUIRE_DATAPOLICY_TESTS=1  a skipped data-policy stage is a failure'
	@echo '  CI_REQUIRE_RULE_TESTS=1  a rule file with no promtool test is a failure'
	@echo '  CI_KIND_KEEP=1           leave the kind cluster up for inspection'

stanford:
	@tests/stanford/run-tests.sh
