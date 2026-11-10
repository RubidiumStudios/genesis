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

When `require_pr` is set, `genesis propagate` uses a rolling `pr/<env>` branch instead of pushing directly to the env branch. The first propagation to a given env creates `pr/<env>` from the env branch, commits the change, pushes, and opens a GitHub Pull Request. Subsequent propagations to the same env append commits to the existing branch and update the PR. Merging the PR is what triggers the Concourse deploy.

The branch is short-lived: it exists only while a PR is open against the env. Operators are expected to delete the branch after the PR merges; stale branches are detected and cleaned up automatically when a fresh propagation arrives with no open PR.

### Idempotency

Re-running `genesis propagate` with the same control SHA is a full no-op for envs whose `pr/<env>` HEAD already references that control SHA — no commit, no push, no PR update. The check looks at the latest commit subject on `pr/<env>` for the `[pipeline] control@<short-sha>` marker. Operators may safely re-run propagate to confirm state.

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

Every environment gets a `redeploy-<env>` job, unless `.genesis/config` turns them off:

```yaml
pipeline:
  redeploy:
    enabled: true     # the default; false emits no redeploy jobs
    style:   inline   # beside each deploy, or grouped in one redeploys group
```

The v2 environment keys `redeploy`, `redeploy_cron_start` and `redeploy_cron_stop` are retired and refused at load. So are the `signal` mode and FWT-948's `status_signal` and `signal_prefix`; the shuttle's events replaced them.

### What Triggers It

- **Its button**, in the Concourse UI or by `fly trigger-job`.
- **A request on its queue**, `redeploy_<env>-<type>` on the shuttle, which another pipeline or tool writes to. The job hands each request back in its outcome hooks.
- **A schedule:** `genesis.pipeline.redeploy_cron` (crontab strings, in UTC) is accepted, but no schedule is emitted yet.

### What the Redeploy Job Does

- Holds the same locks as a deploy: its own deployment's, and its director's.
- Runs `genesis <env> deploy --redeploy` against the commit the environment last deployed, recorded in exodus, never the branch tip.
- Writes the `<env>-<type>_redeployed` event on success. Propagation never reads it, so a redeploy delivers nothing to the environments after it.

### Pipeline Groups

Under `style: inline` each redeploy job sits beside its deploy. Under `style: grouped` they are all listed in one `redeploys` group, after the deployments' groups and before `propagation`.

### Mermaid Diagram Annotation

Environments with redeploy configured are annotated in the auto-generated pipeline Mermaid diagram:

```
sandbox --> preprod[(preprod\nREDEPLOY)] --> prod
```

Annotations can combine: `PR+MANUAL+REDEPLOY` for an env that has all three flags set.
