# BOSH Upgrade Locks

Genesis pipelines that manage a BOSH director alongside the deployments it hosts automatically wire a shared upgrade-lock to prevent a director upgrade from racing against a child deployment.

## Overview

When a child deployment's YAML file declares `genesis.bosh_env: <director-env>` and the named director is also present in the same pipeline, Genesis:

1. Emits one shared `<director-alias>-bosh-lock` Concourse resource for the director.
2. Each child's deploy (and redeploy) job acquires that shared lock before deploying, preventing the director from being upgraded while a child is in flight.
3. The director's own deploy job also acquires its shared lock, preventing a child from deploying while the director is being upgraded.

Locks are implemented with the `cfcommunity/locker-resource` via the OCF Locker service.

## Configuration

### Declaring the parent director

In each child deployment's YAML file:

```yaml
# cf-lab.yml
genesis:
  env: cf-lab
  bosh_env: bosh-lab     # name of the director env in this pipeline
```

`bosh_env` is read at pipeline-gen time. Genesis resolves the relationship only when the named director env is also included in the current pipeline — if the director lives in a separate, manually managed pipeline, the key is ignored and the child behaves as a standalone env.

### Locker integration (required)

BOSH upgrade locks require a locker integration. Add it to your `ci.yml`:

```yaml
integrations:
  locker:
    url:      https://locker.example.com
    username: ((locker-username))
    password: ((locker-password))
```

If a child env has a pipeline-managed BOSH director but no locker is configured, `genesis ci describe` will error early with instructions to either add the locker block or opt out with `bosh_upgrade_lock: false`.

### Opting out per environment

To disable the shared lock for a specific child — for example, a non-production env that does not need coordinated upgrades:

```yaml
# cf-lab.yml
genesis:
  env: cf-lab
  bosh_env: bosh-lab
  pipeline:
    locks:
      bosh_upgrade: false
```

An opted-out child falls back to standalone behaviour: its deploy job acquires a per-env `bosh-lock` resource scoped to its BOSH director URL, without coordinating with the director's own lock.

The `locks:` block is extensible — future lock types will be added as sibling keys under it.

## Lock topology

There are three cases based on a deployment's relationship to its BOSH director:

### Director

A deployment is a director when at least one other pipeline env declares it as its `bosh_env`.

- **Resource**: `<alias>-bosh-lock` using `lock_name: <alias>-bosh-upgrade`.  
  A named lock is used rather than a BOSH URL so the pattern works for `bosh-create-env` directors (which have no known URL at pipeline-gen time).
- **Deploy job**: acquires `<alias>-bosh-lock` (`dont-upgrade-bosh-on-me`), then `<alias>-deployment-lock` (`i-need-to-deploy-myself`).

### Child (bosh_parent set, bosh_upgrade_lock=true)

- **Resource**: no own `bosh-lock` resource — the director's shared resource is referenced directly.
- **Deploy job**: acquires `<director-alias>-bosh-lock` (`dont-upgrade-bosh-on-me`), then `<alias>-deployment-lock`.

### Standalone (no pipeline-managed parent)

The traditional behaviour for envs whose BOSH director is not in the same pipeline.

- **Resource**: `<alias>-bosh-lock` using `bosh_lock: <bosh-url>`.
- **Deploy job**: acquires `<alias>-bosh-lock`, then `<alias>-deployment-lock`.

## Lock keys

| Key | Purpose |
|-----|---------|
| `dont-upgrade-bosh-on-me` | Held by child deploys on the director's bosh-lock; blocks a director upgrade from starting while a child is deploying |
| `i-need-to-deploy-myself` | Held by each env's deploy on its own deployment-lock; serializes concurrent deploys of the same env |

Both keys are released unconditionally in the job's `ensure` block.

## Example: lab pipeline

```
bosh-lab  ──►  cf-lab
          ──►  shield
```

```yaml
# bosh-lab.yml
genesis:
  env: bosh-lab

# cf-lab.yml
genesis:
  env: cf-lab
  bosh_env: bosh-lab
  pipeline:
    prior_env: bosh-lab

# shield.yml
genesis:
  env: shield
  bosh_env: bosh-lab
  pipeline:
    prior_env: bosh-lab
```

Generated resources:

| Name | Lock type | Source |
|------|-----------|--------|
| `bosh-lab-bosh-lock` | shared director | `lock_name: bosh-lab-bosh-upgrade` |
| `bosh-lab-deployment-lock` | per-env deploy | `lock_name: bosh-lab-deployment` |
| `cf-lab-deployment-lock` | per-env deploy | `lock_name: cf-lab-deployment` |
| `shield-deployment-lock` | per-env deploy | `lock_name: shield-deployment` |

Both `cf-lab-deployment` and `shield-deployment` jobs lock `bosh-lab-bosh-lock` before deploying. The `bosh-lab-deployment` job also locks `bosh-lab-bosh-lock` — so an upgrade cannot proceed while any child is deploying, and children cannot deploy while an upgrade is running.

## Pipeline description annotation

The `genesis ci describe` output identifies directors with a `DIRECTOR` annotation in the Mermaid diagram node label:

```
bosh-lab([bosh-lab\nDIRECTOR]) --> cf-lab
bosh-lab([bosh-lab\nDIRECTOR]) --> shield
```

## Cross-pipeline directors

If the BOSH director is managed by a separate pipeline (not listed in `env_dir`), `bosh_env` is silently ignored and the env falls back to standalone lock behaviour. This means you can safely declare `bosh_env` in all child YAML files regardless of whether the director is co-located in the same pipeline.

## Debugging stuck locks

A stuck lock means a previous job acquired the lock and never released it — either because the Concourse job was killed at the OS level (not just aborted), the worker crashed, or a bug prevented the `ensure` block from running.

### Identifying the stuck lock

In Concourse, a failed `put` to a locker resource with `lock_op: lock` will show the key and `locked_by` value in the task output:

```
Lock 'dont-upgrade-bosh-on-me' is already held by 'cf-lab-deployment'
```

This tells you which key is stuck (`dont-upgrade-bosh-on-me`) and which job last acquired it (`cf-lab-deployment`).

### Releasing manually

Use the OCF Locker HTTP API to release a stuck key directly:

```bash
# List all locks on the resource
curl -u locker-user:locker-pass \
  https://locker.example.com/locks/<lock-name>

# Force-release a specific key
curl -u locker-user:locker-pass -X DELETE \
  https://locker.example.com/locks/<lock-name>/<key>
```

For BOSH upgrade locks:
- `<lock-name>` is `<director-alias>-bosh-upgrade` (the `lock_name` from the resource source)
- `<key>` is `dont-upgrade-bosh-on-me`

For deployment locks:
- `<lock-name>` is `<env>-deployment`
- `<key>` is `i-need-to-deploy-myself`

### Preventing recurrence

If a Concourse worker crashes repeatedly without releasing locks, consider:
- Increasing the Concourse worker `drain_timeout` so the worker has time to run `ensure` blocks on shutdown
- Adding an alert on the locker service when a key is held longer than the expected maximum deploy duration
