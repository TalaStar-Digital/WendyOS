.DEFAULT_GOAL := help

SWIFT_FORMAT_TARGETS := WendyAgentCore/Sources WendyAgentCore/Tests WendyAgentMac/Sources WendyE2ETests/Sources WendyE2ETests/Tests

ifeq ($(OS),Windows_NT)
override SHELL := powershell.exe
.SHELLFLAGS := -NoProfile -ExecutionPolicy Bypass -Command
LOCAL_E2E_RUN_ID = windows-to-raspberry-pi-5
LOCAL_E2E_ARGS = --output-dir Build/e2e --agent-os wendyOS --agent-address "$(DEVICE)"
PRINT_HELP = @if (-not $$PSVersionTable) { throw 'Windows make recipes require PowerShell.' }; Write-Output 'Usage:'; Write-Output '  make <target>'; Write-Output ''; Write-Output 'Targets:'; Select-String -Path '$(firstword $(MAKEFILE_LIST))' -Pattern '^[a-zA-Z0-9_-]+:.*?\#\# ' | ForEach-Object { $$parts = $$_.Line -split ':.*?\#\# ', 2; '  {0,-24} {1}' -f $$parts[0], $$parts[1] }
RUN_E2E_TEST = @if (-not $$PSVersionTable) { throw 'Windows E2E targets require PowerShell.' }; ./Scripts/E2ETest.ps1 --default-run-id "$(1)" $(3)
RUN_E2E_RUN = @if (-not $$PSVersionTable) { throw 'Windows E2E targets require PowerShell.' }; ./Scripts/E2ERun.ps1 --default-run-id "$(1)" $(3)
else
SHELL := /bin/bash
LOCAL_E2E_RUN_ID = local
LOCAL_E2E_ARGS = --output-dir Build/e2e --cli-root-dir Build/e2e --agent-root-dir Build/e2e --parallel
PRINT_HELP = @echo 'Usage:'; echo '  make <target>'; echo ''; echo 'Targets:'; grep -E '^[a-zA-Z0-9_-]+:.*?\#\# .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?\#\# "}; {printf "  %-24s %s\n", $$1, $$2}'

OPEN_E2E_REPORT = report_path="$(1)"; if [ -f "$$report_path" ]; then if [ "$$(uname -s)" = "Darwin" ]; then open "$$report_path" || echo "HTML report: $$report_path"; else echo "HTML report: $$report_path"; fi; else echo "HTML report not found: $$report_path"; fi

RUN_E2E_TEST = @run_id="$${WENDY_E2E_RUN_ID:-$(1)}"; \
	WENDY_E2E_RUN_ID="$$run_id" $(2) bash ./Scripts/E2ETest.sh $(3)

RUN_E2E_RUN = @run_id="$${WENDY_E2E_RUN_ID:-$(1)}"; \
	status=0; \
	WENDY_E2E_RUN_ID="$$run_id" $(2) bash ./Scripts/E2ETest.sh $(3) || status=$$?; \
	bash ./Scripts/E2EReview.sh --run-dir "Build/e2e/$$run_id" || { step_status=$$?; [ $$status -eq 0 ] && status=$$step_status; }; \
	bash ./Scripts/E2EReport.sh --run-dir "Build/e2e/$$run_id" || { step_status=$$?; [ $$status -eq 0 ] && status=$$step_status; }; \
	$(call OPEN_E2E_REPORT,Build/e2e/$$run_id/report.html); \
	exit $$status
endif

.PHONY: help format lint test e2e-test e2e-run e2e-test-jetson-orin-nano e2e-run-jetson-orin-nano e2e-test-raspberry-pi-5 e2e-run-raspberry-pi-5 e2e-test-mac-mini e2e-run-mac-mini reference proto agent-release build-cli agent-build agent-start agent-reset-settings agent-reset-permissions agent-reset agent-stop clean

help: ## Show this help message
	$(PRINT_HELP)

format: ## Format Swift code using swift-format
	swift format --recursive --in-place $(SWIFT_FORMAT_TARGETS)

lint: ## Lint Swift code using swift-format
	bash ./Scripts/Lint.sh

test: ## Run Swift package tests
	bash ./Scripts/Test.sh

e2e-test e2e-run: DEVICE ?= wendyos-raspberry-pi-5.local
e2e-test: ## Run Swift E2E tests locally and write raw artifacts
	$(call RUN_E2E_TEST,$(LOCAL_E2E_RUN_ID),,$(LOCAL_E2E_ARGS))

e2e-run: ## Run Swift E2E tests locally, review results, render the report, and open it
	$(call RUN_E2E_RUN,$(LOCAL_E2E_RUN_ID),,$(LOCAL_E2E_ARGS))

e2e-test-jetson-orin-nano e2e-run-jetson-orin-nano: DEVICE ?= wendyos-jetson-orin-nano.local
e2e-test-jetson-orin-nano: ## Run Swift E2E tests against Jetson Orin Nano and write raw artifacts
	$(call RUN_E2E_TEST,jetson-orin-nano,,--output-dir Build/e2e --agent-os wendyOS --agent-address "$(DEVICE)")

e2e-run-jetson-orin-nano: ## Run Swift E2E tests against Jetson Orin Nano, review results, render the report, and open it
	$(call RUN_E2E_RUN,jetson-orin-nano,,--output-dir Build/e2e --agent-os wendyOS --agent-address "$(DEVICE)")

e2e-test-raspberry-pi-5 e2e-run-raspberry-pi-5: DEVICE ?= wendyos-raspberry-pi-5.local
e2e-test-raspberry-pi-5: ## Run Swift E2E tests against Raspberry Pi 5 and write raw artifacts
	$(call RUN_E2E_TEST,raspberry-pi-5,,--output-dir Build/e2e --agent-os wendyOS --agent-address "$(DEVICE)")

e2e-run-raspberry-pi-5: ## Run Swift E2E tests against Raspberry Pi 5, review results, render the report, and open it
	$(call RUN_E2E_RUN,raspberry-pi-5,,--output-dir Build/e2e --agent-os wendyOS --agent-address "$(DEVICE)")

e2e-test-mac-mini e2e-run-mac-mini: DEVICE ?= mac-mini.local
e2e-test-mac-mini: ## Run Swift E2E tests against Mac mini and write raw artifacts
	$(call RUN_E2E_TEST,mac-mini,,--output-dir Build/e2e --agent-os macOS --agent-address "$(DEVICE)")

e2e-run-mac-mini: ## Run Swift E2E tests against Mac mini, review results, render the report, and open it
	$(call RUN_E2E_RUN,mac-mini,,--output-dir Build/e2e --agent-os macOS --agent-address "$(DEVICE)")

reference: ## Generate Swift E2E HTML reference documentation and open it
	rm -rf Build/Reference
	mkdir -p Build/Reference
	cd WendyE2ETests && swift run swift-e2e-testing reference --format html --output ../Build/Reference Tests/WendyE2ETests
	open Build/Reference/index.html

proto: ## Generate Swift gRPC code from Proto/
	./Scripts/GenerateProto.sh

clean: ## Remove Build/
	rm -rf Build/

agent-release: ## Build, sign, notarize, and package the macOS app
	VERSION='$(VERSION)' OUTPUT_DIR='$(OUTPUT_DIR)' bash ./Scripts/Build.sh

build-cli: ## Build the Go CLI in ../go
	$(MAKE) -C ../go build-cli

agent-build: ## Build and package a dev-signed macOS app without notarization
	OUTPUT_DIR='$(OUTPUT_DIR)' bash ./Scripts/Build.sh --dev

agent-start: ## Stop, build, and open the WendyAgentMac app
	@$(MAKE) agent-stop
	@$(MAKE) agent-build
	open Build/WendyAgentMac.app

agent-reset-settings: ## Reset WendyAgentMac preferences/defaults
	./Scripts/ResetMacAppSettings.sh

agent-reset-permissions: ## Reset WendyAgentMac permissions
	./Scripts/ResetMacAppTCC.sh

agent-reset: agent-reset-settings agent-reset-permissions ## Reset WendyAgentMac settings and permissions

agent-stop: ## Quit WendyAgentMac and fail if it is still running after 10 seconds
	./Scripts/Quit.sh
