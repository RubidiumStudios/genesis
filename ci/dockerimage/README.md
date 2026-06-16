Genesis Docker Image
====================

This directory contains the recipe for the Genesis Docker Image,
a container image that wraps up all of the tools and libraries
necessary for running Genesis deployments. It is intended to be
useful for evaluation of Genesis and running CI/CD pipelines that
do deployments.

Build Arguments
---------------

The Dockerfile accepts two build arguments:

- `GENESIS_VERSION` (required) -- the Genesis release tag to fetch,
  without the leading `v`. Example: `3.2.0-rc.1`.
- `GENESIS_OWNER` (optional, default `genesis-community`) -- the
  GitHub org that owns the Genesis release. Override this when
  building images from a fork or a private dev org. Example:
  `RubidiumStudios`.

The binary is fetched from
`https://github.com/${GENESIS_OWNER}/genesis/releases/download/v${GENESIS_VERSION}/genesis`,
so a corresponding GitHub (pre)release must exist on that org.

Software Installed
------------------

Pinned versions of the in-image tooling drift with Ubuntu jammy
package updates. The current Dockerfile installs the following
from `apt`:

- BOSH CLI (`bosh-cli`)
- CF CLI v7 and v6 (`cf-cli`, `cf6-cli`)
- Credhub CLI (`credhub-cli`)
- GitHub CLI (`gh`)
- `gotcha`
- `jq`
- `om`
- `pivnet-cli`
- `safe`
- `sipcalc`
- `spruce`
- `vault`

Plus build tooling (autoconf, build-essential, ruby/dev,
libxml2/libxslt/libyaml dev libs) for kits and hooks that need
to compile native extensions inside the container.

Genesis itself is downloaded from the GitHub release at image
build time.

Usage
-----

You almost invariably want to run a shell in the docker container,
and use that to execute Genesis:

    docker run -it genesiscommunity/genesis /bin/bash
    $ genesis -v
    ... etc ...

Building Locally
----------------

The `Makefile` wraps `docker build`. With the in-tree `genesis`
binary installed, `TAG` defaults to whatever `genesis version`
reports; otherwise pass it explicitly:

    # build a prerelease image from the dev org
    make build \
      TAG=3.2.0-rc.1 \
      GENESIS_OWNER=RubidiumStudios

    # build a public release image (default owner)
    make build TAG=3.2.0

Happy Hacking!
