# BOSH Config Drift Tracking

Genesis pipelines can watch a BOSH director's cloud-config, runtime-config, and
CPI-config for out-of-band changes.  When a config changes on the director,
Concourse detects it through a `bosh-config` resource and re-triggers the
associated jobs so operators are alerted (or so a pending-changes summary is
regenerated).

Tracking is **opt-in** and defaults to off.  Pipelines that do not need drift
detection produce no extra resources or job steps.

---

## Configuration

### Global default

```yaml
configuration:
  track_bosh_configs: true          # cloud + runtime for every env
  # or a subset:
  track_bosh_configs: [cloud, runtime, cpi]
```

Accepted values:

| Value | Types tracked |
|-------|--------------|
| `true` / `yes` / `1` | `cloud`, `runtime` |
| `false` / `no` / `0` | none (off) |
| `[cloud]` | cloud-config only |
| `[runtime]` | runtime-config only |
| `[cpi]` | CPI-config only |
| `[cloud, runtime, cpi]` | all three |

### Per-environment override

Set `genesis.pipeline.track_bosh_configs` in an env YAML file to override the
global default for that environment:

```yaml
# prod.yml
genesis:
  pipeline:
    track_bosh_configs: cloud,runtime,cpi   # comma-separated types
    # or:
    track_bosh_configs: false               # suppress tracking for this env
```

The per-env value shadows the global `configuration.track_bosh_configs` for
that env only.  Other envs continue to use the global setting.

---

## Emitted resources

For each configured type and each environment, one `bosh-config` resource is
emitted named `<alias>-<type>-config`:

| Type | Resource name | Icon |
|------|--------------|------|
| `cloud` | `<alias>-cloud-config` | `cloud` |
| `runtime` | `<alias>-runtime-config` | `run-fast` |
| `cpi` | `<alias>-cpi-config` | `chip` |

Example for a `sandbox` environment with `track_bosh_configs: true`:

```yaml
- name: sandbox-cloud-config
  type: bosh-config
  icon: cloud
  source:
    target:        https://sandbox.bosh.example.com:25555
    client:        admin
    client_secret: ((bosh-admin-secret))
    ca_cert:       ((bosh-ca-cert))
    config:        cloud
    all:           true

- name: sandbox-runtime-config
  type: bosh-config
  icon: run-fast
  source:
    target:        https://sandbox.bosh.example.com:25555
    client:        admin
    client_secret: ((bosh-admin-secret))
    ca_cert:       ((bosh-ca-cert))
    config:        runtime
    all:           true
```

The source fields are derived automatically from the env's `targets:` entry —
no manual configuration of BOSH credentials is required.

---

## How it affects jobs

### Notify job (`notify-<alias>-deployment-changes`)

When bosh-config tracking is enabled, the notify job gains a triggering `get:`
for each tracked type.  This means a config change on the director automatically
causes Concourse to run `ci-show-changes` and report the pending diff — even if
no Git changes are staged.

```yaml
- get: sandbox-cloud-config
  trigger: true
- get: sandbox-runtime-config
  trigger: true
```

### Auto-trigger deploy job (`<alias>-deployment`)

When `auto: true` is set on an environment and bosh-config tracking is enabled,
the deploy job also gets a triggering get for each type.  A config change will
kick off the full deployment automatically.

```yaml
- get: sandbox-cloud-config
  trigger: true
- get: sandbox-runtime-config
  trigger: true
```

### Redeploy job (`<alias>-redeploy`)

Redeploy jobs include a non-triggering `get:` for each tracked config type so
the task container has the latest config snapshot available.  These do not
trigger the job on their own.

---

## Examples

### All environments: cloud + runtime

```yaml
configuration:
  track_bosh_configs: true
```

### Only the production environment tracks all three types

```yaml
configuration:
  track_bosh_configs: [cloud, runtime]   # global: cloud + runtime

# prod.yml
genesis:
  pipeline:
    track_bosh_configs: cloud,runtime,cpi  # prod adds cpi
```

### Opt a specific environment out of global tracking

```yaml
configuration:
  track_bosh_configs: true   # all envs by default

# sandbox.yml
genesis:
  pipeline:
    track_bosh_configs: false  # sandbox is too noisy, skip it
```

### Track only CPI-config globally

```yaml
configuration:
  track_bosh_configs: [cpi]
```

---

## BOSH config resource type

The `bosh-config` resource type is provided by
`cfcommunity/bosh-config-resource`.  It is automatically declared as a resource
type in the pipeline when any `bosh-config` resource is emitted — no manual
`resource_types:` entry is needed.

The `all: true` flag in the source causes the resource to track **all named
configs** of the given type (cloud, runtime, or cpi) rather than a single
named config.  This is the correct setting for monitoring the complete director
state.

---

## OCFP mode

When `configuration.ocfp: true` is set, each `bosh-config` resource source also
includes a `name:` field set to the environment's full genesis env name (e.g.
`us-west-1-sandbox`).  This narrows tracking to the specific named config used
by that environment rather than all configs on the director.

---

## Workaround: manual resource declaration

If fine-grained control is needed beyond what the built-in tracking supports
(for example, watching a specific named config rather than `all: true`), declare
the resource manually via the `ci.yml` pass-through and omit
`track_bosh_configs` for that environment.  The pass-through resource will be
merged into the generated pipeline by the Concourse provider.
