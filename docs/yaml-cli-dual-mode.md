# YAML CLI Dual Mode

Genesis supports a special "dual mode" for YAML processing that runs both `spruce` and `graft` processors simultaneously, allowing you to compare their behavior and validate compatibility during regular Genesis operations.

## Overview

When `yaml_cli` is set to `dual`, Genesis will:

1. Run both `spruce` and `graft` for every YAML operation
2. Use `spruce` output as the safe default for actual operations
3. Log all inputs, outputs, and comparisons for later analysis
4. Store logs in `~/.genesis/logs/yaml-cli/` with timestamped session directories

## Configuration

### Enabling Dual Mode

Dual mode can ONLY be enabled via configuration file (not command line):

**Repository-level** (`.genesis/config`):
```yaml
yaml_cli: dual
```

**User-level** (`~/.genesis/config`):
```yaml
yaml_cli: dual
```

**Note**: The `--yaml-cli` command line option accepts `dual` but it's intended for configuration file use only, as dual mode generates significant logging data.

### Requirements

Both `spruce` and `graft` must be installed and available in your PATH for dual mode to work.

## Log Structure

When dual mode is active, Genesis creates a logging directory structure:

```
~/.genesis/logs/yaml-cli/
└── YYYYMMDD-HHMMSS-PID/          # Session directory
    ├── session.info              # Session metadata
    └── HHMMSS-NNNNNN-command-HASH/  # Operation directory
        ├── input.log             # Command and arguments
        ├── input-file-N.yml      # Input YAML files (if applicable)
        ├── spruce.output         # Spruce stdout
        ├── spruce.error          # Spruce stderr (if any)
        ├── spruce.meta           # Spruce execution metadata
        ├── graft.output          # Graft stdout
        ├── graft.error           # Graft stderr (if any)
        ├── graft.meta            # Graft execution metadata
        ├── comparison.log        # Comparison summary
        └── output.diff           # Differences (if any)
```

## Analysis Tool

Genesis includes `genesis-yaml-cli-analyze` to help analyze dual mode logs:

### List all sessions:
```bash
genesis-yaml-cli-analyze
```

### Analyze a specific session:
```bash
genesis-yaml-cli-analyze --session YYYYMMDD-HHMMSS-PID
```

### Show only differences:
```bash
genesis-yaml-cli-analyze --session SESSION --differences
```

### Show only errors:
```bash
genesis-yaml-cli-analyze --session SESSION --errors
```

### Verbose output:
```bash
genesis-yaml-cli-analyze --session SESSION -v
```

## Use Cases

### 1. Compatibility Testing

Test if `graft` produces identical output to `spruce` for your deployments:

```bash
# Enable dual mode
echo "yaml_cli: dual" >> .genesis/config

# Run normal Genesis operations
genesis manifest my-env
genesis deploy my-env

# Analyze results
genesis-yaml-cli-analyze --session LATEST --differences
```

### 2. Performance Comparison

Compare execution times between processors:

```bash
genesis-yaml-cli-analyze --session SESSION -v | grep "Timing:" -A2
```

### 3. Debugging Differences

When differences are found, examine the detailed logs:

```bash
# Find session with differences
genesis-yaml-cli-analyze --differences

# Examine specific operation
cd ~/.genesis/logs/yaml-cli/SESSION/OPERATION
diff -u spruce.output graft.output
```

## Important Notes

1. **Storage**: Dual mode can generate significant log data. Monitor `~/.genesis/logs/yaml-cli/` and clean up old sessions periodically.

2. **Performance**: Running both processors doubles the YAML processing time. Use dual mode for testing, not production deployments.

3. **Safety**: Genesis always uses the `spruce` output for actual operations in dual mode, ensuring safe behavior even if `graft` produces different results.

4. **Privacy**: Logs may contain sensitive data from your YAML files. Ensure proper access controls on the log directory.

## Example Workflow

```bash
# 1. Enable dual mode for testing
echo "yaml_cli: dual" >> .genesis/config

# 2. Run your normal Genesis workflow
genesis new my-env
genesis manifest my-env
genesis deploy my-env

# 3. Analyze the results
genesis-yaml-cli-analyze

# 4. Investigate any differences
genesis-yaml-cli-analyze --session LATEST --differences -v

# 5. Disable dual mode when done
# Remove the yaml_cli line from .genesis/config
```

## Troubleshooting

### "Dual mode requires both spruce and graft to be available"

Ensure both tools are installed:
```bash
which spruce graft
```

### No logs appearing

Check that:
- Dual mode is enabled in configuration (not just command line)
- The log directory is writable: `~/.genesis/logs/yaml-cli/`
- Genesis operations are actually invoking YAML processing

### Disk space concerns

Clean up old sessions:
```bash
# Remove sessions older than 7 days
find ~/.genesis/logs/yaml-cli -type d -name "20*" -mtime +7 -exec rm -rf {} +
```