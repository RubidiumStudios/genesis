While Genesis was designed to be distributed with no Perl dependencies besides
a version of Perl that was released within the last decade, testing it does
require some CPAN modules and further configurations.

Furthermore, testing Genesis also requires the same system dependencies on
spruce, safe, vault, jq, etc that would be required to run in in production:
namely the same things that the jumpbox boshrelease or script uses.

In order to configure for testing do the following:

On OSX:
  * `brew tap starkandwayne/cf`
  * `brew install spruce safe`
  * `brew install cloudfoundry/tap/bosh-cli` 
    # alternatively, add the tap and install bosh-cli
  * `brew install jq`
  * install vault from https://www.vaultproject.io/downloads.html

On Linux (Ubuntu/Debian, Centos/Amazon Linux or OpenSUSE/SUSE Enterprise Linux):
  * Install the jumpbox script:

  ```
  sudo curl -o /usr/local/bin/jumpbox \
  https://raw.githubusercontent.com/starkandwayne/jumpbox/master/bin/jumpbox

  sudo chmod 0755 /usr/local/bin/jumpbox

  jumpbox system

  jumpbox user # optional
  ```

  You may also need to install expect with your OS package manager if its not
  present by default.  For example, on Ubuntu you would issue:
  `sudo apt install expect`

---

CPAN Modules:

You will need the following cpan modules to run tests:

Expect
Test::Exception
Test::Deep
Test::Differences
Test::Output
Test::TCP
Test::Exit
Test::More
PadWalker

```
cpanm -n  Expect Test::Exception Test::Deep Test::Differences Test::Output Test::TCP Test::Exit Test::More PadWalker
```

If you want to run the coverage tests, you will also need the following modules:
Devel::Cover
Template
PPI::HTML (or Perl::Tidy)
Pod::Coverage::CountParents (or Pod::Coverage)

```
cpanm -n Devel::Cover Template PPI::HTML Pod::Coverage::CountParents
```

---

Test tiers:

The manifest sorts every test into a tier, and `make test` runs them in order:
the sanity tier, then the unit tier side by side (`TEST_JOBS`, one per
processor by default), then the integration and e2e tiers one at a time.
Every tier reads stdin from `/dev/null`.

- A **unit** test calls the code under test directly, with record fixtures and
  stubs.  It starts no vault server and no listener, spawns no `bin/genesis`,
  and writes nothing outside its own temporary directory, though a private
  local git repository is allowed.  Unit tests run in parallel, so one that
  breaks these rules races the others.  Some files under `unit-tests/` still
  start a vault or run the CLI; each one's work area keeps them apart for
  now, and they move to the integration tier, or drop the vault, as they
  are reworked.
- An **integration** test uses the harness with the vault and the CLI.
- An **e2e** test is a scenario story: several commands over one setup,
  asserting everything its states show.

While working, run only what a change reaches:

- `make test-changed` runs the tests that uncommitted changes reach, tier by
  tier (`BASE=<ref>` for everything since a ref).  The choice comes from the
  record the last full `make test` left in `t/.test-deps` of which files
  under `lib/` and `t/` each test, and every genesis it ran, really loaded.
  A test never recorded, or a change outside `lib/` and the test files,
  counts as reached.
- `make test-failed` runs again only the files that failed last time.

`make test` stays the gate before a push, and refreshes the record.

Each test process works in `t/tmp/<pid>`, which `helper` sets up as it loads
and removes as the process ends; its HOME, its vaults' pid files and anything
else it writes go there.  A process that dies without ending cleanly leaves
its directory behind, and the next test to start removes it and stops the
vaults it recorded.  Set `GENESIS_TEST_KEEP_TMP=1` to keep the directory
for inspection.

---

Profiling a test file:

To see where a test file's time goes, load `Harness::Profile` through
`PERL5OPT` and name a log in `GENESIS_TEST_PROFILE`, then read the log with
`t/bin/profile-report`.  It logs every command `Genesis::run` spawns, in the
test process and in every genesis child, and each process's own CPU.  See
`t/Harness/Profile.pod`.

```
GENESIS_TEST_PROFILE=/tmp/profile.log \
PERL5OPT="-I$PWD/t -I$PWD/lib -MHarness::Profile" \
  prove -l t/integration-tests/genesis_ci_walk-seed.t < /dev/null
t/bin/profile-report /tmp/profile.log
```
