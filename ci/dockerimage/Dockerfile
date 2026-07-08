FROM --platform=linux/amd64 ubuntu:jammy
MAINTAINER Dennis J. Bell <dennis.j.bell@gmail.com>

RUN apt-get update \
 && apt-get install -yy wget gnupg \
 && mkdir -p -m 755 /etc/apt/keyrings \
 && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
 && wget -q -O - https://raw.githubusercontent.com/cloudfoundry-community/homebrew-cf/master/public.key | apt-key add - \
 && echo "deb http://apt.community.cloudfoundry.org stable main" | tee /etc/apt/sources.list.d/cloudfoundry-community.list \
 && apt-get update && apt-get install -yy \
    aha \
    autoconf \
    bosh-cli \
    build-essential \
    bzip2 \
    cf-cli \
    cf6-cli \
    credhub-cli \
    curl \
    file \
    git \
    gh \
    gotcha \
    jq \
    libreadline8 \
    libreadline-dev \
    libsqlite3-dev \
    libssl-dev \
    libtool \
    libxml2-dev \
    libxslt-dev \
    lsof \
    om \
    openssl \
    pivnet-cli \
    ruby \
    ruby-dev \
    sipcalc \
    safe \
    spruce \
    sqlite3 \
    vault \
    vim-common \
    unzip \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

ARG GENESIS_VERSION
ARG GENESIS_OWNER=genesis-community

RUN curl -Lo /usr/bin/genesis "https://github.com/${GENESIS_OWNER}/genesis/releases/download/v${GENESIS_VERSION}/genesis" \
     && chmod 0755 /usr/bin/genesis

# Kit::Validator (Perl spec-test framework for Genesis kits) and its
# non-core CPAN test deps.  Runtime deps like Test::More, JSON::PP,
# and File::Temp are already in Ubuntu's perl-base.  Genesis's own
# Perl lib is discovered at runtime under ~/.genesis/lib via the
# self-extract path -- no PERL5LIB gymnastics required.
ARG KIT_VALIDATOR_REF=v0.1.0
RUN apt-get update && apt-get install -y --no-install-recommends cpanminus \
 && cpanm --no-man-pages --notest Test::Deep Test::Output Test::Exit \
 && cpanm --no-man-pages --notest \
      "https://github.com/genesis-community/kit-validator/archive/refs/tags/${KIT_VALIDATOR_REF}.tar.gz" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

RUN genesis -v \
 && perl -MKit::Validator -e 'print "Kit::Validator ", Kit::Validator->VERSION, " loaded OK\n"'
