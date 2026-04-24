# Deployment Status Signals

Genesis pipelines can emit structured deployment status events — success, failure, abort, and error — through a generic signal abstraction backed by the `cfcommunity/shuttle-resource` Concourse custom resource type.

## Overview

When `status_signal` is configured, every deploy and redeploy job in the pipeline emits a Concourse put step for each of its four outcome hooks (`on_success`, `on_failure`, `on_abort`, `on_error`). External consumers — other pipelines, automation, dashboards — can get these signals to gate work on upstream deployment outcomes.

The signal resource for each environment is named `<env>-signal`. The shuttle resource writes a small status record to a backing store (S3, GCS, or local file), which Concourse polls as a versioned resource.

## Configuration

### Global configuration

Set `status_signal` in the `configuration:` block of your `ci.yml`:

```yaml
configuration:
  status_signal:
    backend: s3
    bucket:            genesis-signals
    region:            us-east-1
    access_key_id:     ((aws-access-key-id))
    secret_access_key: ((aws-secret-access-key))
```

This applies to every environment in the pipeline unless overridden or disabled per-env.

### Backends

**`file`** — Writes signal records to the Concourse worker filesystem. Useful for local testing or single-worker setups.

```yaml
status_signal:
  backend: file
  path: /tmp/genesis-signals    # defaults to /tmp/genesis-signals
```

**`s3`** — Writes to an S3 bucket. Suitable for multi-worker pipelines and cross-pipeline consumers.

```yaml
status_signal:
  backend: s3
  bucket:            genesis-signals
  region:            us-east-1
  access_key_id:     ((aws-access-key-id))
  secret_access_key: ((aws-secret-access-key))
  endpoint:          https://s3.example.com   # optional, for S3-compatible stores
```

**`gcs`** — Writes to a Google Cloud Storage bucket.

```yaml
status_signal:
  backend: gcs
  bucket:   genesis-signals
  json_key: ((gcs-service-account-json))
```

### Optional global keys

| Key | Default | Description |
|-----|---------|-------------|
| `prefix` | *(empty)* | Prepended to the per-env prefix: `<prefix>/<env>`. If unset, prefix is just the env name. |
| `image` | `cfcommunity/shuttle-resource` | Override the shuttle resource Docker image. |
| `image_tag` | `latest` | Override the image tag. |

### Per-environment overrides

In each environment's YAML file under `genesis.pipeline`:

```yaml
# sandbox.yml
genesis:
  env: sandbox
  pipeline:
    status_signal: s3           # override backend for this env only
    signal_prefix: acme/sandbox # override prefix for this env
```

To disable signals for a specific environment:

```yaml
genesis:
  env: prod
  pipeline:
    status_signal: false
```

| Value | Meaning |
|-------|---------|
| *(absent)* | Uses global config |
| `file`, `s3`, `gcs` | Enables signals, overrides backend |
| `true` / `1` | Enables signals, uses global backend |
| `false` / `no` / `0` | Disables signals for this env |

## Signal resource prefix

The per-environment signal resource stores records under a prefix path. The effective prefix is resolved as follows:

1. `signal_prefix` in the env's YAML — used verbatim
2. Global `prefix` + `/` + env name (e.g., `mypipeline/sandbox`)
3. Just the env name if no global prefix is set

## Outcome hooks

Each deploy and redeploy job emits a put step to `<alias>-signal` for all four Concourse outcome hooks:

| Hook | Signal `status` |
|------|----------------|
| `on_success` | `success` |
| `on_failure` | `failure` |
| `on_abort` | `abort` |
| `on_error` | `error` |

The put params are:

```yaml
put: sandbox-signal
params:
  status: success
  deployment: sandbox-deployment
```

When Slack/email notifications are also configured, the `on_success` and `on_failure` hooks combine both steps in an `in_parallel` block. The `on_abort` and `on_error` hooks emit the signal put directly (no notification for abort/error).

## Cross-pipeline gating

A downstream pipeline can gate on upstream deploy success by getting the signal resource:

```yaml
resources:
  - name: sandbox-signal
    type: shuttle
    source:
      backend: s3
      bucket: genesis-signals
      region: us-east-1
      access_key_id:     ((aws-access-key-id))
      secret_access_key: ((aws-secret-access-key))
      prefix: sandbox

jobs:
  - name: integration-tests
    plan:
      - get: sandbox-signal
        trigger: true
        version: { status: success }
      - task: run-tests
        ...
```

## Redeploy signal trigger

When an environment has `redeploy: signal` set, the `redeploy-<env>` job automatically triggers off the signal resource instead of running manually:

```yaml
genesis:
  env: prod
  pipeline:
    redeploy: signal
    status_signal: s3
```

This creates a `get: prod-signal, trigger: true, version: {status: success}` step at the top of the redeploy job plan. The redeploy fires whenever a successful deployment signal arrives for that env — useful for chaining a post-deploy health-check or forcing a redeploy after upstream changes.

If `redeploy: signal` is set but no global `status_signal` is configured, the job falls back to manual trigger behaviour (no auto-trigger resource is wired).

## Pipeline description annotation

The `genesis ci describe` output annotates each environment with its active features:

```
Pipeline: cf
Workflow: cf
  sandbox              sandbox-deployment  [auto]  [REDEPLOY:CRON, SIGNAL:s3]
  preprod              preprod-deployment  [manual] (triggered by sandbox)  [SIGNAL:s3]
  prod                 prod-deployment     [manual] (triggered by preprod)  [REDEPLOY:SIGNAL, SIGNAL:s3]
```
