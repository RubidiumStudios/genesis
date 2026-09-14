# Pipeline Section Configuration Example

This directory holds one example file per block of the `pipeline:` section of `.genesis/config`, so you can read each block on its own before assembling the section.

## Required vs Optional Blocks

### ✅ REQUIRED Blocks

```
pipeline:
├── targets:              # ✅ REQUIRED - Deployment targets (BOSH directors)
└── integrations:         # ✅ REQUIRED - Vault, Git, notifications
```

**Minimum viable configuration requires only these 2 blocks.**

### 📋 OPTIONAL Blocks

```
pipeline:
├── provider:                     # 📋 OPTIONAL - Provider type and its options
├── pipeline:                     # 📋 OPTIONAL - Main pipeline definition
│                                 #              (absent means the topology comes
│                                 #               from your environment files)
├── scripts:                      # 📋 OPTIONAL - Explicit script metadata
│                                 #              (scripts auto-discovered if not present)
└── provider_config:              # 📋 OPTIONAL - Provider-specific overrides
    ├── concourse:                # 📋 OPTIONAL - Concourse settings
    └── github-actions:           # 📋 OPTIONAL - GitHub Actions settings
```

Shell scripts themselves live under `scripts/` at the root of the deployment repository, and nothing reads a `.genesis/ci/` directory any more.

### Complete Example Structure

```
pipeline:                           # The pipeline section of .genesis/config
├── targets:                        # ✅ REQUIRED
├── integrations:                   # ✅ REQUIRED
├── provider:                       # 📋 OPTIONAL - Provider type and its options
├── pipeline:                       # 📋 OPTIONAL - Main pipeline definition
├── scripts:                        # 📋 OPTIONAL - Explicit script definitions
└── provider_config:                # 📋 OPTIONAL
    ├── concourse:                  # 📋 OPTIONAL - Concourse overrides
    └── github-actions:             # 📋 OPTIONAL - GitHub Actions overrides

scripts/                            # 📋 OPTIONAL - at the repository root
├── deploy/
│   └── genesis-deploy.sh           # 📋 OPTIONAL - Deployment script
├── test/
│   └── smoke-tests.sh              # 📋 OPTIONAL - Smoke test script
└── maintenance/
    ├── check-kit-updates.sh        # 📋 OPTIONAL - Kit update checker
    └── update-kit.sh               # 📋 OPTIONAL - Kit updater
```

## Block Details

### 1. 📋 pipeline - Main Pipeline Definition

Leave this block out and the pipeline topology is read from the
`genesis.pipeline.*` keys in your environment files instead. Write it when
you want to name the pipeline and lay its workflows out by hand.

**Checked when present:**
- ✅ `metadata.name` - Pipeline name, required once `metadata` is present
- ✅ `branches.live` - Main branch to monitor, required once `branches` is present

**Optional sections:**
- 📋 `workflows` - Absent means the topology comes from the environment files
- 📋 `metadata.version`, `metadata.description`
- 📋 `branches.target_prefix`
- 📋 `configuration.*` - All configuration is optional

**Minimal Example:**
```yaml
metadata:
  name: my-pipeline
branches:
  live: main
workflows:
  deploy:
    type: deployment
    stages:
      - name: sandbox
```

See [pipeline.yml](pipeline.yml) for this block's full contents, with all optional features.

### 2. ✅ targets - Deployment Targets

**Required:**
- ✅ `targets` - At least one deployment target

**For BOSH director targets, required:**
- ✅ `type: bosh-director`
- ✅ `connection.url`
- ✅ `connection.auth.client_id`
- ✅ `connection.auth.client_secret`
- ✅ `connection.ca_cert`

**Optional per-target:**
- 📋 `alias`, `tags`, `region`, `genesis_env`

**Minimal Example:**
```yaml
targets:
  sandbox:
    type: bosh-director
    connection:
      url: https://bosh.example.com:25555
      auth:
        client_id: admin
        client_secret: ((bosh-password))
      ca_cert: ((bosh-ca-cert))
```

See [targets.yml](targets.yml) for this block's multi-region, multi-tier contents.

### 3. ✅ integrations - External Services

**Required:**
- ✅ `vault.url`
- ✅ `source_control` (provider or uri + repository)
- ✅ At least one notification (`slack` or `email`)

**Optional:**
- 📋 `vault.namespace`, `vault.auth`
- 📋 `source_control.auth`, `source_control.commit_author`
- 📋 `locker` configuration

**Minimal Example:**
```yaml
vault:
  url: https://vault.example.com

source_control:
  provider: github
  repository: myorg/deployments

notifications:
  - type: slack
    webhook: ((slack-webhook))
    channel: "#deployments"
```

See [integrations.yml](integrations.yml) for this block's full contents.

## Optional Features

### 📋 Script Discovery (3 Methods)

Scripts are discovered automatically using **three methods in priority order:**

#### Method 1: The `scripts:` Block (Highest Priority)
Full control over script metadata. [scripts/manifest.yml](scripts/manifest.yml) shows what the block holds.

#### Method 2: Inline Annotations
Scripts with `@genesis-script` annotations:
```bash
#!/bin/bash
# @genesis-script
# @description: Execute Genesis deployment
# @requires: genesis>=3.1.0
# @timeout: 60m
```

#### Method 3: Convention-Based (Fallback)
Auto-discovery from filename, under `scripts/` at the repository root:
- `scripts/deploy.sh` → ID: `deploy`
- `scripts/test/smoke.sh` → ID: `test/smoke`

### 📋 Provider-Specific Overrides

- [provider-config/concourse.yml](provider-config/concourse.yml) - Concourse-only settings, under `provider_config.concourse`
- [provider-config/github-actions.yml](provider-config/github-actions.yml) - GitHub Actions-only settings, under `provider_config.github-actions`

## Quick Start - Minimal Configuration

Write these 3 blocks into the `pipeline:` section of `.genesis/config` to get started:

**The `pipeline` block:**
```yaml
metadata:
  name: my-pipeline
branches:
  live: main
workflows:
  deploy:
    type: deployment
    stages:
      - name: sandbox
```

**The `targets` block:**
```yaml
targets:
  sandbox:
    type: bosh-director
    connection:
      url: https://bosh.example.com:25555
      auth:
        client_id: admin
        client_secret: ((bosh-password))
      ca_cert: ((bosh-ca-cert))
```

**The `integrations` block:**
```yaml
vault:
  url: https://vault.example.com
source_control:
  provider: github
  repository: myorg/deployments
notifications:
  - type: slack
    webhook: ((slack-webhook))
    channel: "#ci"
```

Then apply it:
```bash
genesis pipeline-apply
```

## Usage

### Compile and Deploy the Pipeline

```bash
cd /path/to/deployment-repo

# Compile and deploy the pipeline
genesis pipeline-apply
```

The provider is not a flag. `genesis pipeline-apply` reads
`pipeline.provider.type` from `.genesis/config`, so set that key to
`concourse` or to `github-actions` and the same command compiles for
whichever one you named.

### Compile to GitHub Actions Workflow

Set `pipeline.provider.type` to `github-actions` in `.genesis/config`, then run the same command:

```bash
genesis pipeline-apply
```

### Generate Pipeline from Legacy Format

If you have an existing `ci.yml`, you can migrate:

```bash
# The compiler handles both formats automatically
genesis pipeline-apply --config ci.yml
```

## Secret References

Secrets use the `((...))` syntax and are resolved at runtime:

- `((vault/path/to/secret))` - Vault secret path
- `((bosh/env/ca-cert))` - BOSH director CA certificate
- `((git/deploy-key))` - Git SSH deploy key
- `((slack/webhook-url))` - Slack webhook URL

## Workflow Triggers

### Git Commit Triggers
```yaml
triggers:
  - type: git-commit
    branch: main
    pattern: "*-sandbox"  # Auto-deploy sandbox environments
```

### Schedule Triggers
```yaml
triggers:
  - type: schedule
    cron: "0 2 * * 1"  # Weekly on Monday at 2am
```

### Deployment Completion Triggers
```yaml
triggers:
  - type: deployment-complete
    pattern: "*"  # All environments
```

## Environment Progression

The example demonstrates a typical progression:

```
sandbox (auto) → preprod (manual) → prod (manual)
```

- **Sandbox**: Auto-deploys on every commit
- **Pre-Prod**: Requires manual trigger, runs after sandbox
- **Production**: Requires manual trigger, runs after preprod

## Multi-Region Deployment

The example includes parallel deployment across regions:

- **US-West**: us-west-sandbox, us-west-preprod, us-west-prod
- **US-East**: us-east-sandbox, us-east-prod

Each region can progress independently.

## Testing Integration

Smoke tests run automatically after successful deployments:

1. Login to Cloud Foundry API
2. Verify org/space listing
3. Check buildpacks availability
4. Validate service marketplace

## Maintenance Workflows

Scheduled kit updates:

1. **Check for Updates**: Query Genesis Community for new kit versions
2. **Update Kit**: Download and apply updates
3. **Run Tests**: Validate updated kit with unit tests

## Migration from Legacy Format

The compiler automatically normalizes legacy `ci.yml` to this structure:

| Legacy `ci.yml` | The `pipeline:` section |
|-----------------|-------------------------|
| `pipeline.name` | `pipeline.metadata.name` |
| `pipeline.vault` | `integrations.vault` |
| `pipeline.git` | `integrations.source_control` |
| `pipeline.boshes` | `targets` |
| `pipeline.slack` | `integrations.notifications` |
| `pipeline.layout` | `pipeline.workflows.deploy.stages` |

Operators in a legacy `ci.yml` are evaluated at parse time, because the parser loads that file through `spruce merge`. The `pipeline:` section is not, because Genesis reads `.genesis/config` through `spruce json`, so write credential references in the form your CI provider resolves and expect every other value to arrive exactly as you wrote it.

## Configuration Checklist

### ✅ Required (Minimum Viable Pipeline)
- [ ] A `pipeline:` section in `.genesis/config`
- [ ] A `targets` block with at least one BOSH director
- [ ] An `integrations` block with `vault.url` and `source_control`
- [ ] Credentials loaded into your CI provider for all `((...))` references

### 📋 Recommended (Production-Ready)
- [ ] Multiple environments (sandbox, preprod, prod)
- [ ] Email notifications in addition to Slack
- [ ] Auto-triggering for sandbox, manual for production
- [ ] Locker integration for deployment coordination
- [ ] Script metadata, either the `scripts` block or inline annotations

### 🎯 Advanced (Enterprise)
- [ ] Multiple workflows (deploy, test, maintenance)
- [ ] Multi-region deployment targets
- [ ] Provider-specific configuration overrides
- [ ] Scheduled maintenance workflows
- [ ] Custom scripts with full metadata

## Troubleshooting

### "Missing required 'vault' section"
→ Add `vault:` with a `url` under the `integrations` block

### "Pipeline must have at least one workflow"
→ Add a workflow under `pipeline.workflows`, or leave the `pipeline` block out and let the topology come from your environment files

### "Target 'X' is missing 'connection.url'"
→ BOSH targets need `connection.url`, `connection.auth`, `connection.ca_cert`

### "No notification stanzas defined"
→ Add a Slack or Email notification under the `integrations` block

### Script not found
→ Scripts auto-discover from the `scripts/` directory at the repository root
→ Use `@genesis-script` annotations or declare the script in the `scripts` block

## See Also

- [CI Compiler Documentation](../../lib/Genesis/CI/Compiler/README.md)
- [Genesis CI System Architecture](../../lib/Genesis/CI/README.md)
- [Genesis Documentation](https://genesis-community.github.io/docs/)
