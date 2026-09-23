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
