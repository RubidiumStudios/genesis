# Getting Started with Genesis CI Pipelines

Genesis automates the deployment of BOSH environments through CI/CD pipelines. You configure the repository once in `.genesis/config`, you say in each environment file where that environment sits in the topology, and Genesis cuts the branches, sets the pipeline, and delivers your commits environment by environment. This guide walks through standing a pipeline up from scratch.

## What a Pipeline Does

Your work lands on one branch, the control branch, and every environment has a deployment branch of its own named `<env>/<type>`. A commit on control is delivered to an environment's branch only when every environment upstream of it has already deployed the files that commit touches, so what reaches production is what was tested in staging. An environment that has not deployed yet holds its descendants, and the hold carries the reason.

For example, if you have a sandbox that feeds into staging which feeds into production, a change to a shared YAML file reaches `sandbox/bosh` first. Staging and production wait. Once sandbox deploys that commit, the next propagation run delivers it to `staging/bosh`, and production waits on staging in the same way.

Two commands do the work. `genesis pipeline-apply` gives the pipeline its shape, which means cutting the deployment branches, applying branch protection, writing the exodus records, and setting the pipeline on the provider where there is one to set. `genesis propagate` walks the control branch forward and delivers each commit to the branches that are ready for it.

## Prerequisites

You need a Genesis deployment repository that has been initialized with `genesis init`, on version 3 of the repository configuration. The repository should have at least one environment file, such as `my-env.yml`, and a configured Vault for secrets storage. If you are deploying to Concourse, you also need a running Concourse instance and the `fly` CLI authenticated to a target.

If the repository still carries a `ci.yml` with a top-level `pipeline:` key, every pipeline command refuses to run and tells you to migrate. See the "Migration from v2" section of `workplans/Branch-based-Workflow-Architecture.md` for what the move by hand involves.

## Configuring the Repository

The repository's own pipeline settings live in the `pipeline:` block of `.genesis/config`. Here is a minimal working example for Concourse:

```yaml
pipeline:
  enabled: true

  provider:
    type: concourse
    url: https://concourse.example.com
    team: main

  name: my-bosh-deployments

  source_control:
    repository: my-org/my-bosh-deployments
    control_branch: control
    auth:
      type: ssh
      vault: secret/ci/pipeline:git_private_key
    identity:
      name:  Concourse Bot
      email: concourse@pipeline

  vault:
    url: https://vault.example.com
    auth: secret/ci/pipeline:approle

  locker:
    url: https://locker.example.com
    username: locker-user
    password: ((locker-password))

  shuttle:
    backend: s3
    bucket: my-pipeline-shuttle

  notifications:
    style: default
    slack:
      webhook: ((slack-webhook))
      channel: "#deployments"
```

The schema is the contract. Every key a pipeline command reads is declared, validation runs at configuration load for every command rather than only for the pipeline ones, and a key the schema does not declare is refused by name. There are no compatibility aliases.

The provider decides how much of this block you need. A repository that names no provider type is on the manual provider, which sets no pipeline, so the credential blocks an unattended task would need are not required of it. Name `concourse` and Genesis asks for the source control credential, the identity a task commits under, the vault, the locker, and the shuttle, because a pipeline that runs without you has to have them.

Genesis reads `.genesis/config` through `spruce json`, which evaluates no spruce operator at all, so every value in the block reaches the compiler exactly as you wrote it. Write credential references in the form your provider resolves, such as Concourse's `((credential))`.

## Configuring Each Environment

Where an environment sits in the topology is a fact about that environment, so it lives in that environment's own file under `genesis.pipeline`. The block is read merged, so a key set in a site file is inherited by every environment beneath it.

```yaml
genesis:
  env: staging
  pipeline:
    prior_env: sandbox
    manual: true
    require_pr: true
    redeploy_cron: "0 6 * * *"
    track_dependencies:
      - sandbox/bosh
    track_additional_files:
      - ops/shared.yml
```

`prior_env` is the topology edge, naming the environment this one follows. An environment with no `prior_env` takes control's commits without waiting on an ancestor. The rest of the keys are covered in the [Configuration Reference](configuration-reference.md), and a key whose ability your provider does not declare is refused at configuration load naming both the key and the capability.

## Applying the Pipeline

Once both halves are configured, give the pipeline its shape:

```bash
genesis pipeline-apply
```

This cuts a deployment branch for every environment, applies the branch protection each one's `require_pr` asks for, writes the exodus records, and then compiles the pipeline and uploads it to the provider. Genesis asks for confirmation before uploading. To skip the prompt:

```bash
genesis pipeline-apply --yes
```

To see what would be generated without deploying anything:

```bash
genesis pipeline-apply --dry-run
```

The `--dry-run` flag prints the full pipeline YAML to stdout, which is useful for review or for piping into other tools.

## Propagating Your Commits

With the branches cut, deliver control's commits to the environments that are ready for them:

```bash
genesis propagate
```

The run takes no environment argument. It walks the control branch forward from every deployment branch's newest marker and routes each commit on its own, in control order, switching to the control branch inside its own session and leaving you on the branch you started on. To see what each environment would receive without writing anything, run `genesis propagate --dry-run`.

To read where every environment stands, including what is held and why:

```bash
genesis pipeline-status
```

## How the Pipeline Is Compiled

`pipeline-apply` runs your configuration through a multi-stage compiler, which is made up of a Parser, a Validator, ScriptDiscovery, an ASTBuilder, a PipelineDescriptor, and a Provider. The Provider is the stage that turns the compiled pipeline into something a CI system understands, and Genesis ships one for Concourse, one for GitHub Actions, and one for manual operation.

Which Provider runs is decided by the repository and not by the command line. Genesis reads `pipeline.provider.type` from the `pipeline:` block of `.genesis/config`, so every operator working in the same repository compiles for the same CI system. There is no flag that overrides it, and passing one is a usage error.

Where the repository has no enabled `pipeline:` block there is nothing for the compiler to read, and `pipeline-apply` refuses rather than falling back to `ci.yml`. Migrating is how an older repository starts working again, and there is no path that keeps reading the old file.

## Visualizing the Pipeline

Genesis writes a Mermaid flowchart of your pipeline to `pipeline.md`:

```bash
genesis pipeline-graph
```

Or describes it in words:

```bash
genesis pipeline-describe
```

## Next Steps

Read the [Configuration Reference](configuration-reference.md) for the per-environment keys and for every option the legacy format took. If you want the whole `pipeline:` block key by key, see [Pipeline Section Configuration](multi-file-configuration.md). The [CLI Commands](cli-commands.md) page covers `genesis propagate` and the rest of the `pipeline-*` family.
