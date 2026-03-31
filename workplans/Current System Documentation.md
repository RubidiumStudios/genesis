# Genesis Pipeline System - Current State Documentation

This document describes the current (legacy) cache-based pipeline system before the branch-based refactor.

## Overview

The Genesis pipeline system is a Concourse CI/CD integration framework that orchestrates deployment workflows across multiple environments. It implements:

- Hierarchical environment model based on hyphen-delimited naming
- File-based caching for validated change propagation
- Domain-specific language for pipeline configuration
- Automatic generation of Concourse pipeline YAML

---

## Pipeline Commands

### `genesis repipe [<layout>]`

**Purpose:** Configure and deploy a Concourse pipeline for automating deployments.

**Options:**
| Option | Description |
|--------|-------------|
| `--yes`, `-y` | Skip all confirmation prompts |
| `--dry-run`, `-n` | Generate YAML without deploying to Concourse |
| `--target`, `-t <name>` | Concourse target name (defaults to layout name) |
| `--config`, `-c <path>` | Pipeline config file (defaults to `ci.yml`) |
| `--paused`, `-P` | Keep pipeline paused after deployment |

**Workflow:**

```mermaid
flowchart TD
    A[genesis repipe] --> B[Parse ci.yml with Spruce]
    B --> C[Validate pipeline definition]
    C --> D{Multiple layouts?}
    D -->|Yes| E[Prompt user to select]
    D -->|No| F[Use default/only layout]
    E --> G[Generate Concourse YAML]
    F --> G
    G --> H{--dry-run?}
    H -->|Yes| I[Output YAML to stdout]
    H -->|No| J[fly pause-pipeline]
    J --> K[fly set-pipeline]
    K --> L{--paused?}
    L -->|Yes| M[Done]
    L -->|No| N[fly unpause-pipeline]
    N --> O[Set visibility]
    O --> M
```

---

### `genesis graph [<layout>]`

**Purpose:** Generate a Graphviz DAG representation of the pipeline.

**Output:** DOT format to stdout showing environment nodes and trigger dependencies.

---

### `genesis describe [<layout>]`

**Purpose:** Describe pipeline structure in human-readable ASCII tree format.

---

### `genesis ci-pipeline-deploy`

**Purpose:** Execute deployment from within Concourse pipeline context.

**Required Environment Variables:**
| Variable | Description |
|----------|-------------|
| `CURRENT_ENV` | Environment being deployed |
| `GIT_BRANCH` | Branch to push commits to |
| `VAULT_ROLE_ID` | Vault AppRole ID |
| `VAULT_SECRET_ID` | Vault AppRole Secret |
| `VAULT_ADDR` | Vault URL |
| `WORKING_DIR` | Deployment working directory |
| `OUT_DIR` | Output directory for commits |

**Optional Environment Variables:**
| Variable | Description |
|----------|-------------|
| `PREVIOUS_ENV` | Triggering environment (enables cache propagation) |
| `CACHE_DIR` | Required if PREVIOUS_ENV set |
| `GIT_GENESIS_ROOT` | Subdirectory path within repo |
| `GIT_PRIVATE_KEY` | SSH key (OR username/password) |
| `GIT_USERNAME` | HTTPS auth username |
| `GIT_PASSWORD` | HTTPS auth password |
| `VAULT_SKIP_VERIFY` | SSL verification bypass |
| `VAULT_NAMESPACE` | Enterprise Vault namespace |

**Workflow:**

```mermaid
flowchart TD
    A[ci-pipeline-deploy] --> B[Validate env vars]
    B --> C[Authenticate to Vault]
    C --> D{PREVIOUS_ENV set?}
    D -->|Yes| E[Propagate cache from PREVIOUS_ENV]
    D -->|No| F[Skip cache propagation]
    E --> G{create-env deployment?}
    F --> G
    G -->|Yes| H[Fetch state file from git]
    G -->|No| I[Load environment]
    H --> I
    I --> J[Execute deployment]
    J --> K[Clean up local cache]
    K --> L[Commit changes to git]
```

---

### `genesis ci-show-changes`

**Purpose:** Display deployment changes without executing. Analyzes manifest differences.

**Behavior:**
- Propagates previous environment cache
- Generates `updates.yml` (pruned manifest)
- Generates `bosh-vars.yml` for interpolation
- Creates diff script comparing current vs deployed
- Detects cache mismatches and warns about inconsistencies

---

### `genesis ci-generate-cache`

**Purpose:** Generate cache of environment configuration files for downstream propagation.

**What Gets Cached:**
- Hierarchical YAML files (common with predecessor)
- `kit-overrides.yml`
- `ops/` directory
- `bin/` directory

**Cache Location:** `.genesis/cached/<env-name>/`

---

### `genesis ci-pipeline-run-errand`

**Purpose:** Execute BOSH errands after successful deployment.

**Required:** `ERRAND_NAME` environment variable

---

## Caching Mechanism

### File Hierarchy Model

Files are identified via `Genesis::Env::relate_by_name()`:

1. Environment names split by hyphen: `us-west-1-preprod-east` → `[us, west, 1, preprod, east]`
2. Common prefix found with predecessor
3. Files generated for each prefix level

**Example:**

| Environment | Predecessor | Common Files | Unique Files |
|-------------|-------------|--------------|--------------|
| `us-west-1-preprod-east` | `us-west-1-sandbox` | `us.yml`, `us-west.yml`, `us-west-1.yml` | `us-west-1-preprod.yml`, `us-west-1-preprod-east.yml` |

### Cache Propagation Flow

```mermaid
flowchart LR
    subgraph sandbox["sandbox deployment"]
        S1[Deploy] --> S2[ci-generate-cache]
        S2 --> S3[.genesis/cached/sandbox/]
    end

    subgraph preprod["preprod deployment"]
        P0[Receive sandbox cache] --> P1[Propagate to working dir]
        P1 --> P2[Merge cached + preprod files]
        P2 --> P3[Deploy]
        P3 --> P4[ci-generate-cache]
        P4 --> P5[.genesis/cached/preprod/]
    end

    subgraph prod["prod deployment"]
        R0[Receive preprod cache] --> R1[...]
    end

    S3 --> P0
    P5 --> R0
```

### Cache Directory Structure

```
.genesis/
├── cached/
│   ├── sandbox/
│   │   ├── us.yml
│   │   ├── us-west.yml
│   │   ├── us-west-1.yml
│   │   ├── kit-overrides.yml
│   │   ├── ops/
│   │   └── bin/
│   └── preprod/
│       └── ...
├── manifests/
│   ├── sandbox.yml
│   └── sandbox-state.yml  (create-env only)
├── kits/
└── config
```

---

## Pipeline Execution Flow

```mermaid
flowchart TD
    subgraph sandbox["Environment: sandbox"]
        direction TB
        ST[Trigger: auto on git changes]
        SN[notify-sandbox-changes<br/>genesis ci-show-changes]
        SD[sandbox-deployment]
        SD1[Acquire locks]
        SD2[genesis ci-pipeline-deploy]
        SD3[genesis ci-generate-cache]
        SD4[genesis ci-pipeline-run-errand]
        SD5[Release locks]
        SO[Output: sandbox-cache]

        ST --> SN
        SN --> SD
        SD --> SD1 --> SD2 --> SD3 --> SD4 --> SD5
        SD5 --> SO
    end

    subgraph preprod["Environment: preprod"]
        direction TB
        PT[Trigger: passed sandbox]
        PI[Input: sandbox-cache]
        PD[preprod-deployment]
        PD1[Propagate sandbox cache]
        PD2[Merge cached + preprod files]
        PD3[Deploy, cache, errands...]
        PO[Output: preprod-cache]

        PT --> PI --> PD
        PD --> PD1 --> PD2 --> PD3 --> PO
    end

    subgraph prod["Environment: prod"]
        direction TB
        RT[Trigger: passed preprod]
        RI[Input: preprod-cache]
        RD[prod-deployment...]

        RT --> RI --> RD
    end

    SO --> PT
    PO --> RT
```

---

## Key Architectural Patterns

### Hierarchical File Naming

Files named with environment hierarchy enable automatic relationship detection:
- Pattern: `<org>-<region>-<zone>-<stage>[-<variant>].yml`
- Common prefix = shared configuration
- Additional tokens = environment-specific

### Cache-Based Propagation

- Prevents unvetted changes from propagating downstream
- Ensures deterministic deployments
- Supports complex multi-region topologies

### Trigger Chains

- Each environment can trigger multiple downstream environments
- But each environment can only be triggered by ONE upstream
- Layout DSL: `sandbox -> preprod -> prod`

### Atomic Commits

- Each stage has atomic git commits
- State files committed even on failure (for proto-BOSH recovery)

### Vault-Centric Security

- All credentials stored in Vault
- AppRole authentication for pipelines
- Spruce `(( vault ))` references in config

---

## Special Cases

### Proto-BOSH (create-env)

- No previous deployment manifest exists
- State file fetched from git before deployment
- No cloud-config/runtime-config resources
- No BOSH director lock required

### Multi-Region Deployments

- Common configurations shared across regions
- Cache only shares files up to common prefix
- Prevents region-specific config leakage

### Locker Integration

- Prevents BOSH director upgrade during deployment
- Prevents simultaneous deployments to same BOSH
- Optional but recommended for production

---

## Problems with Current System

See [Kickoff Issues.md](./Kickoff%20Issues.md) for detailed analysis of:

1. CLI vs Pipeline behavior mismatch
2. Complex cache system hard to understand/debug
3. Feature gaps (ops/, bin/ propagation)
4. Recovery difficulty from failed deployments
5. Missed/aggregated deployment risks
