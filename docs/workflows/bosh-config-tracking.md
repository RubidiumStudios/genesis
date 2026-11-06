# BOSH Config Tracking

A Classic environment renders against configs someone else uploads to its
director: the cloud config, the runtime configs, the CPI config.  When one of
them changes, the environment needs a redeploy to pick it up.  A pipeline can
watch the director for those changes and say so in Slack.

Tracking is opt-in and off by default.  For now it notifies and nothing more;
no deploy or redeploy is triggered (see [Why it only notifies](#why-it-only-notifies)).

An OCFP environment generates its own named configs and uploads them as part
of its deploy, so there is nothing to watch, and the key is refused there (see
[OCFP environments](#ocfp-environments)).

---

## Configuration

Set `genesis.pipeline.track_bosh_configs` in an environment file, or in a
site file every environment beneath it inherits:

```yaml
# us-east-1-prod.yml
genesis:
  bosh_env: us-east-1-mgmt          # the director this environment deploys to
  pipeline:
    track_bosh_configs: true        # cloud and runtime
    # or exactly the types to watch:
    track_bosh_configs: [cloud, runtime, cpi]
```

| Value | Types tracked |
|-------|---------------|
| `true` | `cloud`, `runtime` |
| `false`, or unset | none |
| a list of `cloud`, `runtime`, `cpi` | those |

The director is the environment's `genesis.bosh_env`, or the environment
itself where it names none.  A create-env environment has no director to
watch, and tracks nothing.

---

## What the pipeline gets

The configs belong to the director, not to the environment, and every
environment on a director renders against the same ones.  So the pipeline
watches each director once per config type, however many environments on it
track that type.

### One check per director and type

Each is a `bosh-config` resource named `<bosh_env>-bosh-<type>-config`, with
`all: true` so that every named config of the type is covered:

```yaml
- name: us-east-1-mgmt-bosh-cloud-config
  type: bosh-config
  icon: cloud
  source:
    target:        ((bosh/us-east-1-mgmt.url))
    ca_cert:       ((bosh/us-east-1-mgmt.ca_cert))
    client:        ((bosh/us-east-1-mgmt.client))
    client_secret: ((bosh/us-east-1-mgmt.client_secret))
    config:        cloud
    all:           true
```

The icons are `cloud`, `run-fast` and `chip` for the cloud, runtime and CPI
checks.

### One notify job per director

`notify-<bosh_env>-bosh-configs` gets every check on its director with
`trigger: true`, and sends one Slack message naming the director, each config
type watched with the environments that render against it, and a link to the
build, whose inputs show which one changed.  Without Slack the job still
runs, so the change is visible in Concourse.

No `deploy-` or `redeploy-` job gets a check.

The job sits in the deployments' group, or in `notifications` where
`pipeline.notifications.style` is `grouped`.

### Worker tags

A check reaches the director, so it runs on the workers that can: the
`genesis.pipeline.provider.tag` of the environments tracking it, which goes on
the resource and on the job's gets.  Those environments must agree on the tag,
since one check serves them all, and the compile refuses where they do not,
naming each environment and its tag.

---

## The director's credentials

The check reads the director with four references under one name,
`bosh/<bosh_env>`: `url`, `ca_cert`, `client` and `client_secret`.

`genesis pipeline-apply` writes them itself.  For each director an
environment tracks, it reads the director's exodus record from the
environment's vault, where the environment's own deploy finds it, and copies
the record's `url`, `ca_cert`, `admin_username` and `admin_password` as
`url`, `ca_cert`, `client` and `client_secret` to
`<path_prefix>/<team>/<pipeline>/bosh/<bosh_env>` in the secrets store.  That
is the pipeline scope, which Concourse reads first, so the copy is used even
where someone has published the director's credentials at the team scope or
the shared path.  The copy is the admin client because the record holds no
other; it adds no exposure, since the pipeline's AppRole can already read the
record.

The apply writes only where a value differs, and reports each director as
copied, updated or in place, never printing a value; a dry run says what it
would copy.  So when the director's client rotates, the next apply brings the
copy up to date.  It needs write access to that scope of the store.

Where the record can't be read (no record, a key missing, or its vault out of
reach), the director is reported not copied with the reason.  The secret check
that follows then finds the four references missing and refuses the apply,
naming the paths Concourse reads, unless given `--missing-secrets-ok`.  With
`--skip-vault` nothing is read or written.

A copy is not removed when no environment tracks its director any more.

---

## Why it only notifies

A new check's first version fires its trigger, so the first apply, and every
rename or recreation of the resource, would redeploy every environment on the
director at once.  And a redeploy cannot yet tell whether a change touches it.
The trigger moves to each environment's redeploy once the deploy records the
configs it rendered against, so that a redeploy can compare.

The first check after an apply sends one notice, which is harmless.

---

## OCFP environments

An environment whose merged `kit.features` include `ocfp`, with
`genesis.manage-cloud-configs` not false, generates and uploads its own named
configs as part of its deploy.  Setting `track_bosh_configs` there is refused
at load, naming the key, the environment and the file that sets it.  Where an
OCFP environment's configs are uploaded by someone else, set
`genesis.manage-cloud-configs: false` and it tracks them as a Classic one does.

A Classic and an OCFP environment may share a director; only the Classic one's
key makes a check.

---

## Legacy `ci.yml`

A legacy `ci.yml`'s `configuration.track_bosh_configs` is still read as the
default for every environment, and gives the same per-director checks.  Its
`tagged: true` names each environment's workers after it, so two environments
tracking one director under it disagree on the tag and are refused; give them
a shared `genesis.pipeline.provider.tag` instead.
