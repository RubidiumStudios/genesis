# Pipeline Section Configuration

Pipeline configuration lives in the `pipeline:` section of `.genesis/config`, rather than in a monolithic `ci.yml`. The schema is the contract. Every key the compiler and the commands read is declared, and `Genesis::Config` refuses an undeclared key by name as the configuration loads, for every command rather than only for the pipeline ones. There are no compatibility aliases, because the v3 schema is unreleased.

When you run `genesis pipeline-apply`, Genesis reads that section. There is no conventional `.genesis/ci/` directory any more and nothing looks for one, and there is no `--platform` flag. The provider is whichever type `pipeline.provider.type` names, so every operator working in the same repository compiles for the same CI system. A repository whose section is absent or not enabled has no pipeline to apply, and one that still carries a legacy `ci.yml` is refused by a check that names the migration.

## Section Structure

```
pipeline:
  enabled:             # Whether this repository has a pipeline
  provider:            # The automation that owns the pipeline, and its own keys
  name:                # The pipeline's name in its provider
  recreate_on_deploy:  # Which runs pass --recreate to the BOSH deploy
  source_control:      # What the pipeline needs to know about the repository
  vault:               # The vault a pipeline task writes exodus through
  locker:              # The locker behind the two mandatory deploy locks
  shuttle:             # The object store behind every queue and event
  notifications:       # How the pipeline notifies, and where
```

How much of this a repository needs is a question about its provider. A repository that names no provider type is on the manual provider, which sets no pipeline, so the blocks an unattended task would need are not required of it. Name `concourse` and `source_control.auth`, `source_control.identity`, `vault`, `locker`, and `shuttle` all become required, because a pipeline that runs without you has to have them.

Where an environment sits in the topology is a fact about that environment rather than about the repository, so it is not in this section at all. It lives in each environment's own file under `genesis.pipeline`, and the [Configuration Reference](configuration-reference.md) is the table for those keys.

Genesis reads `.genesis/config` through `spruce json`, which converts the YAML and evaluates no spruce operator at all, so every value in the `pipeline:` section reaches the compiler exactly as you wrote it. Write credential references in the form your CI provider resolves, such as Concourse's `((credential))`, and keep `(( vault ... ))` and the other spruce operators for a legacy `ci.yml`, which the parser does load through `spruce merge`.

## The provider Block

This block names the provider and carries the keys that provider declares. The type chooses the schema, so a key one provider offers is refused by name under another that does not.

```yaml
provider:
  type: concourse
  url: https://concourse.example.com
  target: my-target
  team: main
  insecure: false
  min_fly_version: 7.9.0
  public: false
  tagged: false
  pause_after_set: false
  group_commits: true
  task:
    image: genesiscommunity/concourse
    version: latest
    privileged: []
```

Three types are registered. `concourse` compiles and sets a pipeline. `github-actions` validates and resolves on the CLI side but has no compiling class yet, so a repository set to it is told so rather than given a pipeline, and it declares the one key that chooses between a single emitted file and several, `output_layout`. `manual` reads no key of its own and sets no pipeline at all, so a provider key written beside `type: manual` is refused like any other key nobody declared.

Each provider also declares what it is able to do, as six named capabilities, and a configuration key whose capability is false is refused at configuration load naming the key, the provider, and the capability. That is how `genesis.pipeline.manual` and `genesis.pipeline.redeploy_cron` are gated, and `pipeline.provider.group_commits` with them.

## The source_control Block

This block is what the pipeline needs to know about the repository it is deploying from.

```yaml
source_control:
  repository: my-org/my-deployments
  remote: origin
  uri: git@github.com:my-org/my-deployments.git
  control_branch: control
  pr_prefix: pr/
  control_requires_pr: false
  auth:
    type: ssh
    vault: secret/ci/pipeline:git_private_key
  identity:
    name:  Concourse Bot
    email: concourse@pipeline
```

`remote` and `uri` are derived from the control branch's upstream, and `repository` is the GitHub owner and repository the API targets. Each is a choice with a good default rather than a fact of the checkout, which is why each takes a key. The deployment root takes none, being a fact of the checkout, and neither does the branch a command happens to be run from, that being runtime state.

`auth` and `identity` are for CI alone, and they are required wherever a pipeline task has to clone and commit on its own. `auth.type` is `ssh` or `https`, and `auth.vault` is the path holding the credential.

## The vault, locker, and shuttle Blocks

```yaml
vault:
  url: https://vault.example.com
  namespace: null
  auth: secret/ci/pipeline:approle

locker:
  url: https://locker.example.com
  username: locker-user
  password: ((locker-password))
  ca_cert: null
  skip_ssl_validation: false

shuttle:
  backend: s3
  bucket: my-pipeline-shuttle
  region: us-east-1
  endpoint: null
  auth: secret/ci/pipeline:s3
```

`vault` is the vault a pipeline task writes exodus through, and `url` is the one key it cannot do without. `locker` is the locker behind the two mandatory deploy locks. `shuttle` is the object store behind every deployment's request queue and `_ran` event, and its `backend` chooses its shape: `s3` and `gcs` are the two, and the backend is required, so a shuttle block written with no backend is refused as an unknown value naming the two you may write.

## The notifications Block

```yaml
notifications:
  style: default
  slack:
    webhook: ((slack-webhook))
    channel: "#deployments"
  email:
    recipients:
      - ops@example.com
```

This is the repository default, and each environment's own `genesis.pipeline.notifications` overrides it.

## The Older Block Shape

The three blocks below, `pipeline`, `targets`, and `integrations`, are the shape the configuration had under the multi-file layout, and the compiler's parser still normalises them. The repository schema does not declare them, so writing one into `.genesis/config` is refused by name at configuration load. They are documented here for reading an older repository and for working on the parser, and not as keys to write.

### The pipeline Block

This block defined the pipeline identity, branch configuration, workflows, and global settings.

```yaml
metadata:
  name: my-cf-deployments
  version: "1.0"

branches:
  live: main
  target_prefix: target/

workflows:
  default:
    type: deployment
    triggers:
      - type: git
        pattern: "*.yml"
    stages:
      - name: deploy-sandbox
        script: deploy
        inputs: [deployment-repo]
        outputs: [manifests]
      - name: deploy-staging
        script: deploy
      - name: approve-prod
        type: manual-approval
        approvers: [ops-team]
      - name: deploy-prod
        script: deploy

configuration:
  public: false
  tagged: false
  task:
    image: genesiscommunity/concourse
    version: latest
  notifications:
    style: inline
```

The `metadata` section names the pipeline and assigns a version. The `branches` section defines which Git branch the pipeline monitors (`live`) and the prefix used for target branches.

The `workflows` section is the heart of the configuration. Each workflow is a named deployment topology. When using the legacy layout DSL (via a fallback from `ci.yml`), the parser converts the layout into a workflow automatically. In the `pipeline:` section, you can define workflows with explicit stages and trigger relationships.

The `configuration` section holds global settings that correspond to the top-level boolean flags and task/registry/notification settings from the legacy format.

### The targets Block

This block defined deployment targets, which are BOSH directors.

```yaml
targets:
  sandbox:
    name: sandbox
    alias: sandbox
    type: bosh-director
    tags: []
    connection:
      url: https://bosh.sandbox.example.com
      auth:
        type: basic
        client_id: admin
        client_secret: ((bosh-sandbox-password))
      ca_cert: ((bosh-sandbox-ca-cert))

  proto:
    name: proto
    alias: proto-bosh
    type: bosh-create-env
    tags:
      - create-env
```

Each target has a `type` that is either `bosh-director` for standard deployments or `bosh-create-env` for proto-BOSH create-env deployments. The `connection` section mirrors the fields from `pipeline.boshes` in the legacy format but uses a structured `auth` map instead of flat `username`/`password` fields.

The `alias` and `genesis_env` fields work the same way as in the legacy `boshes` section.

### The integrations Block

This block defined the external service integrations, which are Vault, Git source control, notifications, and the optional Locker service.

```yaml
vault:
  url: https://vault.example.com
  namespace: null
  auth:
    type: approle
    role_id: ((vault-role-id))
    secret_id: ((vault-secret-id))
  options:
    tls_verify: true
    no_strongbox: false

source_control:
  provider: github
  repository: my-org/my-deployments
  uri: null
  default_branch: main
  root: .
  version_depth: 0
  commit_author:
    name: Concourse Bot
    email: concourse@pipeline
  auth:
    type: ssh-key
    private_key: ((git-private-key))

notifications:
  - type: slack
    name: slack
    webhook: ((slack-webhook))
    channel: "#deployments"
    username: runwaybot
    icon: http://cl.ly/image/.../concourse-logo.png
    events: [started, failed, succeeded]

  - type: email
    name: email
    recipients:
      - ops@example.com
    from: concourse@example.com
    smtp:
      host: smtp.example.com
      username: smtp-user
      password: ((smtp-password))
    events: [failed]

locker:
  url: https://locker.example.com
  username: locker-user
  password: ((locker-password))
  ca_cert: null
  skip_ssl_validation: true
```

The `vault` and `source_control` sections are required. The validator checks for `vault.url` and the presence of `source_control`. Notifications are a list because you can have multiple notification providers active simultaneously.

The `source_control.provider` field accepts `github` or `gitlab` and is used to construct the Git URI automatically from the `repository` field (e.g., `github` + `my-org/my-repo` becomes `git@github.com:my-org/my-repo.git`). If you need a custom URI, set the `uri` field directly.

## Script Metadata

The `scripts/` directory at the root of your deployment repository can contain shell scripts referenced by workflow stages, and script discovery still reads their metadata. Scripts can declare it in two ways.

The first way is a `scripts:` block, which explicitly lists each script and its requirements. Like the three blocks above it, this one belongs to the older shape, so the repository schema does not declare it and the parser reads it only where it comes from an older configuration:

```yaml
scripts:
  deploy:
    description: Execute Genesis deployment
    path: scripts/deploy.sh
    executor: bash
    version: "1.0"
    requirements:
      - tool: genesis-cli
        version: ">=3.1.0"
    inputs:
      - name: deployment-repo
        type: git-repository
        required: true
    outputs:
      - name: manifests
        type: directory
        path: .genesis/manifests/
    environment:
      required: [CURRENT_ENV, VAULT_ADDR]
      optional: [GENESIS_TRACE]
    timeout: 60m
```

The second way is inline annotations in the script file itself, which is the one that needs no configuration key at all:

```bash
#!/bin/bash
# @genesis-script
# @description: Execute Genesis deployment
# @version: 1.0
# @requires: genesis-cli>=3.1.0, bosh-cli>=7.0
# @input: deployment-repo (git-repository, required)
# @output: manifests (directory, .genesis/manifests/)
# @env-required: CURRENT_ENV, VAULT_ADDR
# @env-optional: GENESIS_TRACE
# @timeout: 60m
```

Scripts without either a `scripts:` entry or inline annotations are still discovered. The system infers basic metadata from the filename, assigning a default description based on the path and assuming `bash` as the executor.

## The Override File

Where the compiled output needs a change the configuration cannot express, one override file sits beside `.genesis/config` and is merged over the emitted output verbatim, after compilation. There is no override directory and no override key in the section.

The file is named for the provider, as `.genesis/pipeline-overrides-<provider>.yml`, so `.genesis/pipeline-overrides-concourse.yml` is the whole of it for a Concourse repository. A provider that emits more than one file takes one override per emitted file instead, named for that file's base name with the directory flattened into the name, so a provider emitting `qa/deploy.yml` and `prod/deploy.yml` reads `.genesis/pipeline-overrides-<provider>-qa-deploy.yml` and `.genesis/pipeline-overrides-<provider>-prod-deploy.yml`. The whole output name goes in, directory and all, because dropping the directory would let two emitted files merge against the same override and nothing in the run would say so.

Which form applies follows the output layout in force rather than the provider's capability, so a provider that can emit several files but is set to `single` takes the single form. An output that is not YAML passes through untouched, and only the files the layout names are read, and only where they are on disk.

## Relationship to Legacy Format

When the compiler pipeline reads a legacy `ci.yml`, the parser normalizes it into the same internal structure the older blocks above describe. The `boshes` section becomes `targets`, the `vault`, `git`, `slack`, and `email` sections become `integrations`, and the `layout` string is parsed into a workflow with a graph of nodes and edges.

This means that both formats flow through the same Validator, ASTBuilder, and provider pipeline. The only difference is where the configuration comes from initially.

## Migrating from ci.yml

A repository that still carries a pipeline `ci.yml` has not moved to v3, and every pipeline command refuses it by name and tells you what to do. The move is by hand, and the "Migration from v2" section of `workplans/Branch-based-Workflow-Architecture.md` is where it is written out.

In outline, there are three steps. You read the `pipeline:` block of `ci.yml` for the provider, the git URI, the branch, the pipeline name, and the vault URL. You write them into the `pipeline:` block of `.genesis/config`, which declares every one of them. Then you remove `ci.yml` with `git rm ci.yml`, and that restores the pipeline commands. The topology does not come across as a `layout` string at all. Each environment's place in it goes into that environment's own file, under `genesis.pipeline.prior_env`.

Once migrated, give the pipeline its shape:

```bash
genesis pipeline-apply
```
