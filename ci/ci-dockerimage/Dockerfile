FROM registry.ops.scalecf.net/genesis-community/genesis:latest

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get install -y \
      libexpect-perl \
      expect \
      libcarp-always-perl \
      libpadwalker-perl \
      libtest-deep-perl \
      libtest-differences-perl \
      libtest-exit-perl \
      libtest-exception-perl \
      libtest-output-perl \
      libtest-tcp-perl \
      libppi-perl \
      iputils-ping \
 && curl -Lo shellcheck.tar.xz "https://github.com/koalaman/shellcheck/releases/download/v0.7.2/shellcheck-v0.7.2.linux.x86_64.tar.xz" \
     && tar -xf shellcheck.tar.xz \
     && mv shellcheck*/shellcheck /usr/bin/shellcheck \
     && chmod 0755 /usr/bin/shellcheck \
     && rm -rf shellcheck* \
 && git config --global user.name "Genesis CI Bot" \
 && git config --global user.email genesis-ci@rubidiumstudios.com

# t/sanity-tests/pod-complete.t parses every module with PPI, and fails
# rather than skips when it is missing -- a gate that switches itself off
# when a dependency is absent reports success on the run that most needs
# to fail.  Checked here so a packaging change surfaces at image build
# rather than as a confusing red suite.
RUN perl -MPPI -e 'print "PPI ", PPI->VERSION, " loaded OK\n"'
