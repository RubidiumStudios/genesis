# Pipeline Propagation

Genesis propagates environment configuration through a controlled branch topology where each environment's files live on their own git branch. The `genesis propagate` command advances those branches when the upstream `control` branch changes.

## Overview

The pipeline uses a control branch (commonly `main` or `control`) where all shared and per-environment files are committed. `genesis propagate` walks the topology and, for each environment, commits only the files relevant to that environment onto the environment's own branch. Concourse monitors those per-env branches and triggers deployments when they change.

## Branch Topology

Each environment has a corresponding git branch (e.g., `sandbox`, `preprod`, `prod`). The `genesis.pipeline.prior_env` key in each environment YAML file defines the propagation order:

```yaml
# prod.yml
genesis:
  env: prod
  pipeline:
    prior_env: preprod
```

This makes `preprod` the upstream of `prod` — Concourse deploys `preprod` first, then triggers `prod`.

## PR-Based Propagation

For environments that require review before deployment, set `require_pr: true`:

```yaml
# prod.yml
genesis:
  env: prod
  pipeline:
    prior_env: preprod
    require_pr: true
```

When `require_pr` is set, `genesis propagate` creates a `propagate/<env>/<control-sha>` branch instead of pushing directly to the env branch, then opens (or updates) a GitHub Pull Request for review. Merging the PR is what triggers the Concourse deploy.

### Idempotency

Re-running `genesis propagate` with the same control SHA updates the existing PR rather than creating a new one. The check uses the GitHub API to find an open PR with the matching head branch — this works across machines and CI runs.

### Propagation Flags

| Flag | Behavior |
|------|----------|
| `--dry-run` | Shows what would happen; no remote changes |
| `--no-push` | Commits locally but does not push or open PRs |

### GitHub Credentials

PR creation requires a GitHub token with `repo` scope. Set `GITHUB_AUTH_TOKEN` in the environment. The token is validated before any git operations begin.

## Redeploy Lane

The redeploy lane lets you force-redeploy an environment without any content changes — useful for recovering from a failed deployment, rotating credentials, or periodic health-checks.

### Configuration

In the environment's YAML file under `genesis.pipeline`:

```yaml
genesis:
  pipeline:
    redeploy: manual          # or: cron, signal
    redeploy_cron_start: "04:00"   # only required for cron mode
    redeploy_cron_stop:  "05:00"   # only required for cron mode
```

### Trigger Modes

**`manual`** — A `redeploy-<env>` Concourse job is created with no auto-trigger. An operator triggers it via the UI or `fly trigger-job`.

**`signal`** — Identical to `manual` in pipeline terms; the naming convention communicates that the trigger is expected from an external automated system rather than a human.

**`cron`** — A Concourse `time` resource is created for the environment and wired as the job trigger. The job runs automatically whenever Concourse observes the time window.

```yaml
# Daily redeploy between 04:00–05:00 UTC
genesis:
  pipeline:
    redeploy: cron
    redeploy_cron_start: "04:00"
    redeploy_cron_stop:  "05:00"
```

When no `redeploy_cron_start` / `redeploy_cron_stop` are specified, they default to `04:00` and `05:00` UTC.

### What the Redeploy Job Does

- Acquires the same dual locks as a normal deploy (`<env>-bosh-lock` and `<env>-deployment-lock`), ensuring it coordinates with in-flight normal deploys.
- Gets the current env branch and git resource (no trigger, no change detection).
- Runs `ci-pipeline-deploy` with `PREVIOUS_ENV=~` (no cache, no propagation from upstream).
- Does **not** generate or push a cache after deploying — only normal deploys advance the cache.
- Does **not** trigger downstream environments.

### Pipeline Groups

Any pipeline that has at least one env with `redeploy` configured will emit a `redeploy` group in Concourse, separate from the main workflow group. This keeps the redeploy jobs visible but out of the main deployment flow.

### Mermaid Diagram Annotation

Environments with redeploy configured are annotated in the auto-generated pipeline Mermaid diagram:

```
sandbox --> preprod[(preprod\nREDEPLOY)] --> prod
```

Annotations can combine: `PR+MANUAL+REDEPLOY` for an env that has all three flags set.
