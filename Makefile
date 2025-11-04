.PHONY: sanity-test test test-quick test-secrets test-ci unit-test integration-test e2e-test test-all test-manifest release dev-release clean coverage

# Test manifest-based execution
TEST_MANIFEST ?= t/test-manifest.txt
TESTS ?= t/*.t

sanity-test:
	@bash -c 'set -o pipefail; export GENESIS_OUTPUT_COLUMNS=120; perl -Ilib -c bin/genesis && perl -Ilib -- bin/genesis -D ping 2>&1'

coverage:
	SKIP_SECRETS_TESTS=yes cover -t -ignore_re '(/Legacy.pm|/JSON/|/UUID/|^t/.*\.pm)'

test: unit-test integration-test e2e-test

unit-test: sanity-test
	@echo "Running unit tests (library/module level)..."
	@SKIP_SECRETS_TESTS=yes prove -l $(shell t/bin/parse-manifest $(TEST_MANIFEST) unit-tests)

integration-test: sanity-test
	@echo "Running integration tests (multi-component)..."
	@prove -l $(shell t/bin/parse-manifest $(TEST_MANIFEST) integration-tests)

e2e-test: sanity-test
	@echo "Running e2e tests (full workflows)..."
	@prove -l $(shell t/bin/parse-manifest $(TEST_MANIFEST) e2e-tests)

test-all: sanity-test unit-test integration-test e2e-test

test-manifest: sanity-test
	@echo "Running all tests from manifest..."
	@prove -lf $(TESTS)

test-quick: unit-test

test-secrets: sanity-test
	@echo 'Running secrets e2e test...'
	@prove -l t/e2e-tests/secrets.t ; rc=$$? ; for pid in $$(ps | grep '[\.]/t/vaults/vault-' | awk '{print $$1}') ; do kill -TERM $$pid; done ; exit $$rc

test-isolated: sanity-test
	@echo "Running all tests in isolation..."
	@for x in $$(awk '/\.t$$/{print "t/"$$1}' $(TEST_MANIFEST)); do \
		echo "Testing $$x..."; \
		git clean -xdf t; \
		prove -lv $$x || exit 1; \
	done

release:
	@if [[ -z $(VERSION) ]]; then echo >&2 "No VERSION specified in environment; try \`make VERSION=2.0 release'"; exit 1; fi
	@echo "Cutting new Genesis release (v$(VERSION))"
	./pack $(VERSION)

shipit:
	rm -rf artifacts
	mkdir -p artifacts
	./pack $(VERSION)
	mv genesis-$(VERSION) artifacts/genesis
	artifacts/genesis -v | grep $(VERSION)

dev-release:
	@echo "Cutting new **DEVELOPER** Genesis release"
	./pack

clean:
	rm -f genesis-*
