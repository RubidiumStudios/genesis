# Getting Started with Genesis CI Pipelines

Genesis automates the deployment of BOSH environments through CI/CD
pipelines. You describe your environments and their relationships in a
configuration file, and Genesis generates the full pipeline definition for
your CI platform. This guide walks through creating your first pipeline
from scratch.

## What a Pipeline Does

A Genesis deployment pipeline watches your Git repository for changes to
environment files. When it detects a change, it deploys the affected
environment, generates a cache of shared configuration for downstream
environments, and triggers the next environment in the chain. Each
environment passes its configuration forward so that downstream
environments can detect what changed.

For example, if you have a sandbox that feeds into staging which feeds into
production, a change to a shared YAML file will deploy sandbox first. If
sandbox succeeds, staging deploys automatically (or waits for manual
approval). Production deploys only after staging succeeds.

## Prerequisites

You need a Genesis deployment repository that has been initialized with
`genesis init`. The repository should have at least one environment file
(like `my-env.yml`) and a configured Vault for secrets storage. If you are
deploying to Concourse, you also need a running Concourse instance and the
`fly` CLI authenticated to a target.

## Writing ci.yml

Create a file called `ci.yml` in the root of your deployment repository.
This is the legacy single-file format and is the simplest way to get
started. Here is a minimal working example:

```yaml
pipeline:
  name: my-bosh-deployments

  vault:
    url:    https://vault.example.com
    role:   (( vault "secret/ci/pipeline:role_id" ))
    secret: (( vault "secret/ci/pipeline:secret_id" ))

  git:
    owner: my-org
    repo:  my-bosh-deployments
    private_key: (( vault "secret/ci/pipeline:git_private_key" ))

  slack:
    webhook: (( vault "secret/ci/pipeline:slack_webhook" ))
    channel: "#deployments"

  boshes:
    sandbox:
      url:      https://bosh.sandbox.example.com
      ca_cert:  (( vault "secret/bosh/sandbox/ssl/ca:certificate" ))
      username: admin
      password: (( vault "secret/bosh/sandbox/admin:password" ))

    staging:
      url:      https://bosh.staging.example.com
      ca_cert:  (( vault "secret/bosh/staging/ssl/ca:certificate" ))
      username: admin
      password: (( vault "secret/bosh/staging/admin:password" ))

    production:
      url:      https://bosh.prod.example.com
      ca_cert:  (( vault "secret/bosh/prod/ssl/ca:certificate" ))
      username: admin
      password: (( vault "secret/bosh/prod/admin:password" ))

  layout: |
    auto sandbox
    sandbox -> staging -> production
```

The `(( vault ... ))` and `(( grab ... ))` expressions are spruce operators.
They are evaluated at pipeline deploy time by `spruce merge`, which means
your actual secrets never appear in the generated pipeline YAML. The
pipeline itself uses Vault AppRole authentication (the `role` and `secret`
fields) to access secrets at runtime.

## Understanding the Layout

The `layout` section uses a small domain-specific language to define how
environments relate to each other. The example above says:

The `auto sandbox` directive means that when a change is detected on the
monitored Git branch, the sandbox environment deploys automatically without
human intervention. The `sandbox -> staging -> production` line says that
after sandbox deploys successfully, staging should be triggered, and after
staging succeeds, production should be triggered.

Environments that are not listed in an `auto` directive require manual
approval in Concourse before they deploy. In this example, staging and
production both require someone to click the "play" button in the Concourse
UI after their predecessor succeeds.

See [Layout DSL](layout-dsl.md) for the full language reference.

## Deploying the Pipeline

Once your `ci.yml` is written, deploy it to Concourse:

```bash
genesis repipe
```

Genesis will ask for confirmation before uploading. If you want to skip the
confirmation prompt:

```bash
genesis repipe --yes
```

To see what would be generated without actually deploying:

```bash
genesis repipe --dry-run
```

The `--dry-run` flag prints the full Concourse pipeline YAML to stdout. This
is useful for review or for piping into other tools.

## How the Pipeline Is Compiled

`repipe` runs your configuration through a multi-stage compiler, which
is made up of a Parser, a Validator, an ASTBuilder, a
PipelineDescriptor, and a Provider. The Provider is the stage that turns
the compiled pipeline into something a CI system understands, and
Genesis ships one for Concourse and one for GitHub Actions.

Which Provider runs is decided by the repository and not by the command
line. Genesis reads `pipeline.provider.type` from the `pipeline:`
section of `.genesis/config`, so every operator working in the same
repository compiles for the same CI system. There is no flag that
overrides it, and passing one is a usage error.

Where the repository has no enabled `pipeline:` section there is nothing
for the compiler to read, and `repipe` refuses rather than falling back
to `ci.yml`. A repository that still carries a `ci.yml` with a top-level
`pipeline:` key is refused before that, by a check that tells you to
move its settings into `.genesis/config`. Migrating is how an older
repository starts working again, and there is no path that keeps reading
the old file.

## Visualizing the Pipeline

Genesis can generate a Graphviz DOT diagram of your pipeline:

```bash
genesis graph | dot -Tpng > pipeline.png
```

Or describe it in human-readable text:

```bash
genesis describe
```

Both commands accept the same `--config` option as `repipe`.

## Next Steps

Read the [Configuration Reference](configuration-reference.md) for a
complete list of every option you can set in `ci.yml`. If your pipeline
has multiple layouts or complex environment topologies, read the
[Layout DSL](layout-dsl.md) documentation. If you want to configure the
pipeline in `.genesis/config` instead, see
[Pipeline Section Configuration](multi-file-configuration.md).
