.PHONY: sanity-test compile-check pod-gate pod-check pod-check-syntax pod-check-quiet test test-quick test-fail-fast test-secrets test-ci unit-tests integration-tests e2e-tests test-all test-manifest release dev-release clean coverage pod-validate-ai pod-validate-changed test-deps test-deps-coverage install-secrets-engine test-changed test-failed test-progress

# Test manifest-based execution
TEST_MANIFEST ?= t/test-manifest.txt
TESTS ?= t/*/*.t

# Unit tests run side by side, one per processor unless told otherwise, and
# integration and e2e tests side by side too, on at most eight, the most they
# have been proved at.  An e2e file works in its own copy of the fixture
# repository it uses (helper's fixture_repo), not in t/repos itself.
# getconf answers on macOS and Linux alike.
TEST_JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
INTEGRATION_JOBS ?= $(shell n=$(TEST_JOBS); [ $$n -gt 8 ] && n=8; echo $$n)

# Every tier reads stdin from /dev/null, so a run started from a background
# shell or CI behaves as one started in a terminal: fake_tty's script call
# cannot query a socket, and a kit hook that prompts would wait on one.
TEST_STDIN = < /dev/null

# A full run records which files under lib/ and t/ each test, and every
# genesis it ran, really loaded (see t/Harness/Deps.pod), so make
# test-changed can choose the tests a change reaches.
TEST_DEPS = GENESIS_TEST_DEPS=$(CURDIR)/t/.test-deps.new PERL5OPT="-I$(CURDIR)/t -MHarness::Deps $$PERL5OPT"

# A full run's output also goes to this log, which make test-progress reads.
# Each tier runs under bash with pipefail, so the tee never hides prove's
# own exit status.
TEST_LOG = t/tmp/last-run.log
LOGGED = bash -o pipefail -c '"$$@" 2>&1 | tee -a $(TEST_LOG)' --

# Coverage report format (html, json, text)
COVERAGE_REPORT_FORMAT ?= html

compile-check:
	@echo "Checking all Perl modules compile..."
	@failed=0; \
	for pm in $$(find lib -name '*.pm'); do \
		if ! perl -Ilib -c "$$pm" >/dev/null 2>&1; then \
			echo "FAILED: $$pm"; \
			perl -Ilib -c "$$pm"; \
			failed=$$((failed+1)); \
		fi; \
	done; \
	if [ $$failed -eq 0 ]; then \
		echo "All modules compile successfully"; \
	else \
		echo "$$failed module(s) failed to compile"; \
		exit 1; \
	fi

# The gate that t/sanity-tests/pod-complete.t runs, with a readable report.
# Takes module names or paths; no arguments checks everything.
pod-gate:
	@t/bin/pod-gate $(MODULES)

pod-check:
	@echo "Checking POD coverage for all modules..."
	@t/bin/pod-coverage-check

pod-check-syntax:
	@echo "Checking POD coverage and syntax for all modules..."
	@t/bin/pod-coverage-check --syntax

pod-check-quiet:
	@echo "Checking POD coverage (summary only)..."
	@t/bin/pod-coverage-check --quiet

sanity-test: compile-check
	@bash -c 'set -o pipefail; export GENESIS_OUTPUT_COLUMNS=120; perl -Ilib -c bin/genesis && perl -Ilib -- bin/genesis -D ping 2>&1'

coverage:
	SKIP_SECRETS_TESTS=yes cover -t -ignore_re '(/Legacy.pm|/JSON/|/UUID/|^t/.*\.pm)' -report $(COVERAGE_REPORT_FORMAT)

test: sanity-test
	@echo "Running all tests from manifest..."
	@t/bin/test-state begin
	@rm -rf t/.test-deps.new t/tmp/fixture-cache
	@mkdir -p t/tmp && : > $(TEST_LOG)
	@$(TEST_DEPS) $(LOGGED) t/bin/prove-tier sanity-tests 1 -lf --timer $(shell t/bin/parse-manifest $(TEST_MANIFEST) sanity-tests) $(TEST_STDIN)
	@$(TEST_DEPS) $(LOGGED) t/bin/prove-tier unit-tests $(TEST_JOBS) -lf --timer $(shell t/bin/parse-manifest $(TEST_MANIFEST) unit-tests) $(TEST_STDIN)
	@$(TEST_DEPS) $(LOGGED) t/bin/prove-tier integration-tests $(INTEGRATION_JOBS) -lf --timer $(shell t/bin/parse-manifest $(TEST_MANIFEST) integration-tests) $(TEST_STDIN)
	@$(TEST_DEPS) $(LOGGED) t/bin/prove-tier e2e-tests $(INTEGRATION_JOBS) -lf --timer $(shell t/bin/parse-manifest $(TEST_MANIFEST) e2e-tests) $(TEST_STDIN)
	@sort -u t/.test-deps.new > t/.test-deps && rm -f t/.test-deps.new
	@t/bin/test-state commit

# Run only the tests a change reaches, by tier, from the record the last full
# run left (see t/bin/affected-tests).  The change is what is uncommitted, or
# everything since BASE:
#   make test-changed
#   make test-changed BASE=v3.2.x-dev
# A test file never recorded, or a change outside lib/ and the tests, runs as
# if everything were reached.  This is the loop while working; make test
# stays the gate before a push.
test-changed:
	@t/bin/test-changed $(or $(BASE),HEAD) $(TEST_JOBS)

# How far the running (or last) make test has got, refreshed every EVERY
# seconds until it ends; it only reads the run's log, so it costs the run
# nothing.  Run it in a second terminal:
#   make test-progress
#   make test-progress EVERY=30
test-progress:
	@t/bin/test-progress -w $(or $(EVERY),15) -j $(TEST_JOBS) $(TEST_LOG)

# Run again only the test files that failed in the last run of any tier,
# each tier as make test runs it.
test-failed:
	@t/bin/prove-tier --failed sanity-tests 1 -l $(TEST_STDIN)
	@t/bin/prove-tier --failed unit-tests $(TEST_JOBS) -l $(TEST_STDIN)
	@t/bin/prove-tier --failed integration-tests $(INTEGRATION_JOBS) -l $(TEST_STDIN)
	@t/bin/prove-tier --failed e2e-tests $(INTEGRATION_JOBS) -l $(TEST_STDIN)

# Point git at the tracked hooks.  Hooks live in .git/hooks by default,
# which is neither tracked nor cloned, so this is what makes them apply
# to anyone but their author.  Worktrees share the common git directory,
# so one invocation covers all of them.
hooks:
	@git config core.hooksPath .githooks
	@echo "core.hooksPath -> .githooks"
	@echo "pre-push now requires a passing 'make test' for the current tree."
	@echo "Bypass an individual push with: git push --no-verify"

test-all: sanity-test unit-tests integration-tests e2e-tests

# Terminate a test run and the children it leaves behind -- fake BOSH
# directors are Test::TCP forks and vault servers are backgrounded, so
# neither dies with the runner.  DRY_RUN=1 lists without terminating.
end-testing:
	@t/bin/end-testing

unit-tests: sanity-test
	@echo "Running unit tests (library/module level)..."
	@SKIP_SECRETS_TESTS=yes prove -l -j$(TEST_JOBS) $(shell t/bin/parse-manifest $(TEST_MANIFEST) unit-tests) $(TEST_STDIN)

integration-tests: sanity-test
	@echo "Running integration tests (multi-component)..."
	@prove -l -j$(INTEGRATION_JOBS) $(shell t/bin/parse-manifest $(TEST_MANIFEST) integration-tests) $(TEST_STDIN)

e2e-tests: sanity-test
	@echo "Running e2e tests (full workflows)..."
	@prove -l -j$(INTEGRATION_JOBS) $(shell t/bin/parse-manifest $(TEST_MANIFEST) e2e-tests) $(TEST_STDIN)

test-quick: unit-tests

# Run all manifest tests sequentially, bailing on the first failure.
# Useful when the test ordering matters and you want to debug the
# earliest break without waiting for the rest of the suite.
test-fail-fast: sanity-test
	@echo "Running all tests from manifest (fail-fast)..."
	@for t in $$(t/bin/parse-manifest $(TEST_MANIFEST) sanity-tests unit-tests integration-tests e2e-tests); do \
		echo "+ $$t"; \
		prove -l $$t $(TEST_STDIN) || { echo "STOP: $$t failed; bailing per fail-fast policy"; exit 1; }; \
	done

test-secrets: sanity-test
	@echo 'Running secrets e2e test...'
	@prove -l t/e2e-tests/secrets.t $(TEST_STDIN)

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

# AI-powered POD documentation validation
# Requires: uv, claude CLI
#
# Usage:
#   make pod-validate-ai                    # Validate all POD modules
#   make pod-validate-ai MODULES="Genesis::Kit Genesis::Env"
#   make pod-validate-changed               # Validate changed files only
#   make pod-validate-changed BASE=main     # Compare to specific branch
pod-validate-ai:
ifdef MODULES
	@t/bin/pod-validate-ai $(MODULES)
else
	@t/bin/pod-validate-ai --all
endif

pod-validate-changed:
	@t/bin/pod-validate-ai --changed --base $(or $(BASE),main)

# Install a secrets engine for the test suite to run, into t/engines.  Tests
# never download one; they name this target when the engine they ask for is
# missing.
#   make install-secrets-engine ENGINE=vault VERSION=1.14.4
#   make install-secrets-engine ENGINE=bao VERSION=2.7.0
install-secrets-engine:
	@t/bin/install-secrets-engine $(ENGINE) $(VERSION)

# Install test dependencies via Homebrew and cpanm
test-deps:
	@command -v brew >/dev/null 2>&1 || { \
		echo >&2 "Error: Homebrew is required but not installed."; \
		echo >&2 "Install it from https://brew.sh"; \
		exit 1; \
	}
	brew install shellcheck perl cpanminus
	cpanm -n Carp::Always Expect PadWalker PPI \
		Test::Deep Test::Differences Test::Exception \
		Test::Exit Test::Output Test::TCP

# Install optional coverage dependencies (requires test-deps)
test-deps-coverage: test-deps
	cpanm -n Devel::Cover Template PPI::HTML Pod::Coverage::CountParents
