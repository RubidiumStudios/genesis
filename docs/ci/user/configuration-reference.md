# Configuration Reference

A v3 repository configures its pipeline in two places. The repository's own settings live in `.genesis/config` under the `pipeline` key, and each environment's settings live in that environment's own file under `genesis.pipeline`. The schema is the contract, so every key a command reads is declared, validation runs at configuration load for every command, and a key the schema does not declare is refused by name rather than aliased.

The `ci.yml` format the rest of this document describes is the legacy format. A repository that still carries a pipeline `ci.yml` has not moved to v3, every pipeline command refuses it and names the migration, and the "Migration from v2" section of `workplans/Branch-based-Workflow-Architecture.md` says what the move by hand involves.

## Per-environment `genesis.pipeline` keys

| Key | What it does |
|-----|--------------|
| `prior_env` | Names this environment's parent in the topology. An environment with no `prior_env` takes control's commits without waiting on an ancestor |
| `require_pr` | Routes delivery through `<pr_prefix><env>/<type>` and a pull request into the deployment branch, and is also the rule `genesis pipeline-apply` applies to that branch's protection |
| `manual` | Marks the environment as one a person starts, which the graph labels and `genesis pipeline-status` reads, and which is provider-conditional as the section below states |
| `redeploy_cron` | One crontab string, or a list of them, in UTC, triggering the environment's redeploy job |
| `track_dependencies` | The deployments this one reads, declared so that the applied record and the staleness check know about them |
| `track_bosh_configs` | Whether, or which, BOSH config changes trigger this environment's redeploy job |
| `track_additional_files` | Extra paths for this environment's propagation set, relative to the deployment root, with `<env>` substitution and globs |
| `notifications` | The per-environment override of the repository's notification settings |

The block is read merged, so a key written in a site file is inherited by every environment beneath it, and a key written in the environment's own file wins over the one it inherits.

### `manual`

Every environment built from environment files already takes `trigger: false` on the deployment branch's `get` in the deploy job, so the pipeline fetches the branch and then waits for a person to start the job, and writing `manual` does not change that get. What the key reaches today is how the pipeline is read rather than how it is emitted. The Mermaid graph labels the environment `MANUAL`, and `genesis pipeline-status` reads the key when it says that a descendant is held by an ancestor awaiting its trigger.

The key is valid only where the provider emits a triggering resource, because a key about triggering says nothing where the provider emits no trigger at all. That ability has a name, `optional_git_triggers`, and every provider declares whether it has it. Concourse declares it true. The manual provider declares all six of its abilities false, because `genesis pipeline-apply` sets no pipeline at all under it. Nothing fetches, nothing triggers, and there is no `get` for the key to sit on, so an operator runs `genesis <env> deploy` by hand instead. GitHub Actions declares the ability false as well, until the class that emits for it is written.

Where the ability is absent the key is refused at configuration load, by name, and the refusal names the key, the provider, and the capability together. Writing `genesis.pipeline.manual` in an environment file of a repository that has its pipeline enabled and sits on the manual provider therefore fails every command rather than only the pipeline ones, because a key that cannot mean anything is better said out loud than accepted and dropped when the pipeline is emitted. A repository whose `pipeline.enabled` is false is not validated at all, so it carries the key with no refusal.

An environment whose deploy job waits for a person certifies nothing until that person acts, so its descendants stay held meanwhile, and `genesis pipeline-status` prints the reason as `awaiting its trigger` beside the ancestor that holds them.

## pipeline.source_control

Says which repository the pipeline lives in and how CI reaches it. The block is read from the working tree's own `.genesis/config` rather than from control, because it says where control is, so it has to be known before control can be read.

```yaml
pipeline:
  source_control:
    repository: team/bosh-deployments
    # or, as its URL, on any host:
    #   repository: https://git.example.com/team/bosh-deployments.git
    #   repository: git@git.example.com:team/bosh-deployments.git
    control_branch: control
    pr_prefix:      pr/
    auth:
      type:  ssh            # or https
      vault: secret/ci/git
    identity:
      name:  Genesis CI
      email: ci@example.com
```

`repository` names the repository, written as `owner/repo`, which means github.com, or as the repository's https or ssh URL, which carries its own host. Every form names one repository, so they are interchangeable. It can be left out where the clone's remotes leave no doubt which repository they point at.

A `genesis propagate` with an environment that sets `require_pr` needs `GITHUB_AUTH_TOKEN`, because what a reviewer decided is what decides whether that environment's pull request branch is rebuilt or left alone. Without it the run refuses before writing anything, naming the variable and those environments. `--dry-run` still runs, and says that a real run would refuse.

Pull requests and branch protection are GitHub's API, and they are called on the repository's own host: `https://api.github.com` for github.com, and `https://<host>/api/v3`, GitHub Enterprise Server's API, for any other host. Nothing is asked only to find out whether a host is GitHub. The answers to those calls say it, by the `X-GitHub-Request-Id` and `X-GitHub-Media-Type` headers GitHub puts on every answer. A host other than github.com is remembered in `~/.genesis/cache/github-hosts.yml`, with the GitHub Enterprise Server version it answered with. A host that answers without those headers is asked once more, and then refused, naming the host, the address asked and what came back. Only a command that calls the API meets that refusal: `genesis pipeline-apply` with a token, a `genesis propagate` that opens a pull request, and the pull request column of `genesis pipeline-status`, which says the host is not GitHub and goes on. A repository on another kind of host still loads, and runs every command that calls no API: with no environment setting `require_pr`, and with `GITHUB_AUTH_TOKEN` unset where `genesis pipeline-apply` runs, which then skips the branch protection and says so.

The remote is not configured. A remote's name and its protocol are each cloner's own choice, made when they clone and before `.genesis/config` is there to read, so the remote Genesis reads, refreshes and publishes through is whichever of the clone's remotes points at the repository, under any name and any protocol. A clone with one remote uses it, unless its URL names a different repository. Where two remotes point at the repository, the one the control branch tracks is used. Where the remotes point at more than one repository and `repository` is unset, as with a fork beside the original, the configuration load refuses rather than guess, because a clone of a fork tracks the fork. `pipeline.source_control.remote` is no longer read, and a configuration that still sets it is refused, naming what replaces it.

A remote whose URL cannot be matched to the repository, such as an internal mirror on another host, is pinned instead:

```
git config genesis.remote <remote>
```

For example, a clone whose `mirror` remote points at `https://git.corp.example/mirrors/bosh-deployments.git` runs `git config genesis.remote mirror`. The pin lives in the clone's own `.git/config`, never globally, so it is never committed and never cloned. A `genesis.remote` set with `git config --global` is ignored with a warning, because it would pin every repository on the machine. The pin is read before the match and wins, and a pin naming a remote the clone does not have is refused rather than passed over. `genesis pipeline-describe` shows how the remote was found, `matched`, `pinned` or `derived`, and for a pin it names the clone's `.git/config` as where it lives. Remove the pin with `git config --unset genesis.remote`.

CI clones the repository by a URL composed from `repository` and `auth.type`: `git@<host>:<owner>/<repo>.git` for `ssh`, the default, and `https://<host>/<owner>/<repo>.git` for `https`. `uri` overrides it, for a host that cannot be reached that way.

## Top-Level Structure

```yaml
pipeline:
  name:           <string>       # Required
  vault:          <map>          # Required
  git:            <map>          # Required
  boshes:         <map>          # Required
  slack:          <map>          # At least one of slack or email required
  email:          <map>          # At least one of slack or email required
  layout:         <string>       # Required (or layouts)
  layouts:        <map>          # Required (or layout)
  task:           <map>          # Optional
  locker:         <map>          # Optional
  groups:         <map>          # Optional
  errands:        <list>         # Optional
  auto-update:    <map>          # Optional
  registry:       <map>          # Optional
  notifications:  <string>       # Optional
  public:         <boolean>      # Optional, default false
  tagged:         <boolean>      # Optional, default false
  unredacted:     <boolean>      # Optional, default false
  ocfp:           <boolean>      # Optional, default false
  debug:          <boolean>      # Optional, default false
  require-passed-caches: <bool>  # Optional
```

No other top-level keys are permitted under `pipeline`. The validator rejects unrecognized keys with an error message identifying the offending key.

## pipeline.name

A string that names the pipeline. This becomes the Concourse pipeline name when deployed via `fly set-pipeline`, and appears in notification messages. It is also used as the default Concourse group name when custom groups are not configured.

## pipeline.vault

Configures the Vault instance that the pipeline uses at runtime to retrieve secrets for deployments.

```yaml
vault:
  url:       https://vault.example.com           # Required
  role:      (( vault "secret/ci:role_id" ))      # AppRole role ID
  secret:    (( vault "secret/ci:secret_id" ))    # AppRole secret ID
  verify:    true                                 # TLS verification, default true
  no-strongbox: false                             # Skip strongbox init
  namespace: my-namespace                         # Vault enterprise namespace
```

The `url` field is the only strictly required field. The `role` and `secret` fields provide AppRole credentials that the pipeline uses to authenticate to Vault. These are typically spruce `(( vault ... ))` operators that get resolved when you run `genesis pipeline-apply` against a Vault you are already authenticated to.

When `verify` is set to false, the pipeline sets `VAULT_SKIP_VERIFY=true` in the environment of every task that communicates with Vault. The `namespace` field sets `VAULT_NAMESPACE` for Vault Enterprise deployments. The `no-strongbox` flag sets `VAULT_NO_STRONGBOX` to skip the Strongbox initialization that Genesis normally performs.

Allowed keys: `url`, `role`, `secret`, `verify`, `no-strongbox`, `namespace`.

## pipeline.git

Configures the Git repository that the pipeline monitors for changes and pushes deployment results back to.

```yaml
git:
  owner:       my-org                              # GitHub/GitLab org
  repo:        my-deployments                      # Repository name
  uri:         git@github.com:my-org/my-repo.git   # Alternative to owner/repo
  branch:      master                              # Branch to monitor, default master
  root:        .                                   # Subdirectory, default .
  private_key: (( vault "secret/ci:git_key" ))     # SSH auth
  username:    bot-user                             # HTTPS auth (alternative)
  password:    (( vault "secret/ci:git_pass" ))    # HTTPS auth (alternative)
  version_depth: 0                                 # Git clone depth
  commits:
    user_name:  Concourse Bot                      # Git commit author name
    user_email: concourse@pipeline                 # Git commit author email
```

Authentication is required and must be exactly one of two modes. You either provide `private_key` for SSH authentication, or `username` and `password` for HTTPS authentication. Specifying both is an error.

When using SSH authentication, you must also specify either `uri` or both `owner` and `repo`. The validator enforces this. When `owner` and `repo` are provided without `uri`, the system constructs the URI as `git@github.com:owner/repo.git`.

The `root` field is for monorepo setups where the Genesis deployment repository lives in a subdirectory. When set to something other than `.`, all Git resource paths are prefixed with this value, and the pipeline sets `GIT_GENESIS_ROOT` so Genesis knows where to find environment files.

The `commits` subsection controls the Git author identity used when the pipeline pushes state files and cache data back to the repository. If omitted, the defaults are "Concourse Bot" and "concourse@pipeline".

## pipeline.boshes

Defines the BOSH directors that the pipeline deploys to. Each key is the Genesis environment name (matching the environment YAML filename without the `.yml` extension). The keys in this map determine which environments the pipeline manages.

```yaml
boshes:
  sandbox:
    url:         https://10.0.0.1:25555
    ca_cert:     (( vault "secret/bosh/sandbox/ssl/ca:certificate" ))
    username:    admin
    password:    (( vault "secret/bosh/sandbox/admin:password" ))
    alias:       sandbox                     # Display name, defaults to key
    genesis_env: my-sandbox                  # Override Genesis env name

  proto:
    alias: proto-bosh
    # No url/ca_cert/username/password means this is a create-env deployment
```

For standard BOSH director deployments, all four connection fields (`url`, `ca_cert`, `username`, `password`) are required. The validator checks this and reports which fields are missing.

For create-env (proto-BOSH) deployments, you omit the connection fields entirely. The validator detects create-env environments by loading the environment via `Genesis::Top` and checking `use_create_env`. For create-env environments, only the `alias` field is allowed.

The `alias` field provides a human-friendly name used in Concourse job and resource names. If your environment is named `us-west-2-prod`, setting `alias: prod` makes the Concourse UI much more readable. The `genesis_env` field overrides the Genesis environment name passed to `genesis deploy` and is used with the `ocfp` flag for BOSH config naming.

Allowed keys: `url`, `ca_cert`, `username`, `password`, `alias`, `genesis_env`.

## pipeline.slack

Configures Slack notifications for pipeline events. At least one notification provider (slack or email) is required.

```yaml
slack:
  webhook: (( vault "secret/ci:slack_webhook" ))   # Required
  channel: "#deployments"                           # Required
  username: runwaybot                               # Default: runwaybot
  icon:    http://cl.ly/image/.../concourse-logo.png  # Bot avatar URL
```

The webhook and channel are required. The pipeline sends messages on deployment start (for non-auto environments), failure, and success.

Allowed keys: `webhook`, `channel`, `username`, `icon`.

## pipeline.email

Configures email notifications as an alternative or supplement to Slack.

```yaml
email:
  to:
    - ops-team@example.com
    - oncall@example.com
  from: concourse@example.com
  smtp:
    host:     smtp.example.com
    port:     587
    username: smtp-user
    password: (( vault "secret/ci:smtp_password" ))
```

The `to` field must be a list with at least one address. The `from` field and `smtp` section are both required. Within `smtp`, the `host`, `username`, and `password` fields are required. The `port` field is optional.

## pipeline.layout and pipeline.layouts

These define the deployment topology. You must specify exactly one of `layout` or `layouts`. Providing both is an error, and providing neither is also an error.

Use `layout` when you have a single pipeline topology:

```yaml
layout: |
  auto sandbox
  sandbox -> staging -> production
```

Use `layouts` when you need multiple named topologies in one pipeline (for example, separate progression chains for different regions):

```yaml
layouts:
  us-east:  |
    auto us-east-sandbox
    us-east-sandbox -> us-east-staging -> us-east-prod
  eu-west:  |
    auto eu-west-sandbox
    eu-west-sandbox -> eu-west-staging -> eu-west-prod
```

When using `layout`, the topology is internally named "default". When using `layouts`, each key becomes the name of a Concourse pipeline layout. You select which layout to deploy with the positional argument to `genesis pipeline-apply`:

```bash
genesis pipeline-apply us-east
```

See [Layout DSL](layout-dsl.md) for the full syntax.

## pipeline.task

Configures the Docker image used for pipeline tasks.

```yaml
task:
  image:      genesiscommunity/concourse   # Default
  version:    latest                        # Default
  privileged:                               # Environments needing privileged mode
    - proto
```

All pipeline tasks (deploy, cache generation, errands, show-changes) run in a Docker container. The `image` and `version` fields control which image is used. The `privileged` field is a list of environment aliases that require Concourse privileged task mode (typically create-env deployments that need raw disk access).

Allowed keys: `image`, `version`, `privileged`.

## pipeline.locker

Configures the Locker service for deployment locking. When configured, the pipeline acquires BOSH director locks and deployment locks before deploying, preventing concurrent deployments to the same director or environment.

```yaml
locker:
  url:                  https://locker.example.com   # Required
  username:             locker-user                   # Required
  password:             (( vault "secret/ci:locker")) # Required
  ca_cert:              (( vault "secret/locker:ca")) # Optional
  skip_ssl_validation:  true                          # Optional
```

When locker is configured, each deployment job acquires two locks: a BOSH director lock (keyed `dont-upgrade-bosh-on-me`) that prevents BOSH upgrades during deployment, and a deployment lock (keyed `i-need-to-deploy-myself`) that prevents concurrent deployments of the same environment. Both locks are released in an `ensure` block so they are freed even if the deployment fails.

Allowed keys: `url`, `username`, `password`, `ca_cert`, `skip_ssl_validation`.

## pipeline.groups

Defines custom Concourse pipeline groups. By default, all jobs are placed in a single group named after the pipeline. Custom groups let you organize jobs in the Concourse UI.

```yaml
groups:
  sandbox:
    - sandbox
  staging:
    - staging
  production:
    - production
```

Each key is a group name and each value is a list of environment names or aliases. The validator checks that every listed name corresponds to an actual BOSH environment defined in `boshes`.

## pipeline.errands

A list of BOSH errand names to run after each successful deployment. The errands run in sequence after the deploy task and before cache generation.

```yaml
errands:
  - smoke-tests
  - acceptance-tests
```

Errands are skipped for create-env deployments since proto-BOSH environments do not support errands.

## pipeline.auto-update

Configures automatic kit and Genesis binary updates. When configured, the pipeline creates an additional job called `update-genesis-assets` that monitors GitHub releases for new kit versions and Genesis CLI versions.

```yaml
auto-update:
  file:              base.yml                    # Required - kit version file
  kit:               bosh                        # Kit name
  org:               genesis-community           # GitHub org
  auth_token:        (( vault "secret/ci:gh"))   # GitHub token
  kit_auth_token:    (( vault "secret/ci:kit"))  # Kit-specific token
  github_auth_token: (( vault "secret/ci:gh"))   # Deprecated alias
  api_url:           https://github.example.com/api/v3  # GitHub Enterprise
  label:             concourse                   # CI label for commits
  period:            24h                         # Check interval
```

The `file` field is required and specifies which environment YAML file contains the `kit.version` that should be updated. The job fetches new kit releases, updates the version in the specified file, embeds the latest Genesis binary, and commits the changes back to the repository.

## pipeline.registry

Configures a private Docker registry for pulling task images.

```yaml
registry:
  uri:      registry.example.com
  username: docker-user
  password: (( vault "secret/ci:docker_pass" ))
```

When configured, the registry URI is prepended to all image references, and the credentials are added to all image source definitions.

## pipeline.notifications

Controls how notification jobs are organized in the pipeline. Valid values are `inline`, `parallel`, and `grouped`.

With `inline` (the default), notification jobs for non-auto environments appear in the same Concourse group as deployment jobs. With `grouped`, notification jobs are moved to a separate group called "notifications". The `parallel` option is also accepted.

## Boolean Flags

The following boolean flags default to false when not specified:

`public` controls whether the Concourse pipeline is publicly visible. When true, the pipeline is exposed via `fly expose-pipeline`. When false, it is hidden.

`tagged` adds Concourse tags to resources and tasks, using the environment name as the tag value. This is used with Concourse workers that have custom tags for routing work to specific infrastructure.

`unredacted` disables manifest redaction during deployment. When true, the pipeline sets `CI_NO_REDACT=1` so that full manifests appear in Concourse task logs. This is a security risk and should only be used for debugging.

`ocfp` enables OCF Platform naming conventions. When true, BOSH config resources use the `genesis_env` value (or the environment name) as the config name instead of the default value of `default`.

`debug` enables additional debug output in pipeline tasks by setting the `DEBUG` environment variable.

`require-passed-caches` changes how git resources are fetched in deployment jobs. When true, the deployment job fetches the git resource from the cache resource rather than from the main git resource with a `passed` constraint. This affects the Genesis binary path and source directory used during deployment.
