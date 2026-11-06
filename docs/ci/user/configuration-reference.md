# Configuration Reference

A v3 repository configures its pipeline in two places:

- **The repository's own settings** live in `.genesis/config`, under the `pipeline` key.
- **Each environment's settings** live in that environment's own file, under `genesis.pipeline`.

The schema is the contract. Every key a command reads is declared, and validation runs at configuration load for every command. A key the schema does not declare is refused by name rather than aliased. A retired key is refused naming what replaced it.

`.genesis/config` is generated. Change it with `genesis config --set <key> <value>` and `genesis config --unset <key>`, never by hand. That command validates the result it would write, and refuses to write one that does not load.

A repository that still carries a pipeline `ci.yml` has not moved to v3, and every pipeline command refuses it. Each `ci.yml` setting's v3 home, and the order of the move, are in the operator's migration guide, *Pipeline Migration: v2 to v3*.

## Per-environment `genesis.pipeline` keys

| Key | What it does |
|-----|--------------|
| `prior_env` | Names the environment this one follows. A change waits until that environment has deployed it, and the deploy is chained after that environment's. An environment with no `prior_env` takes control's commits without waiting on another |
| `require_pr` | Delivers to this environment through a pull request, from `<pr_prefix><env>/<type>` into the deployment branch. A reviewer approves and merges it. `genesis pipeline-apply` also requires a pull request on that branch |
| `manual` | The environment's deploy waits for a person to start it, as the section below states |
| `provider.tag` | The worker tag, or a list of tags, whose workers reach this environment's network. It goes on the steps that need that network: the environment's deploy, redeploy and notify tasks, and its director's BOSH config checks. Concourse only |
| `redeploy_cron` | One crontab string, or a list of them, in UTC. Accepted, but no schedule is emitted yet |
| `track_dependencies` | The deployments this one reads, declared so that the applied record and the staleness check know about them. No trigger is emitted yet |
| `track_bosh_configs` | Whether, or which, of the director's BOSH configs a Classic environment watches: `true` for cloud and runtime, or a list of `cloud`, `runtime` and `cpi`. A change notifies through the director's `notify-<bosh_env>-bosh-configs` job and triggers nothing. The key is refused on an OCFP environment, and `genesis pipeline-apply` copies the director's credentials for the check. See [BOSH config tracking](../../workflows/bosh-config-tracking.md) |
| `track_additional_files` | Extra paths for this environment's propagation set, relative to the deployment root, with `<env>` substitution and globs. It replaces `required_files` |
| `notifications` | Refused at load. Notifications are the repository's settings, in `pipeline.notifications` of `.genesis/config` |

The block is read merged, so a key written in a site file is inherited by every environment beneath it. A key written in the environment's own file wins over the one it inherits. Every key here shapes the pipeline, so each must resolve from the environment's own files: a `(( vault ))` value, a credhub variable, or a reference those files do not resolve is refused, naming the file that sets it.

The environment's director is `genesis.bosh_env`, outside the block, as for a deploy by hand. It also names the director's lock pool, `<bosh_env>-bosh`.

These keys are retired and refused, each naming its replacement: `locks`, `status_signal`, `signal_prefix`, `required_files`, `redeploy`, `redeploy_cron_start` and `redeploy_cron_stop`.

### `manual`

An environment deploys automatically unless it sets `manual: true`. Its deploy job then takes `trigger: false` on its deployment branch's `get`: the pipeline fetches each delivery and waits for a person to start the job. Where Slack is configured, its notify job posts what deploying the delivery would change. The Mermaid graph labels the environment `MANUAL`, and `genesis pipeline-status` reads the key.

An environment whose deploy waits for a person certifies nothing until that person acts, so the environments after it stay held meanwhile. `genesis pipeline-status` prints the reason as `awaiting its trigger` beside the environment that holds them.

The key is valid only where the provider emits a triggering resource, because a key about triggering says nothing where the provider emits no trigger at all. That ability has a name, `optional_git_triggers`, and every provider declares whether it has it:

- **Concourse** declares it true.
- **The manual provider** declares all six of its abilities false, because `genesis pipeline-apply` sets no pipeline at all under it. Nothing fetches, nothing triggers, and there is no `get` for the key to sit on, so an operator runs `genesis <env> deploy` by hand instead.
- **GitHub Actions** declares it false as well, until the class that emits for it is written.

Where the ability is absent the key is refused at configuration load, by name, and the refusal names the key, the provider, and the capability together. Writing `genesis.pipeline.manual` in an environment file of a repository that has its pipeline enabled and sits on the manual provider therefore fails every command, not only the pipeline ones. A key that cannot mean anything is better said out loud than accepted and dropped when the pipeline is emitted. A repository whose `pipeline.enabled` is false is not validated at all, so it carries the key with no refusal.

## The `pipeline` section of `.genesis/config`

```yaml
pipeline:
  enabled:   true                  # false by default; set it last
  name:      bosh                  # defaults to deployment_type
  provider:
    type:    concourse             # or manual (the default)
    url:     https://ci.example.com
    team:    platform
    # ... the provider's own keys, below
  source_control: { ... }
  vault:          { ... }
  locker:         { ... }
  shuttle:        { ... }
  notifications:  { ... }          # optional
  registry:       { ... }          # optional
  redeploy:       { ... }          # optional
  exodus_mount:       /secret/exodus/
  recreate_on_deploy: never
  unredacted:         false
```

`source_control`, `vault`, `locker` and `shuttle` are required wherever the provider sets a pipeline, which today is Concourse.

Every credential is named by a vault reference and never written in the file. The compiled pipeline turns each into a Concourse variable, `((path.key))`, which Concourse resolves from its own vault when a build runs. A *credential block* (`source_control.auth`, `vault.auth`, `registry.auth`) names a `type` and a `path`. Each component is then read from that path under its own name, or from its own `<path>:<key>` where it is stored under another name:

```yaml
auth:
  type:    approle
  path:    vault/approle             # role_id and secret_id, under those names
  role_id: vault/approle:approle_id  # or one component from elsewhere
```

### `pipeline.name`

The pipeline's name in its provider, which defaults to `deployment_type`. It is the Concourse pipeline `fly set-pipeline` sets, and the name of the deployments' group. Under Concourse it is also the pipeline scope of the secrets store. A pipeline must not take the name of a v2 pipeline that is still set, or the apply would overwrite it.

### `pipeline.provider`

`type` picks the provider: `manual` (the default), which sets no pipeline, or `concourse`. The Concourse provider's keys:

| Key | What it does |
|-----|--------------|
| `url`, `team` | The Concourse URL and team. Required. Each operator's own fly target is found by these, or given with `--target`; `target` is retired |
| `insecure` | Skip TLS verification with fly |
| `public` | Make every job's build log public. False by default |
| `task.image`, `task.version` | The image every task runs in, by default `genesiscommunity/concourse:latest`. It needs git 2.34.1 or later. An image named here is taken as written, host included |
| `task.privileged` | Environments whose deploy task runs privileged, such as a create-env director |
| `git.webhooks` | `true` puts a webhook token on every git resource, has propagate ask Concourse to check each branch it pushes, and has `genesis pipeline-apply` keep the token and a GitHub push hook. False by default |
| `git.check_every`, `git.control_check_every` | How often the deployment branches, and control, are polled: a Concourse duration (`30s`, `5m`, `1h`) or `never`. Concourse's default, 1m, where unset. With webhooks on, `1h` for the deployment branches keeps GitHub's traffic low |
| `secrets_store` | The vault Concourse resolves the pipeline's references from, where it is not the repository's own: `url`, `namespace`, `path_prefix` (default `/concourse`), `shared_path` (where Concourse has one configured) and `insecure`. Unset, the store is the repository's vault under `/concourse` |
| `pause_after_set` | Leave the pipeline paused after it is set. `genesis pipeline-apply --paused` does the same for one run |
| `min_fly_version`, `fly_bin_path` | The lowest fly the pipeline may be set with, and which fly to run; `GENESIS_FLY_BIN` overrides the latter |
| `group_commits` | Deploy the tip of what arrived rather than each commit in turn. Only `true` is supported, and `false` is refused |

`tagged` is retired: each environment names its own workers with `genesis.pipeline.provider.tag`.

## pipeline.source_control

Says which repository the pipeline lives in and how CI reaches it. The block is read from the working tree's own `.genesis/config` rather than from control, because it says where control is, so it has to be known before control can be read.

```yaml
pipeline:
  source_control:
    repository: team/bosh-deployments
    # or, as its URL, on any host:
    #   repository: https://git.example.com/team/bosh-deployments.git
    #   repository: git@git.example.com:team/bosh-deployments.git
    pr_prefix:      pr/
    auth:
      type: ssh            # or https
      path: git            # private_key, or username and password
    api_token: github:token
    identity:
      name:  Genesis CI
      email: ci@example.com
```

`repository` names the repository, written as `owner/repo`, which means github.com, or as the repository's https or ssh URL, which carries its own host. Every form names one repository, so they are interchangeable. It can be left out where the clone's remotes leave no doubt which repository they point at.

`auth` is the clone credential every task clones and pushes with: an SSH deploy key with write access, read as `((<path>.private_key))`, or an HTTPS username and token, read as `((<path>.username))` and `((<path>.password))`. Use the repository's automation account, not a person's. `auth.vault` is retired, and refused naming `path`.

`api_token` is the `path:key` of the GitHub token propagate opens pull requests with. It is needed wherever an environment sets `require_pr` and the clone credential is SSH, because GitHub's API takes no SSH key; with HTTPS auth the clone credential's password serves. It must belong to an automation account, because GitHub does not let a pull request's author approve it.

`identity` is the name and email every pipeline task commits under. It is required; there is no default.

`control_branch` is `control`, and a different name is a break-glass setting only. `control_requires_pr` makes `genesis pipeline-apply` require a pull request on control too. `pr_prefix`, `pr/` by default, prefixes each pull request branch.

A `genesis propagate` with an environment that sets `require_pr` needs `GITHUB_AUTH_TOKEN`, because what a reviewer decided is what decides whether that environment's pull request branch is rebuilt or left alone. Without it the run refuses before writing anything, naming the variable and those environments. `--dry-run` still runs, and says that a real run would refuse.

Pull requests and branch protection are GitHub's API, and they are called on the repository's own host: `https://api.github.com` for github.com, and `https://<host>/api/v3`, GitHub Enterprise Server's API, for any other host.

Nothing is asked only to find out whether a host is GitHub. The answers to those calls say it, by the `X-GitHub-Request-Id` and `X-GitHub-Media-Type` headers GitHub puts on every answer. A host other than github.com is remembered in `~/.genesis/cache/github-hosts.yml`, with the GitHub Enterprise Server version it answered with. A host that answers without those headers is asked once more, and then refused, naming the host, the address asked and what came back.

Only a command that calls the API meets that refusal:

- `genesis pipeline-apply` with a token;
- a `genesis propagate` that opens a pull request;
- the pull request column of `genesis pipeline-status`, which says the host is not GitHub and goes on.

A repository on another kind of host still loads, and runs every command that calls no API. That means no environment setting `require_pr`, and `GITHUB_AUTH_TOKEN` unset where `genesis pipeline-apply` runs, which then skips the branch protection and says so.

The remote is not configured. A remote's name and its protocol are each cloner's own choice, made when they clone and before `.genesis/config` is there to read. So the remote Genesis reads, refreshes and publishes through is whichever of the clone's remotes points at the repository, under any name and any protocol:

- A clone with one remote uses it, unless its URL names a different repository.
- Where two remotes point at the repository, the one the control branch tracks is used.
- Where the remotes point at more than one repository and `repository` is unset, as with a fork beside the original, the configuration load refuses rather than guess, because a clone of a fork tracks the fork.

`pipeline.source_control.remote` is no longer read, and a configuration that still sets it is refused, naming what replaces it.

A remote whose URL cannot be matched to the repository, such as an internal mirror on another host, is pinned instead:

```
git config genesis.remote <remote>
```

For example, a clone whose `mirror` remote points at `https://git.corp.example/mirrors/bosh-deployments.git` runs `git config genesis.remote mirror`. The pin lives in the clone's own `.git/config`, never globally, so it is never committed and never cloned. A `genesis.remote` set with `git config --global` is ignored with a warning, because it would pin every repository on the machine.

The pin is read before the match and wins, and a pin naming a remote the clone does not have is refused rather than passed over. `genesis pipeline-describe` shows how the remote was found, `matched`, `pinned` or `derived`, and for a pin it names the clone's `.git/config` as where it lives. Remove the pin with `git config --unset genesis.remote`.

CI clones the repository by a URL composed from `repository` and `auth.type`: `git@<host>:<owner>/<repo>.git` for `ssh`, the default, and `https://<host>/<owner>/<repo>.git` for `https`. `uri` overrides it, for a host that cannot be reached that way.

## pipeline.vault

The deployment vault every pipeline task logs in to, to read secrets, generate missing ones, and write exodus.

```yaml
vault:
  url:       https://vault.example.com
  namespace: my-namespace          # Vault Enterprise only
  auth:
    type: approle                  # or token
    path: vault/approle            # role_id and secret_id
  options:
    tls_verify:   true
    no_strongbox: false
```

The AppRole's policy and where its credentials are stored are in the operator's guide, *Pipeline Accounts and Permissions*.

## pipeline.locker

The locker behind the deploy locks. Locks are mandatory: every deploy and redeploy holds its own deployment's pool with `i-need-to-deploy-myself`, and a director's deploy holds that director's pool with `dont-upgrade-bosh-on-me`.

```yaml
locker:
  url:      https://locker.example.com
  username: locker
  password: ((locker/api.password))   # written in Concourse's own form
  ca_cert:  ((locker/api.ca_cert))
  skip_ssl_validation: false
```

## pipeline.shuttle

The object store behind each deployment's events and redeploy queue. `s3` is the one backend.

```yaml
shuttle:
  backend:  s3
  bucket:   genesis-pipelines
  region:   us-east-1
  endpoint: https://s3.example.com    # a non-AWS endpoint
  auth:     shuttle                   # access_key_id and secret_access_key, under those names
  tls_skip_verify: false
```

Each deployment `<env>-<type>` has three paths in the bucket: `<env>-<type>/deployed` and `<env>-<type>/redeployed`, the events its deploy and redeploy write, and `<env>-<type>/redeploy`, the queue its redeploy job takes requests from. A tool outside the pipeline asks for a redeploy by writing to that queue. `image` and `image_tag` choose the resource's image.

## pipeline.notifications

```yaml
notifications:
  style: inline                     # inline, parallel or grouped
  slack:
    webhook: slack:webhook          # path:key of the webhook URL
    channel: "#deployments"         # a legacy webhook only
    username: genesis               # a legacy webhook only
    icon: https://example.com/genesis.png
    mentions_on_failure: ["@oncall"]
```

`style` decides where a manual environment's notify job sits:

- **`inline`**, the default: its deploy offers only versions the notify job has seen.
- **`parallel`**: they stand side by side.
- **`grouped`**: the notify jobs move to a `notifications` group.

A Slack app's webhook fixes its channel, name and icon, so `channel`, `username` and `icon` are honoured only by a legacy webhook. Every message begins with an emoji naming its kind and links to its build. `email` is accepted and not emitted.

## pipeline.registry

The registry every image Genesis names by default is pulled through: each resource type's image, the default task image, and the default shuttle image.

```yaml
registry:
  uri: registry.example.com/dockerhub-mirror
  auth:
    type: basic
    path: registry                  # username and password
```

An image named in the configuration, `provider.task.image` or `shuttle.image`, is taken as written. It carries the registry's credentials only where it begins with the registry's host.

## pipeline.redeploy

```yaml
redeploy:
  enabled: true       # each environment's redeploy-<env> job, queue and event
  style:   inline     # beside each deploy, or grouped in one redeploys group
```

A redeploy runs `genesis <env> deploy --redeploy` against what the environment last deployed, on request: its button, or a request on its queue. With `enabled: false` there are no redeploy jobs, and an environment's `redeploy_cron` is refused.

## Other keys

| Key | What it does |
|-----|--------------|
| `exodus_mount` | The vault mount every pipeline record lives under, `/secret/exodus/` by default. Every environment's `genesis.exodus_mount` must resolve to it |
| `recreate_on_deploy` | `never` (the default), `redeploy-only` or `always`: which runs pass `--recreate` to BOSH. A deploy reads it itself, so it takes effect without an apply |
| `unredacted` | Print each deploy's manifest diff unredacted, as `CI_NO_REDACT`. A security risk; use it only to debug |
