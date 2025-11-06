# Genesis::Config Refactoring Plan

**Status**: Planned
**Priority**: High
**Complexity**: Medium-High
**Estimated Effort**: 2-3 days

## Executive Summary

Genesis::Config requires two major refactorings:

1. **Source Tracking**: Separate storage from computation to prevent defaults/env vars from being saved to disk
2. **Schema Integration**: Move from manual validation to automatic validation with schema attachment at construction

These refactorings will improve correctness (save only explicit values), developer experience (automatic validation), and maintainability (clearer separation of concerns).

---

## Problem Statement

### Current Issues

#### 1. Defaults Written to Disk
**Problem**: When `validate()` is called with a schema containing defaults, those defaults are added to `_contents` via `set()` and subsequently saved to disk.

**Impact**:
- Config files bloat with default values
- Difficult to distinguish user-set values from defaults
- Schema changes require manual config file updates
- Source of truth becomes ambiguous (schema vs file)

**Example**:
```perl
my $config = Genesis::Config->new($path);
$config->validate($schema);  # Adds defaults to _contents
$config->save();             # Writes defaults to file (WRONG!)
```

#### 2. Passive Validation
**Problem**: Validation is manual - caller must remember to call `validate($schema)` explicitly.

**Impact**:
- Easy to forget validation
- Schema passed every time, not associated with config
- No validation on load or save
- Invalid configs can be created and persisted

**Example**:
```perl
my $config = Genesis::Config->new($path);
$config->set('invalid_key', 'value');  # No validation
$config->save();  # Persists invalid config (WRONG!)
```

---

## Proposed Solution

### Part 1: Source Tracking Refactoring

#### Internal Structure Change
```perl
# Current: Simple hash
$self->{contents} = {
    foo => 'bar',
    with_default => 'default_value',  # Can't tell if set or default
};

# Proposed: Source-tracked hash
$self->{contents} = {
    foo => {
        value => 'bar',
        source => 'loaded',  # loaded | set | env | default
    },
    with_default => {
        value => 'default_value',
        source => 'default',
    },
};
```

#### New Methods

**`get_source($key)` - Returns value source**
```perl
$config->get_source('foo');  # 'loaded', 'set', 'env', or 'default'
```

**`get_all()` - Returns all effective values**
```perl
# Includes all sources (loaded + set + env + defaults)
my $all = $config->get_all();
```

**`is_set($key)` - Checks if explicitly loaded or set**
```perl
$config->is_set('foo');              # true  (loaded from file)
$config->is_set('with_default');     # false (only default)
$config->is_set('env_override');     # false (env var)
```

**`_explicit_contents()` - Private method for save()**
```perl
# Returns only loaded + set sources (what should be saved)
my $to_save = $config->_explicit_contents();
```

#### Priority Resolution
Priority order in `get()`: **env > set > loaded > default**

#### Modified Methods

**`validate($schema)` - No longer modifies _contents**
```perl
# Current: Calls $self->set() for defaults
# Proposed: Only validates, doesn't modify contents
```

**`get($key)` - Computes defaults on-demand**
```perl
# Check priority: env → set → loaded → default
# Return value without modifying _contents
```

**`save()` - Only writes explicit values**
```perl
# Use _explicit_contents() to get only loaded/set values
# Never writes defaults or env overrides
```

#### Test Coverage
Comprehensive TDD tests already written in `t/unit-tests/genesis_config-core.t`:
- 21 subtests covering all functionality
- New methods wrapped in SKIP blocks for incremental implementation
- Tests for save behavior (ensures defaults not written)
- Tests for priority resolution
- Tests for source tracking

---

### Part 2: Schema Integration Refactoring

#### Constructor Enhancement

**Hybrid Constructor** - Supports both old positional and new named params:

```perl
# Old style (backward compatible)
Genesis::Config->new($path);
Genesis::Config->new($path, $autosave);
Genesis::Config->new($path, $autosave, $content);

# New style (named parameters)
Genesis::Config->new(
    path => $path,
    schema => $schema,          # NEW: attach schema
    autosave => 1,
    content => {},
    validate_on_load => 1,      # NEW: auto-validate on load
    validate_on_save => 1,      # NEW: auto-validate on save
    validate_on_set => 0,       # NEW: validate individual sets (opt-in)
);
```

#### When to Validate

**Always Validate (if schema provided):**
1. **On Load** - When `_contents` first accessed/loaded from file
2. **Before Save** - Catch invalid state before persisting

**Optional Validate:**
3. **On Set** - Can be enabled, but may be too aggressive for partial configs

#### Implementation Pattern

```perl
sub new {
    my $class = shift;
    my ($path, %opts);

    # Detect old vs new style
    if (@_ == 0) {
        $path = undef;
    } elsif (@_ == 1 && !ref($_[0])) {
        $path = $_[0];
    } elsif (@_ >= 2 && $_[0] !~ /^(path|schema|content|autosave|validate_on_\w+)$/) {
        # Old style positional
        ($path, $opts{autosave}, $opts{content}) = @_;
    } else {
        # New style named params
        %opts = @_;
        $path = delete $opts{path};
    }

    return bless({
        path => $path,
        schema => $opts{schema},
        validate_on_load => $opts{validate_on_load} // 1,
        validate_on_save => $opts{validate_on_save} // 1,
        validate_on_set => $opts{validate_on_set} // 0,
        # ... existing fields
    }, $class);
}

sub _contents {
    my $self = shift;
    unless ($self->{contents_loaded}) {
        # Load from file...
        $self->{contents_loaded} = 1;
        $self->_validate if $self->{schema} && $self->{validate_on_load};
    }
    return $self->{contents};
}

sub save {
    my $self = shift;
    $self->_validate if $self->{schema} && $self->{validate_on_save};
    # Use _explicit_contents() to only save loaded/set values
    # ... existing save logic
}

sub _validate {
    my $self = shift;
    return unless $self->{schema};
    # Call existing validate() logic but don't modify _contents
}
```

---

## Current Usage Audit

### Production Code (4 occurrences)
All use simple path-only style - **no breaking changes needed**:

1. `lib/Genesis/Config.pm:468` - `Genesis::Config->new($self->{path})`
2. `lib/Genesis/Top.pm:896` - `Genesis::Config->new($self->path(".genesis/config"))`
3. `lib/Genesis/Top.pm:1149` - `Genesis::Config->new()`
4. `lib/Genesis/Helpers.pm:25` - `Genesis::Config->new($ENV{HOME}."/.genesis/config")`

### Test Code (47+ occurrences)
Mix of styles - **tests can be freely updated**:

- **Path only**: ~37 occurrences
- **Path + autosave**: 1 occurrence (`t/e2e-tests/init.t:24`)
- **Path + autosave + content**: 5 occurrences (`t/unit-tests/genesis-core.t`)

---

## Implementation Plan

### Phase 1: Source Tracking (Core Refactoring)
**Goal**: Fix save() behavior - don't write defaults/env vars

**Steps**:
1. ✅ Create comprehensive TDD tests (DONE - 21 subtests in genesis_config-core.t)
2. Change internal `_contents` structure to track sources
3. Implement `get_source()` method
4. Implement `get_all()` method
5. Implement `is_set()` method
6. Implement `_explicit_contents()` private method
7. Modify `validate()` to not call `set()` for defaults
8. Modify `get()` to compute defaults on-demand with priority resolution
9. Modify `save()` to use `_explicit_contents()`
10. Run tests incrementally as methods are implemented (red-green-refactor)

**Success Criteria**:
- All 21 subtests in genesis_config-core.t pass
- `save()` only writes loaded/set values
- Defaults accessible via `get()` but not saved
- Source tracking works for all value types

**Estimated Effort**: 1-2 days

### Phase 2: Schema Integration
**Goal**: Automatic validation with schema attachment

**Steps**:
1. Implement hybrid constructor (old + new styles)
2. Add schema storage in blessed object
3. Add validation flags (validate_on_load, validate_on_save, validate_on_set)
4. Implement auto-validation in `_contents()` (on load)
5. Implement auto-validation in `save()` (before save)
6. Update Genesis::Top to pass schema at construction
7. Keep manual `validate()` for backward compatibility

**Success Criteria**:
- Hybrid constructor tests pass (already written, currently skipped)
- Old-style calls continue working (backward compatibility)
- New-style calls work with schema parameter
- Auto-validation prevents invalid configs
- Genesis::Top uses new schema parameter

**Estimated Effort**: 1 day

### Phase 3: Test Migration (Optional, Can Be Done Incrementally)
**Goal**: Modernize test code to use new named-params style

**Steps**:
1. Update `t/e2e-tests/init.t` (1 occurrence)
2. Update `t/unit-tests/genesis-core.t` (5 occurrences)
3. Update other test files as encountered (~37 occurrences)

**Success Criteria**:
- All test files use new named-params style
- Tests remain passing throughout migration
- Better test readability and maintainability

**Estimated Effort**: 0.5 days (spread over time)

---

## Backward Compatibility

### Guaranteed Compatibility
- ✅ All existing positional parameter calls work unchanged
- ✅ `validate($schema)` manual calls continue working
- ✅ Existing production code requires zero changes
- ✅ Old test code works without modification

### Migration Path
- New schema parameter is **opt-in**
- Auto-validation only happens if schema provided
- Named parameters are **optional**, not required
- Gradual migration supported - mix old and new styles

---

## Risk Assessment

### Low Risk
- ✅ Comprehensive TDD test coverage already in place
- ✅ Backward compatibility maintained via hybrid constructor
- ✅ Production code uses simplest patterns (path-only)
- ✅ Can be implemented incrementally (source tracking → schema → tests)

### Medium Risk
- Internal structure change (`_contents` format) affects all get/set operations
- Must ensure cache invalidation works correctly with new structure
- Need to verify all code paths handle source-tracked values

### Mitigation
- Run full test suite after each phase
- Keep manual `validate()` method as fallback
- Extensive testing of edge cases (nested keys, arrays, etc.)
- Can roll back changes per-phase if issues detected

---

## Testing Strategy

### Unit Tests (Already Written)
`t/unit-tests/genesis_config-core.t` - 21 comprehensive subtests:

1. ✅ Constructor backward compatibility (old-style positional params)
2. ⏸️ Constructor new named parameters (SKIPPED until Phase 2)
3. Basic config creation and loading
4. Setting values explicitly
5. Environment variable overrides
6. Schema defaults
7. Priority resolution: env > set > loaded > default
8. Save behavior - only explicit values (core refactoring goal)
9. Modifying loaded values
10. Contents methods (`get_all()`, `_explicit_contents()`)
11. `has()` and `is_set()` methods
12. Validation does not modify explicit contents
13-21. Existing method coverage (path, exists, loaded, changed, clear, replace, show_diff, get, set)

### Integration Tests
- Genesis::Top config loading/validation
- Full deployment repo config lifecycle
- Kit compilation config handling

### Manual Testing
- Create repo, modify .genesis/config, verify only explicit values saved
- Test env var overrides don't persist to file
- Verify schema defaults available but not saved

---

## Code Changes Summary

### Files to Modify

**Primary Changes**:
1. `lib/Genesis/Config.pm` (~200 lines changed)
   - Constructor: +35 lines (hybrid detection logic)
   - Internal structure: modify `_contents` to track sources
   - New methods: `get_source()`, `get_all()`, `is_set()`, `_explicit_contents()`
   - Modified methods: `validate()`, `get()`, `save()`

**Secondary Changes**:
2. `lib/Genesis/Top.pm` (2 lines changed)
   - Line 896: Add schema parameter to Config construction
   - Line 1149: Optionally add schema to new config

**Test Changes**:
3. `t/unit-tests/genesis_config-core.t` (already updated)
   - Enable skipped constructor tests when Phase 2 complete

**Optional Changes** (Phase 3):
4. Various test files - migrate to named-params style

---

## Success Metrics

### Functional
- ✅ Config files no longer contain default values
- ✅ Environment variable overrides don't persist to disk
- ✅ Schema defaults always available via `get()`
- ✅ Invalid configs rejected before save
- ✅ All existing functionality preserved

### Code Quality
- ✅ 100% of genesis_config-core.t tests passing
- ✅ No regressions in existing tests
- ✅ Clear separation: storage vs computation
- ✅ Backward compatible API

### Developer Experience
- ✅ Automatic validation prevents invalid configs
- ✅ Schema attached at construction (no manual validate calls needed)
- ✅ Clear API for checking value sources
- ✅ Easier to understand what gets saved vs computed

---

## References

- **Test File**: `t/unit-tests/genesis_config-core.t`
- **Implementation**: `lib/Genesis/Config.pm`
- **Usage**: `lib/Genesis/Top.pm`, `lib/Genesis/Helpers.pm`
- **Related**: Genesis::Top refactoring (config validation on load)

---

## Notes

- Tests are already written and properly structured for red-green-refactor TDD
- Constructor tests exist but are skipped pending Phase 2 implementation
- All production code uses simple patterns - minimal impact
- Can implement Phase 1 (source tracking) independently of Phase 2 (schema integration)
- Phase 3 (test migration) is optional and can be done over time

---

**Last Updated**: 2025-11-06
**Author**: Claude Code Session
**Status**: Ready for Implementation
