# Notification Styles

Genesis pipelines can emit Slack notifications for pipeline events. Four styles control what gets notified, when, and how. Styles can be combined with per-environment overrides and `@mentions` on failure.

## Configuration

Notification config lives in the `slack:` block of your pipeline integrations:

```yaml
# .genesis/ci/integrations.yml  (multi-file format)
# — or —
# integrations section of ci.yml  (legacy format)

slack:
  webhook:  ((slack-webhook))
  channel:  '#deployments'
  style:    grouped           # per-env | grouped | minimal | none
  mentions_on_failure:
    - '@sre-oncall'
  per_env_overrides:
    lm-aws-useast1-hs-prod:
      channel:  '#prod-deployments'
      mentions_on_failure:
        - '@prod-sre'
```

All keys except `webhook` and `channel` are optional.

## Styles

### `per-env` (default)

A pending-changes notification job (`notify-<env>-<type>-changes`) is created for every non-auto environment. The deploy job depends on the notify job — it runs only after the operator acknowledges the changes. All envs share the global Slack channel unless overridden.

```
notify-sandbox-deployment-changes  →  sandbox-deployment
notify-prod-deployment-changes     →  prod-deployment
```

**Use when**: you want humans to review and approve each deployment manually.

### `grouped`

Same notify jobs as `per-env`, but they are collected into a separate `notifications` Concourse group rather than sitting inline with the deploy pipeline. Deploy jobs do not depend on notify jobs — they can run independently.

```
Group: my-pipeline
  sandbox-deployment, prod-deployment

Group: notifications
  notify-sandbox-deployment-changes, notify-prod-deployment-changes
```

**Use when**: you want pending-change visibility but don't want notifications to gate deployments.

### `minimal`

No pending-changes notify jobs are created. Slack notifications are emitted only on failure (via the `on_failure` hook). Success is silent.

```
sandbox-deployment  (on_failure → Slack alert)
prod-deployment     (on_failure → Slack alert)
```

**Use when**: you only want to know about failures — lab pipelines, automated CI loops, high-frequency deploy pipelines where success noise is unwanted.

### `none`

No Slack notifications at all. No `slack` resource, no notify jobs, no outcome hooks. The `slack-notification` Concourse resource type is also omitted.

**Use when**: throwaway or local test pipelines where notifications are irrelevant.

## Decision matrix

| Scenario | Recommended style |
|----------|------------------|
| Production pipeline, manual approvals required | `per-env` |
| Large pipeline, separate ops notification channel | `grouped` |
| Automated CI, alert on failures only | `minimal` |
| Lab / ephemeral test environment | `none` |
| High-frequency nightly deploys | `minimal` |

## `mentions_on_failure`

A list of Slack handles or role mentions prepended to failure notification text. Applies globally unless overridden per env.

```yaml
slack:
  mentions_on_failure:
    - '@sre-oncall'
    - '@platform-team'
```

Output for a failure: `@sre-oncall @platform-team: test-pipeline: Deployment to prod-deployment failed`

Mentions are **never** added to success notifications.

## Per-environment overrides

Any environment can override the global `channel` and/or `mentions_on_failure`:

```yaml
slack:
  channel: '#deployments'
  mentions_on_failure: []
  per_env_overrides:
    lm-aws-useast1-hs-prod:
      channel:  '#prod-critical'
      mentions_on_failure:
        - '@prod-sre'
```

The override key is the environment name as declared in the env YAML file. Any keys absent from the override inherit from the global config.

## Backward compatibility

The legacy `notifications: grouped` format in `ci.yml` is still recognized:

| Legacy value | New equivalent |
|-------------|---------------|
| `notifications: grouped` | `slack.style: grouped` |
| `notifications: inline` (or absent) | `slack.style: per-env` |

The old `integrations.notifications` array format is also still accepted. Genesis will normalize it automatically:

```yaml
# Old format — still works
integrations:
  notifications:
    - type: slack
      webhook: ((hook))
      channel: '#ci'
```

This is treated as `style: per-env` (or `grouped` if `notifications: grouped` is also set). New pipelines should use the `slack:` block directly.
