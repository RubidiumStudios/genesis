# ci.yml Configuration Reference

This document defines all configuration options for the Genesis pipeline `ci.yml` file.

## Document Structure

```yaml
pipeline:
  # Core configuration (required)
  name: string
  vault: { ... }
  git: { ... }
  boshes: { ... }

  # Notifications (at least one required)
  slack: { ... }
  email: { ... }

  # Layout definition (one form required)
  layout: string      # Single layout
  layouts: { ... }    # Multiple named layouts

  # Optional configuration
  locker: { ... }
  registry: { ... }
  task: { ... }
  auto-update: { ... }
  groups: { ... }
  errands: [ ... ]

  # Optional flags
  public: boolean
  tagged: boolean
  unredacted: boolean
  debug: boolean
  ocfp: boolean
  notifications: string
  require-passed-caches: boolean
```

---

## Required Configuration

### `pipeline.name`

**Type:** string
**Required:** Yes

Display name for the pipeline in Concourse.

```yaml
pipeline:
  name: "production-deployments"
```

---

### `pipeline.vault`

**Required:** Yes

Vault server configuration for secret management.

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `url` | string | Yes | - | Vault server URL |
| `verify` | boolean | No | `true` | TLS certificate verification |
| `role` | string | Conditional | - | AppRole ID (required with `secret`) |
| `secret` | string | Conditional | - | AppRole secret (required with `role`) |
| `namespace` | string | No | - | Vault namespace (Enterprise only) |
| `no-strongbox` | boolean | No | `false` | Set `true` for non-Genesis Vault kits |

**Example:**
```yaml
pipeline:
  vault:
    url: "https://vault.example.com"
    verify: true
    role: "(( vault \"secret/ci/approle:id\" ))"
    secret: "(( vault \"secret/ci/approle:secret\" ))"
```

---

### `pipeline.git`

**Required:** Yes

Git repository configuration.

#### Authentication (mutually exclusive)

**Option 1: SSH Private Key**
```yaml
pipeline:
  git:
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      ...
      -----END RSA PRIVATE KEY-----
```

**Option 2: HTTPS Username/Password**
```yaml
pipeline:
  git:
    username: "bot-user"
    password: "(( vault \"secret/git:password\" ))"
```

#### Repository Definition (mutually exclusive)

**Option A: Direct URI**
```yaml
pipeline:
  git:
    uri: "git@github.com:org/repo.git"
```

**Option B: Owner + Repo Pattern**
```yaml
pipeline:
  git:
    owner: "my-org"
    repo: "deployments"
    host: "github.com"  # optional, defaults to github.com
```

#### Optional Git Fields

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `branch` | string | `"master"` | Git branch to track |
| `root` | string | `"."` | Subdirectory within repo for Genesis |
| `version_depth` | integer | `0` | Git history depth for version checks |
| `commits.user_name` | string | `"Concourse Bot"` | Commit author name |
| `commits.user_email` | string | `"concourse@pipeline"` | Commit author email |

**Complete Example:**
```yaml
pipeline:
  git:
    owner: "mycompany"
    repo: "prod-deployments"
    private_key: "(( vault \"secret/git:private_key\" ))"
    branch: "main"
    root: "deployments"
    commits:
      user_name: "Genesis Bot"
      user_email: "genesis@example.com"
```

---

### `pipeline.boshes`

**Required:** Yes

BOSH director configurations. One entry per environment.

#### Standard BOSH Director

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `url` | string | Yes | BOSH director URL |
| `username` | string | Yes | BOSH admin username |
| `password` | string | Yes | BOSH admin password |
| `ca_cert` | string | Yes | BOSH CA certificate (PEM) |
| `alias` | string | No | Short name for pipeline jobs |
| `genesis_env` | string | No | OCFP environment name mapping |

#### Proto-BOSH (create-env)

For create-env deployments, only `alias` is allowed (no connection details).

**Example:**
```yaml
pipeline:
  boshes:
    proto-bosh:
      alias: "proto"
      # No url/username/password/ca_cert for create-env

    sandbox:
      alias: "sb"
      url: "https://sandbox.example.com:25555"
      ca_cert: "(( vault \"secret/bosh/sandbox/ssl:ca\" ))"
      username: "admin"
      password: "(( vault \"secret/bosh/sandbox:password\" ))"

    prod:
      url: "https://prod.example.com:25555"
      ca_cert: "(( vault \"secret/bosh/prod/ssl:ca\" ))"
      username: "admin"
      password: "(( vault \"secret/bosh/prod:password\" ))"
```

---

## Notification Configuration

**At least one notification channel (Slack or Email) must be defined.**

### `pipeline.slack`

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `webhook` | string | Yes | - | Slack webhook URL |
| `channel` | string | Yes | - | Channel (`#channel`) or user (`@user`) |
| `username` | string | No | `"runwaybot"` | Bot display name |
| `icon` | string | No | - | Bot icon URL |

```yaml
pipeline:
  slack:
    webhook: "(( vault \"secret/slack:webhook\" ))"
    channel: "#deployments"
    username: "GenesisBot"
```

### `pipeline.email`

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `to` | array | Yes | List of recipient email addresses |
| `from` | string | Yes | Sender email address |
| `smtp.host` | string | Yes | SMTP server hostname |
| `smtp.port` | integer | No | SMTP port (default: 587) |
| `smtp.username` | string | Yes | SMTP authentication username |
| `smtp.password` | string | Yes | SMTP authentication password |

```yaml
pipeline:
  email:
    to:
      - "ops-team@example.com"
      - "devops-lead@example.com"
    from: "deployments@example.com"
    smtp:
      host: "smtp.example.com"
      port: 587
      username: "(( vault \"secret/smtp:username\" ))"
      password: "(( vault \"secret/smtp:password\" ))"
```

---

## Layout Configuration

**One form required: either `layout` (single) or `layouts` (multiple).**

### Layout Language Syntax

#### Auto-Trigger Directive
```
auto <pattern>
```
- Patterns support `*` wildcard (expands to `.*` regex)
- Multiple `auto` lines allowed
- Pattern must match at least one environment name

#### Trigger Chain
```
<env-a> -> <env-b> [-> <env-c> ...]
```
- Defines deployment progression
- Each environment can only be triggered by ONE upstream

#### Comments
Lines beginning with `#` are ignored.

### Single Layout

```yaml
pipeline:
  layout: |+
    auto *-sandbox
    sandbox -> preprod -> prod
```

### Multiple Named Layouts

```yaml
pipeline:
  layouts:
    default: |+
      auto *-sandbox
      sandbox -> preprod -> prod

    regional: |+
      auto us-sandbox eu-sandbox
      us-sandbox -> us-preprod -> us-prod
      eu-sandbox -> eu-preprod -> eu-prod

    on-prem: |+
      on-prem-1 -> on-prem-2
```

**Layout Selection:**
- If layout name provided to `genesis repipe`, use it
- If only one layout exists, use it
- If `default` layout exists, use it
- Otherwise, prompt user to select

---

## Optional Configuration

### `pipeline.locker`

Distributed deployment locking to prevent simultaneous deployments.

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `url` | string | Yes* | - | Locker API endpoint |
| `username` | string | Yes* | - | Authentication username |
| `password` | string | Yes* | - | Authentication password |
| `skip_ssl_validation` | boolean | No | `true` | Skip SSL verification |
| `ca_cert` | string | No | - | CA certificate (PEM) |

*Required if locker section is defined.

```yaml
pipeline:
  locker:
    url: "https://locker.example.com"
    username: "concourse"
    password: "(( vault \"secret/locker:password\" ))"
    skip_ssl_validation: false
    ca_cert: "(( vault \"secret/locker/ssl:ca\" ))"
```

---

### `pipeline.registry`

Private Docker registry configuration.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `uri` | string | No | Registry endpoint |
| `username` | string | No | Authentication username |
| `password` | string | No | Authentication password |

```yaml
pipeline:
  registry:
    uri: "registry.example.com"
    username: "bot"
    password: "(( vault \"secret/registry:password\" ))"
```

---

### `pipeline.task`

Concourse task configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `image` | string | `"genesiscommunity/concourse"` | Docker image name |
| `version` | string | `"latest"` | Docker image tag |
| `privileged` | array | `[]` | Environments requiring privileged mode |

```yaml
pipeline:
  task:
    image: "myregistry/genesis-ci"
    version: "v2.0.0"
    privileged:
      - proto-bosh
```

---

### `pipeline.auto-update`

Automatic Genesis and kit version updates.

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `file` | string | Yes | - | File containing kit.version |
| `kit` | string | No | auto-detected | Kit name |
| `org` | string | No | auto-detected | GitHub organization |
| `api_url` | string | No | auto-detected | Git API URL |
| `auth_token` | string | No | - | GitHub token |
| `kit_auth_token` | string | No | - | Kit provider token |
| `github_auth_token` | string | No | - | Genesis GitHub token |
| `label` | string | No | `"concourse"` | Commit message label |
| `period` | string | No | `"24h"` | Check interval |

```yaml
pipeline:
  auto-update:
    file: "deployments/kit.yml"
    kit: "cf"
    auth_token: "(( vault \"secret/github:token\" ))"
    period: "12h"
```

---

### `pipeline.groups`

Organize jobs into Concourse UI tabs.

```yaml
pipeline:
  groups:
    sandbox:
      - sandbox
    production:
      - preprod
      - prod
```

---

### `pipeline.errands`

BOSH errands to run after each deployment.

```yaml
pipeline:
  errands:
    - smoke-tests
    - acceptance-tests
```

---

## Optional Flags

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `public` | boolean | `false` | Pipeline visibility in Concourse |
| `tagged` | boolean | `false` | Use tags for worker constraints |
| `unredacted` | boolean | `false` | Show secrets in logs |
| `debug` | boolean | `false` | Enable debug output |
| `ocfp` | boolean | `false` | Use OCFP naming for configs |
| `notifications` | string | `"inline"` | Style: `inline`, `parallel`, `grouped` |
| `require-passed-caches` | boolean | `true` | Require cached changes to have passed |

---

## Complete Example

```yaml
pipeline:
  name: "production-deployments"
  public: false
  tagged: true
  debug: false

  vault:
    url: "https://vault.prod.example.com"
    verify: true
    role: "(( vault \"secret/ci/approle:id\" ))"
    secret: "(( vault \"secret/ci/approle:secret\" ))"

  git:
    owner: "mycompany"
    repo: "prod-deployments"
    private_key: "(( vault \"secret/git:private_key\" ))"
    branch: "main"
    root: "deployments"
    commits:
      user_name: "Genesis Bot"
      user_email: "genesis@example.com"

  slack:
    webhook: "(( vault \"secret/slack:webhook\" ))"
    channel: "#deployments"
    username: "GenesisBot"

  task:
    image: "genesiscommunity/concourse"
    version: "latest"

  locker:
    url: "https://locker.example.com"
    username: "concourse"
    password: "(( vault \"secret/locker:password\" ))"

  boshes:
    sandbox:
      alias: "sb"
      url: "https://sandbox.example.com:25555"
      ca_cert: "(( vault \"secret/bosh/sandbox/ssl:ca\" ))"
      username: "admin"
      password: "(( vault \"secret/bosh/sandbox:password\" ))"

    preprod:
      url: "https://preprod.example.com:25555"
      ca_cert: "(( vault \"secret/bosh/preprod/ssl:ca\" ))"
      username: "admin"
      password: "(( vault \"secret/bosh/preprod:password\" ))"

    prod:
      url: "https://prod.example.com:25555"
      ca_cert: "(( vault \"secret/bosh/prod/ssl:ca\" ))"
      username: "admin"
      password: "(( vault \"secret/bosh/prod:password\" ))"

  errands:
    - smoke-tests

  notifications: "grouped"

  groups:
    sandbox:
      - sandbox
    production:
      - preprod
      - prod

  layouts:
    default: |+
      auto *-sandbox
      sandbox -> preprod -> prod

    regional: |+
      auto us-sandbox eu-sandbox
      us-sandbox -> us-preprod -> us-prod
      eu-sandbox -> eu-preprod -> eu-prod
```

---

## Validation Rules

### Required Fields
- `pipeline.name` must be present
- `pipeline.vault.url` must be present
- `pipeline.git` must have either `private_key` OR (`username` AND `password`)
- `pipeline.git` must have either `uri` OR (`owner` AND `repo`)
- `pipeline.boshes` must have at least one environment
- At least one of `pipeline.slack` or `pipeline.email` must be defined
- Either `pipeline.layout` or `pipeline.layouts` must be defined (not both)

### BOSH Environment Validation
- For standard deployments: `url`, `username`, `password`, `ca_cert` all required
- For create-env: only `alias` allowed
- Environment names must match entries in layout

### Layout Validation
- Each environment can only be triggered by ONE other environment
- Auto patterns must match at least one environment
- All environments in layout must have corresponding BOSH config

### Mutual Exclusions
- `private_key` vs `username`/`password`
- `uri` vs `owner`/`repo`
- `layout` vs `layouts`
