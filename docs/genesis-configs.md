# Genesis Configuration

This document describes how to configure Genesis using the `~/.genesis/config` file.

## Overview

Genesis reads configuration from `~/.genesis/config` to customize its behavior. This file uses YAML format and supports various settings that control how Genesis operates across different environments and deployments.

## Configuration File Location

The configuration file should be located at:
```
~/.genesis/config
```

## Configuration Options

### BOSH Target Configuration

#### `default_bosh_target`
Controls the default BOSH director targeting behavior when multiple options are available.

**Type:** enum  
**Default:** `ask`  
**Values:** `ask`, `self`, `parent`  
**Environment Variable:** `GENESIS_DEFAULT_BOSH_TARGET`

```yaml
default_bosh_target: ask
```

- `ask`: Prompt the user to select a BOSH director
- `self`: Use the current environment as the BOSH director
- `parent`: Use the BOSH director that deployed the current environment

***Note:*** BOSH environments that use create-env will always use `self` regardless of this setting, because they have no parent.  Likewise, non-BOSH director environments will always use `parent` because they aren't a BOSH director.

### Repository Configuration

#### `legacy_repo_suffix`
Enable support for legacy repository naming conventions.

**Type:** boolean  
**Default:** `false`  
**Environment Variable:** `GENESIS_LEGACY_REPO_SUFFIX`

```yaml
legacy_repo_suffix: false
```

#### `deployment_roots`
Configure deployment root directories for organizing Genesis repositories. This supports both simple string paths and labeled path mappings.

**Type:** array  
**Default:** `[]`  
**Subtype:** `string||hasharray` (can be a string or a hash of label => path)  
**Environment Variable:** `GENESIS_DEPLOYMENT_ROOTS`  
**Environment Splitting:** Uses `:` to separate multiple entries specified in the environment variable.
**Environment Conversion:** Supports both simple paths and `label=path` pairs separated by `;` in the environment variable.

```yaml
deployment_roots:
  - /home/user/deployments
  - production: /opt/genesis/prod
  - staging: /opt/genesis/staging
```

```bash
export GENESIS_DEPLOYMENT_ROOTS="/home/user/deployments;production=/opt/genesis/prod;staging=/opt/genesis/staging"
```

### Genesis Behavior

#### `embedded_genesis`
Control behavior when Genesis detects an embedded Genesis installation.

**Type:** enum  
**Default:** `ignore`  
**Values:** `ignore`, `check`, `warn`

```yaml
embedded_genesis: ignore
```

- `ignore`: Don't check for embedded Genesis
- `check`: Check for embedded Genesis but don't warn
- `warn`: Check and warn about embedded Genesis

#### `automatic_config_upgrade`
Control automatic upgrading of configuration files.

**Type:** enum  
**Default:** `no`  
**Values:** `no`, `yes`, `silent`  
**Environment Variable:** `GENESIS_CONFIG_AUTOMATIC_UPGRADE`

```yaml
automatic_config_upgrade: no
```

- `no`: Never automatically upgrade configuration
- `yes`: Upgrade configuration with user confirmation
- `silent`: Upgrade configuration without prompting

### Display Configuration

#### `output_style`
Configure the visual style of Genesis output.

**Type:** enum  
**Default:** `plain`  
**Values:** `plain`, `fun`, `pointer`

```yaml
output_style: plain
```

- `plain`: Simple text output without decorations
- `fun`: Enhanced output with emojis and visual elements
- `pointer`: Output with pointer-style indicators

#### `show_duration`
Display command execution duration information.

**Type:** boolean  
**Default:** `false`  
**Environment Variable:** `GENESIS_SHOW_DURATION`

```yaml
show_duration: true
```

### Deployment Behavior

#### `fix_on_deploy`
Control whether Genesis should attempt to fix issues during deployment.

**Type:** enum  
**Default:** `never`  
**Values:** `always`, `ask`, `never`  
**Environment Variable:** `GENESIS_FIX_ON_DEPLOY`

```yaml
fix_on_deploy: ask
```

- `always`: Automatically fix issues without prompting
- `ask`: Prompt before fixing issues
- `never`: Never attempt to fix issues automatically

#### `confirm_release_overrides`
Control when to confirm BOSH release overrides.

**Type:** enum  
**Values:** `always`, `outdated`, `never`  
**Environment Variable:** `GENESIS_CONFIRM_RELEASE_OVERRIDES`

```yaml
confirm_release_overrides: outdated
```

- `always`: Always confirm release overrides
- `outdated`: Only confirm when releases are outdated
- `never`: Never confirm release overrides

### Cache and Storage

#### `spec_cache_dir`
Directory for caching specification files.

**Type:** string  
**Default:** `""`  
**Environment Variable:** `GENESIS_SPEC_CACHE_DIR`

```yaml
spec_cache_dir: "/tmp/genesis-cache"
```

#### `bosh_logs_path`
Path template for storing BOSH deployment logs. The `<DEPLOYMENT_ROOT>` placeholder will be replaced with the actual deployment root path.

**Type:** string  
**Default:** `<DEPLOYMENT_ROOT>/bosh_logs`  
**Environment Variable:** `GENESIS_DEPLOYMENT_LOGS_PATH`

```yaml
bosh_logs_path: "/var/log/genesis/bosh_logs"
```

### Warning Suppression

#### `suppress_warnings`
Configure which warnings to suppress. This is a hash with its own schema for specific warning types.

**Type:** hash

```yaml
suppress_warnings:
  oversized_secrets: false
  bosh_target: false
```

##### `oversized_secrets`
Suppress warnings about secrets that are larger than expected.

**Type:** boolean  
**Default:** `false`  
**Environment Variable:** `GENESIS_SUPRESS_OVERSIZED_SECRETS_WARNING`

##### `bosh_target`
Suppress warnings about BOSH target selection.

**Type:** boolean  
**Default:** `false`  
**Environment Variable:** `GENESIS_SUPPRESS_BOSH_TARGET_WARNING`

### Logging Configuration

#### `logs`
Configure detailed logging behavior for Genesis operations. This is an array of hash objects, each defining a separate log destination with its own configuration.

**Type:** array of hash objects

```yaml
logs:
  - file: "/var/log/genesis/genesis.log"
    level: INFO
    show_stack: default
    truncate: false
    style: plain
    lifespan: forever
    timestamp: true
  - file: "/tmp/genesis-debug.log"
    level: DEBUG
    style: rfc-5424
    lifespan: current
```

Each log entry supports the following schema:

##### `file`
**Type:** string  
**Required:** `true`  
Path to the log file where messages will be written.

##### `level`
**Type:** enum  
**Default:** `INFO`  
**Values:** `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `OUTPUT`  
Minimum log level to record. Messages at this level and above will be logged.

- `TRACE`: Most verbose, includes all internal operations
- `DEBUG`: Detailed debugging information
- `INFO`: General informational messages
- `WARN`: Warning messages
- `ERROR`: Error messages
- `OUTPUT`: Only capture command output

##### `show_stack`
**Type:** enum  
**Default:** `default`  
**Values:** `default`, `none`, `full`, `current`, `fatal`  
Controls when and how stack traces are displayed in log messages.

- `default`: Show stack traces based on log level defaults
- `none`: Never show stack traces
- `full`: Always show full stack traces
- `current`: Show current execution context only
- `fatal`: Only show stack traces for fatal errors

##### `style`
**Type:** enum  
**Default:** `plain`  
**Values:** `plain`, `fun`, `pointer`, `rfc-5424`  
Log message formatting style.

- `plain`: Simple text format
- `fun`: Enhanced format with colors and emojis
- `pointer`: Format with pointer-style indicators
- `rfc-5424`: Standard RFC-5424 syslog format

##### `timestamp`
**Type:** boolean  
**Default:** `false`  
Whether to include timestamps in log entries.

#### Future Logging Options - not yet implemented

These future options are currently placeholders and will be implemented in future releases.  They have no effect, but they will not cause errors if included in the configuration file.

##### `truncate`
**Type:** boolean  
**Default:** `false`  (Currently defaults to `true` in effect, as this is not implemented yet)
Whether to truncate (clear) the log file when Genesis starts up.

##### `lifespan`
**Type:** enum  
**Default:** `forever`  
**Values:** `forever`, `current`, `N days`
How long to retain log entries.

- `forever`: Keep log entries indefinitely
- `current`: Only keep entries for the current Genesis session (ie truncate is effectively `true`)
- `N days`: Keep log entries for the specified number of days (e.g., `7 days`)

## Example Configuration

Here's a complete example configuration file demonstrating all available options:

```yaml
# ~/.genesis/config

# BOSH targeting
default_bosh_target: ask

# Repository management
legacy_repo_suffix: false
deployment_roots:
  - /home/genesis/deployments
  - production: /opt/genesis/prod
  - staging: /opt/genesis/staging
  - development: /tmp/genesis-dev

# Display preferences
output_style: fun
show_duration: true

# Deployment behavior
fix_on_deploy: ask
confirm_release_overrides: outdated

# Cache and storage
spec_cache_dir: "/tmp/genesis-cache"
bosh_logs_path: "/var/log/genesis/<DEPLOYMENT_ROOT>/bosh_logs"

# Warning suppression
suppress_warnings:
  oversized_secrets: false
  bosh_target: true

# Genesis behavior
embedded_genesis: warn
automatic_config_upgrade: yes

# Comprehensive logging setup
logs:
  # Main application log
  - file: "/var/log/genesis/genesis.log"
    level: INFO
    timestamp: true
    style: plain
    lifespan: forever
    show_stack: default
    truncate: false
    
  # Debug log for troubleshooting
  - file: "/tmp/genesis-debug.log"
    level: DEBUG
    style: rfc-5424
    lifespan: current
    truncate: true
    timestamp: true
    show_stack: full
    
  # Error-only log
  - file: "/var/log/genesis/errors.log"
    level: ERROR
    style: plain
    lifespan: forever
    timestamp: true
    show_stack: fatal
```

## Environment Variable Overrides

Many configuration options can be overridden using environment variables. When an environment variable is set, it takes precedence over the configuration file setting. The following environment variables are supported:

- `GENESIS_DEFAULT_BOSH_TARGET`
- `GENESIS_LEGACY_REPO_SUFFIX`
- `GENESIS_SHOW_DURATION`
- `GENESIS_CONFIG_AUTOMATIC_UPGRADE`
- `GENESIS_FIX_ON_DEPLOY`
- `GENESIS_CONFIRM_RELEASE_OVERRIDES`
- `GENESIS_SPEC_CACHE_DIR`
- `GENESIS_DEPLOYMENT_LOGS_PATH`
- `GENESIS_DEPLOYMENT_ROOTS`
- `GENESIS_SUPRESS_OVERSIZED_SECRETS_WARNING`
- `GENESIS_SUPPRESS_BOSH_TARGET_WARNING`

## Configuration Validation

Genesis validates the configuration file on startup using a comprehensive schema. If there are validation errors, Genesis will report them and may refuse to run until the configuration is corrected. The validation ensures:

- All enum values are from the allowed set
- Boolean values are properly formatted
- Required fields are present
- Array and hash structures match expected schemas
- Environment variable conversions are properly formatted

## Advanced Configuration

### Deployment Roots with Labels

The `deployment_roots` configuration supports both simple paths and labeled mappings. This is particularly useful when working with multiple environments:

```yaml
deployment_roots:
  - /home/user/simple-path
  - prod: /opt/production/deployments
  - staging: /opt/staging/deployments  
  - dev: /tmp/dev-deployments
```

Labels allow you to reference deployment roots by name in Genesis commands, making it easier to switch between different deployment contexts.

### Complex Logging Scenarios

You can configure multiple log destinations for different purposes:

```yaml
logs:
  # Audit trail - everything at INFO level
  - file: "/var/log/genesis/audit.log"
    level: INFO
    style: rfc-5424
    timestamp: true
    lifespan: forever
    
  # Development debugging
  - file: "/tmp/genesis-trace.log"
    level: TRACE
    style: plain
    show_stack: full
    lifespan: current
    truncate: true
    
  # Error monitoring
  - file: "/var/log/genesis/errors.log"
    level: ERROR
    style: plain
    timestamp: true
    show_stack: fatal
```

## Upgrading Configuration

When `automatic_config_upgrade` is enabled, Genesis may automatically update your configuration file to support new features or fix deprecated settings. The upgrade behavior depends on the setting:

- `no`: Configuration is never automatically modified
- `yes`: Genesis will prompt before making changes
- `silent`: Changes are applied automatically without prompting

It's recommended to keep backups of your configuration file when enabling automatic upgrades.
