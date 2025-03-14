# Genesis Environment Variables Reference

## Core Variables

### GENESIS_VERSION
- Current version of Genesis being used
- Set internally during startup
- Set by: Genesis::Init() in bin/genesis
- Used by:
  - Genesis::Commands::Env (check prereqs)
  - Genesis::Kit (version compatibility checks)
  - Genesis::Config (version checks)

### GENESIS_LIB
- Path to Genesis library directory
- Can be overridden to use alternate library location
- Defaults to bin/lib under Genesis installation directory 
- Set by: bin/genesis startup
- Used by:
  - Genesis::Kit::Provider (loading kit modules)
  - Genesis::Commands (loading command modules)
  - Genesis::Top (finding library components)

### GENESIS_CALLBACK_BIN
- Path to Genesis binary for callbacks
- Defaults to path of currently executing Genesis binary
- Set by: bin/genesis startup
- Used by: 
  - Genesis::Kit::Helper (executing callbacks)
  - Genesis::Commands::Pipeline (ci commands)

## Configuration 

### GENESIS_CONFIG_NO_CHECK
- When set to 1, skips configuration validation checks
- Used by deploy command with --no-config flag
- Set by: Genesis::Commands::Env::deploy
- Used by:
  - Genesis::Kit::Compiler (config validation)
  - Genesis::Config (validation skipping)

## Operational Control

### GENESIS_SHOW_TIMINGS
- Enables timing output for operations when set
- Shows duration of key operations
- Set by: User/Environment
- Used by:
  - Genesis::Log (timing output)
  - Genesis::Commands::deploy (operation timing)

### GENESIS_NO_UTF8
- Disables UTF-8 output when set
- Useful for environments with limited character support
- Set by: User/Environment 
- Used by:
  - Genesis::Term (character output control)
  - Genesis::UI (display formatting)

### GENESIS_QUIET
- Reduces output verbosity when set
- Only shows errors and critical information
- Set by: Command line options
- Used by:
  - Genesis::Log (output verbosity control)
  - Genesis::Commands (reduced output)
  - bin/genesis END block (log level control)

### GENESIS_LOG_STYLE
- Controls output style formatting
- Values: plain, color, html
- Defaults to 'plain' if unset
- Set by: User config/Environment
- Used by:
  - Genesis::Log (output formatting)
  - Genesis::UI (display styling)
  - bin/genesis END block (log style control)

## Development/Testing

### GENESIS_DEV_MODE
- Enables development mode features
- Provides additional debugging output
- Shows stack traces on errors
- Set by: User/Environment
- Used by:
  - bin/genesis (stack trace control)
  - Genesis::Base (debug output)
  - Genesis::Kit::Dev (development features)

### GENESIS_UNDER_TEST
- Indicates Genesis is running under test harness
- Modifies behavior for testing environment
- Set by: Test harness
- Used by:
  - bin/genesis (test mode control)
  - Genesis::Base (test behavior modifications)
  - Genesis::Commands (test adaptations)

## Path Management

### GENESIS_CALLER_DIR 
- Original directory where Genesis was invoked
- Used to maintain context for relative paths
- Set by: bin/genesis main()
- Used by:
  - Genesis::Top (path resolution)
  - Genesis::Kit (finding kit files)
  - Genesis::Commands::Env (environment paths)

### GENESIS_DEPLOYMENT_ROOT
- Root directory of current deployment
- Set when using @-notation for environments
- Set by: bin/genesis @-notation handling
- Used by:
  - Genesis::Top (repository location)
  - Genesis::Env (environment files)
  - Genesis::Commands::Pipeline (deployment paths)

## Cloud Config

### GENESIS_CLOUD_CONFIG_SUBTYPE
- Specifies cloud config subtype when generating configs
- Used by cloud-config hooks
- Set by: Genesis::Hook::CloudConfig hooks
- Used by:
  - Genesis::Hook::CloudConfig (config type control)
  - Genesis::Commands::deploy (cloud config generation)

## Prefix Type Control

### GENESIS_PREFIX_TYPE
- Controls how environment prefixes are handled
- Values: none, search, option_c, file, explicit_file
- Set by: bin/genesis main() argument parsing
- Used by:
  - Genesis::Top (path handling)
  - Genesis::Env (environment resolution)
  - Genesis::Commands (path behavior)

### GENESIS_PREFIX_SEARCH
- Search pattern when using @-notation
- Format: @<env-match>[:deployment-match]
- Set by: bin/genesis @-notation handling
- Used by:
  - Genesis::Top (repository search)
  - Genesis::Env (environment search)

## Target Management

### GENESIS_TARGET_VAULT
- Target Vault for operations
- Used during callback operations
- Set by: Genesis::Commands::pipeline
- Used by:
  - Genesis::Vault (vault targeting)
  - bin/genesis (vault operations)

### GENESIS_DEFAULT_BOSH_TARGET 
- Default BOSH target when not explicitly specified
- Values: parent, self
- Set by: Genesis::Commands::Env bosh operations
- Used by:
  - Genesis::BOSH (target resolution)
  - Genesis::Commands::deploy (BOSH operations)

## CI/CD Pipeline Variables

### GENESIS_PIPELINE_DEPLOY_BRANCH
- Git branch for pipeline deployments
- Used by CI pipeline operations
- Set by: Genesis::Commands::Pipeline::repipe
- Used by:
  - Genesis::CI (pipeline configuration)
  - Genesis::Commands::Pipeline (deployment)

## Command Output Control

### GENESIS_OUTPUT_COLUMNS
- Controls width of text output
- Defaults to terminal width if unset
- Set by: User config/Environment
- Used by:
  - Genesis::Term (output formatting)
  - Genesis::UI (display width)
  - Genesis::Log (message wrapping)

Note: Some variables may have additional uses in kit hooks or user scripts. This documents the core Genesis codebase usage.
