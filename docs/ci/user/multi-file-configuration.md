# Pipeline Section Configuration

Pipeline configuration lives in the `pipeline:` section of `.genesis/config`, rather than in a monolithic `ci.yml`. The schema is the contract. Every key the compiler and the commands read is declared, and `Genesis::Config` refuses an undeclared key by name as the configuration loads, for every command rather than only for the pipeline ones. There are no compatibility aliases, because the v3 schema is unreleased.

When you run `genesis pipeline-apply`, Genesis reads that section. There is no conventional `.genesis/ci/` directory any more and nothing looks for one, and there is no `--platform` flag. The provider is whichever type `pipeline.provider.type` names, so every operator working in the same repository compiles for the same CI system. A repository whose section is absent or not enabled has no pipeline to apply, and one that still carries a legacy `ci.yml` is refused by a check that names the migration.

## Section Structure

```
pipeline:
  enabled:             # Whether this repository has a pipeline
  provider:            # The automation that owns the pipeline, and its own keys
  name:                # The pipeline's name in its provider
  exodus_mount:        # The vault mount the pipeline's records live under
  recreate_on_deploy:  # Which runs pass --recreate to the BOSH deploy
  unredacted:          # Whether the pipeline's deploys print diffs unredacted
  source_control:      # What the pipeline needs to know about the repository
  vault:               # The vault a pipeline task writes exodus through
  locker:              # The locker behind the two mandatory deploy locks
  shuttle:             # The object store behind every queue and event
  notifications:       # How the pipeline notifies, and where
```

How much of this a repository needs is a question about its provider. A repository that names no provider type is on the manual provider, which sets no pipeline, so the blocks an unattended task would need are not required of it. Name `concourse` and `source_control.auth`, `source_control.identity`, `vault`, `locker`, and `shuttle` all become required, because a pipeline that runs without you has to have them.

Where an environment sits in the topology is a fact about that environment rather than about the repository, so it is not in this section at all. It lives in each environment's own file under `genesis.pipeline`, and the [Configuration Reference](configuration-reference.md) is the table for those keys.

Genesis reads `.genesis/config` through `spruce json`, which converts the YAML and evaluates no spruce operator at all, so every value in the `pipeline:` section reaches the compiler exactly as you wrote it. A credential is named by its vault reference, `path` or `path:key`, and the compiler writes each as a Concourse variable, `((path.key))`, which Concourse resolves when a build runs. `locker.password` and `locker.ca_cert` are the exception: they are written in Concourse's own `((...))` form and passed through as written. A spruce operator such as `(( vault ... ))` is never evaluated here.

`.genesis/config` is generated, so set each key with `genesis config --set <key> <value>` rather than editing the file.

## The exodus_mount Key

`pipeline.exodus_mount` is the vault mount every record the pipeline keeps lives under, and it defaults to `/secret/exodus/`. The record `genesis pipeline-apply` writes, saying which control commit the pipeline was applied from, is at `<exodus_mount>_pipelines/<deployment type>`, and each environment's own exodus record sits under the same mount. Every environment of the pipeline must resolve its own `genesis.exodus_mount` to this value, and a repository where one does not is refused when its configuration loads, naming the environment, both mounts, and this key. A repository whose environments move their secrets mount, and with it their default exodus mount, sets this key once to match.

Changing the key after an apply moves where the pipeline looks for its record. The record stays where the apply wrote it, so `genesis propagate` reads the pipeline as never applied and says to run `genesis pipeline-apply`, which writes the record at the new mount.

## The provider Block

This block names the provider and carries the keys that provider declares. The type chooses the schema, so a key one provider offers is refused by name under another that does not.

```yaml
provider:
  type: concourse
  url: https://concourse.example.com
  team: main
  insecure: false
  min_fly_version: 7.9.0
  public: false
  pause_after_set: false
  group_commits: true
  task:
    image: genesiscommunity/concourse
    version: latest
    privileged: []
```

Three types are registered. `concourse` compiles and sets a pipeline. `github-actions` validates and resolves on the CLI side but has no compiling class yet, so a repository set to it is told so rather than given a pipeline, and it declares the one key that chooses between a single emitted file and several, `output_layout`. `manual` reads no key of its own and sets no pipeline at all, so a provider key written beside `type: manual` is refused like any other key nobody declared.

Under Concourse, `public` decides whether every job's build log can be read without logging in. It is false unless you set it, and it shows only on a pipeline that is exposed, so a hidden pipeline looks the same either way.

Where some environments sit in networks only certain Concourse workers can reach, each such environment names those workers in its own file:

```yaml
genesis:
  pipeline:
    provider:
      tag: datacenter-east     # or a list of tags
```

The tag goes on the steps that need the environment's network: the task of its deploy, redeploy and notify jobs, and a check against its director. Locks, events, Slack messages, branch fetches and `propagate` run on untagged workers, since the locker, the object store, Slack and GitHub sit beside Concourse; untagged workers must reach those, and tagged ones the director, the vault and GitHub. Set it in a file several environments share and every environment beneath it takes the tag. The older `tagged: true` beside the provider is refused; it put an environment's own name on every step, so to keep that, set `tag: <env>` in each environment.

`secrets_store` says where Concourse resolves the pipeline's `((...))` references, which may be a different vault from the one your environments use:

```yaml
provider:
  secrets_store:
    url: https://vault.ops.example.com   # unset: the repository's own vault (secrets_provider)
    namespace: ops                       # if any
    path_prefix: /concourse              # Concourse's --vault-path-prefix; the default
```

Concourse reads a reference `((name.key))` at `<path_prefix>/<team>/<pipeline>/name`, then at `<path_prefix>/<team>/name`. Under Concourse, Genesis's CI paths follow that order whether or not you write the block, which you need only to point elsewhere or change a default; leave it out entirely when Concourse reads the same vault your `secrets_provider` names, under `/concourse`: `ci_mount` is the team scope, `/concourse/<team>/`, for what every pipeline of the team shares; the pipeline scope `/concourse/<team>/<pipeline>/` holds what this repository's pipeline alone uses; and `ci_base` is `/concourse/<team>/<pipeline>/<env>/`. Hooks see the first and last as `GENESIS_CI_MOUNT` and `GENESIS_CI_BASE`, and an environment can still override either with `genesis.ci_mount` or `genesis.ci_base`. Each operator reaches the store through their own `safe` target for its URL. Under the manual provider, or with the pipeline disabled, the CI paths stay where they always were, under the environment's secrets mount.

`pipeline-apply` checks every `((name.key))` the compiled pipeline uses before it sets anything, at the pipeline scope, then the team scope, then `<path_prefix>/<shared_path>/` where `shared_path` is given, and reports each as found, missing, or unverified (when it cannot read the store, or `--skip-vault` is given), never printing a value. A missing one refuses the apply; `--missing-secrets-ok` sets the pipeline anyway, for a first apply whose secrets you set afterwards. The check finds a secret anywhere Concourse would. Publish the credentials your pipelines share, such as the locker's, the shuttle's, and the AppRole pipelines reach your vault with, at the team scope, `<path_prefix>/<team>/`; a shared path works too where your Concourse has one. Your repository only references them, and the apply writes none of them. The one exception is a BOSH director's credentials. Where an environment sets `genesis.pipeline.track_bosh_configs`, the apply copies them from the director's exodus record to the pipeline scope before the check runs (see [BOSH config tracking](../../workflows/bosh-config-tracking.md#the-directors-credentials)).

Two limits. `shared_path` must be the value your Concourse server's `--vault-shared-path` is set to: Genesis cannot read the server's settings, so a shared path the server does not use would report a secret found where Concourse never looks. And a Concourse whose `--vault-lookup-templates` changes its lookup order is not modelled; the check assumes the default order above.

`git` says how the pipeline learns that a branch moved:

```yaml
provider:
  git:
    webhooks: true            # the default is false: every branch is polled
    control_check_every: 1m   # control's fallback poll; unset, Concourse's 1m
    check_every: 1h           # every deployment branch's fallback poll; unset, 1m
```

With `webhooks` on, `pipeline-apply` keeps a webhook token for this pipeline in the secrets store and a GitHub push hook that checks control the moment anything is pushed, and propagate asks Concourse to check each deployment branch it has just pushed, so a deploy starts within seconds of its delivery. What neither reports, chiefly a pull request merged on GitHub, waits for the fallback poll, which is why the intervals are still worth setting: an hour for the deployment branches keeps GitHub's traffic low. The intervals are Concourse durations (`30s`, `5m`, `1h`) or `never`.

The token is the pipeline's own: `pipeline-apply` writes one to the secrets store at `<path_prefix>/<team>/<pipeline>/webhook` when there is none, leaves it after that, and replaces it, and the hook with it, when you give `--rotate-webhook-token`. It never prints it. The hook is the one whose URL calls this pipeline's `control-branch`, so another tool's hook, or another root's in the same repository, is never touched; turning `webhooks` off removes it. The apply needs write access to that scope of the store, and a `GITHUB_AUTH_TOKEN` that may manage the repository's hooks (Webhooks: write, or `admin:repo_hook`); without the latter it prints the URL to set by hand. GitHub allows twenty push hooks per repository, one per deployment root's pipeline, and past that the apply reports GitHub's refusal and the fallback poll does the work.

`group_commits` is true, a deploy taking the tip of whatever arrived on its branch. False would deploy each commit in turn, and that is not built yet, so false is refused when the configuration loads.

Each provider also declares what it is able to do, as six named capabilities, and a configuration key whose capability is false is refused at configuration load naming the key, the provider, and the capability. That is how `genesis.pipeline.manual` and `genesis.pipeline.redeploy_cron` are gated, and `pipeline.provider.group_commits` with them.

## The source_control Block

This block is what the pipeline needs to know about the repository it is deploying from.

```yaml
source_control:
  repository: my-org/my-deployments   # or its URL; optional where the remotes settle it
  pr_prefix: pr/
  control_requires_pr: false
  auth:
    type: ssh
    path: git
  api_token: github:token
  identity:
    name:  Genesis CI
    email: ci@example.com
```

`repository` is the repository the pipeline lives in, and the one the GitHub API is called on. The remote is not configured: Genesis uses whichever of the clone's remotes points at the repository, and a clone whose remote cannot be matched, such as a mirror, pins one with `git config genesis.remote <remote>`. The [Configuration Reference](configuration-reference.md#pipelinesource_control) says how the match works. `uri` overrides the URL CI clones from, where it cannot be composed from `repository`. The deployment root takes no key, being a fact of the checkout, and neither does the branch a command happens to be run from, that being runtime state.

`auth` and `identity` are for CI alone, and they are required wherever a pipeline task has to clone and commit on its own. `auth.type` is `ssh` or `https`, and `auth.path` names the vault secret holding the type's components under their own names: `private_key` for `ssh`, `username` and `password` for `https`. A component kept elsewhere is given on its own as `<path>:<key>`, which replaces the default for that component alone, so `{type: https, path: secret/ci/git, password: secret/shared/token:value}` reads the username from `secret/ci/git` and the password from the shared secret. The load refuses a block missing a component, and a component the type does not take. The old `auth.vault` key is refused, naming `path`.

`api_token` is the GitHub token the pipeline's propagate job opens and updates pull requests with, as `<path>:<key>`, and it is read only where an environment sets `genesis.pipeline.require_pr`. Where it is not set, an `https` clone credential's password is used in its place, since that is a GitHub token too; an `ssh` clone credential is not one, so a pipeline with a pull request environment and `ssh` auth is refused at compile until `api_token` is set. The token needs read and write access to the repository's contents and pull requests. Both the clone credential and this token should belong to an automation account rather than a person: GitHub does not let a pull request's author approve it.

## The vault, locker, and shuttle Blocks

```yaml
vault:
  url: https://vault.example.com
  namespace: null
  auth:
    type: approle                       # or token
    path: secret/ci/pipeline/approle    # holds role_id and secret_id

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
  auth: shuttle                         # holds access_key_id and secret_access_key
```

`vault` is the vault a pipeline task writes exodus through, and `url` is the one key it cannot do without. `locker` is the locker behind the two mandatory deploy locks. `shuttle` is the object store behind every deployment's request queue, `<env>-<type>/redeploy`, and its `_deployed` and `_redeployed` events, at `<env>-<type>/deployed` and `<env>-<type>/redeployed`. Its `backend` chooses its shape, which is `s3`, the one store the shuttle resource has. The backend is required, so a shuttle block written with no backend, or with another, is refused as an unknown value naming `s3`.

## The notifications Block

```yaml
notifications:
  style: inline                 # inline, parallel or grouped
  slack:
    webhook: slack:webhook      # path:key of the webhook URL
    channel: "#deployments"     # a legacy webhook only
    mentions_on_failure: ["@oncall"]
```

Notifications are the repository's settings, for every environment alike. An environment's own `genesis.pipeline.notifications` is accepted at load but not read, so leave it unset. `email` is accepted and not emitted.

With Slack configured, each message begins with an emoji for its kind, so a run of them reads at a glance:

| Message | Emoji |
|---|---|
| A deploy started, once it holds its locks | 🚀 `:rocket:` |
| A redeploy started | 🔄 `:arrows_counterclockwise:` |
| A deploy succeeded | ✅ `:white_check_mark:` |
| A redeploy succeeded | ♻️ `:recycle:` |
| A deploy or redeploy failed | ❌ `:x:` |
| A deploy or redeploy errored | ⚠️ `:warning:` |
| A deploy or redeploy was aborted | ⏹️ `:black_square_for_stop:` |
| Changes are staged for a manual deploy | 📥 `:inbox_tray:` |
| The staged changes could not be offered | ⛔ `:no_entry:` |
| Propagation opened or updated pull requests | 🔀 `:twisted_rightwards_arrows:` |
| A director's BOSH config changed | ⚙️ `:gear:` |

A start message never stops a deploy: a Slack outage or a bad webhook fails the message alone, and the deploy goes on.

## The redeploy Block

```yaml
redeploy:
  enabled: true    # the default
  style: inline    # the default; or grouped
```

`enabled` decides whether the pipeline has redeploy jobs at all. Where it is true, every environment gets a `redeploy-<env>` job, which deploys again the commit its last successful deploy recorded, together with that job's request queue and its `_redeployed` event. Where it is false, none of the three is emitted for any environment, and an environment that sets `genesis.pipeline.redeploy_cron` is refused at load, naming both keys, since its schedule would have no job to trigger. Redeploying by hand with `genesis <env> deploy --redeploy` works either way.

`style` decides where the redeploy jobs sit in the Concourse UI. `inline` keeps each beside its deploy in the deployment group; `grouped` lists them all in one `redeploys` group, after the deployment groups and before `propagation`, which suits a pipeline whose deployment view should show only what moves content forward. It has no effect where `enabled` is false.

## The registry Block

```yaml
registry:
  uri: registry.example.com/mirror
  auth:
    type: basic
    path: concourse/registry   # holds username and password
```

Where Concourse cannot pull from public registries, `registry` names the mirror it pulls through. `uri` prefixes every image Genesis names by default: each resource type the pipeline declares, the task image, and the shuttle image. Each of those sources carries the credential as references, `username` and `password` read from `path` or given one by one as `<path>:<key>`. An image you name yourself, `provider.task.image` or `shuttle.image`, is used exactly as you write it, so a mirror that keeps your own images under a different path than the public ones is written in full there; it carries the credential when it begins with the registry's host. Without the block every image is pulled as named.

## The Override File

Where the compiled output needs a change the configuration cannot express, one override file sits beside `.genesis/config` and is merged over the emitted output verbatim, after compilation. There is no override directory and no override key in the section.

The file is named for the provider, as `.genesis/pipeline-overrides-<provider>.yml`, so `.genesis/pipeline-overrides-concourse.yml` is the whole of it for a Concourse repository. A provider that emits more than one file takes one override per emitted file instead, named for that file's base name with the directory flattened into the name, so a provider emitting `qa/deploy.yml` and `prod/deploy.yml` reads `.genesis/pipeline-overrides-<provider>-qa-deploy.yml` and `.genesis/pipeline-overrides-<provider>-prod-deploy.yml`. The whole output name goes in, directory and all, because dropping the directory would let two emitted files merge against the same override and nothing in the run would say so.

Which form applies follows the output layout in force rather than the provider's capability, so a provider that can emit several files but is set to `single` takes the single form. An output that is not YAML passes through untouched, and only the files the layout names are read, and only where they are on disk.

## Migrating from ci.yml

A repository that still carries a pipeline `ci.yml` has not moved to v3, and every pipeline command refuses it by name and tells you what to do. The move is by hand, and the operator's guide *Pipeline Migration: v2 to v3* gives its order and every setting's new home.

In outline:

1. Pause the v2 pipeline.
2. Write each `ci.yml` setting into the `pipeline:` section of `.genesis/config` with `genesis config --set`.
3. Remove `ci.yml` with `git rm ci.yml`, which restores the pipeline commands.

The topology does not come across as a `layout` string at all. Each environment's place in it goes into that environment's own file:

- `genesis.pipeline.prior_env` names the environment before it.
- `genesis.pipeline.manual: true` marks every environment the layout's `auto` pattern did not match, because a v3 environment deploys automatically unless it says otherwise.

Give the v3 pipeline a different `pipeline.name` where it would take the v2 pipeline's, and apply it with `--paused` beside the paused v2 one.

Anything else `ci.yml` carried outside its `pipeline:` key, which v2 merged over the generated pipeline, moves to the override file, `.genesis/pipeline-overrides-concourse.yml` (see "The Override File" above), which is merged over the compiled pipeline the same way. Review it before the first apply rather than copying it across blind: the v3 pipeline names its jobs and resources differently (`deploy-<env>`, `redeploy-<env>`, `notify-<env>`, `propagate`, `control-branch`, `<env>-branch`), so an entry that patched a v2 job or resource by name now matches nothing and adds a new one beside the generated pipeline instead. `genesis pipeline-apply --dry-run` prints the merged result to check against.

Once migrated, set the pipeline paused, review it, and unpause it in Concourse:

```bash
genesis pipeline-apply --paused
```
