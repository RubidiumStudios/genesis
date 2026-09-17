# Writing a Provider

A provider is the class that answers for one CI platform, and the compiler it hands out is the class that translates the generic pipeline from the AST into that platform's own configuration. This document explains how to write both, by walking through the two contracts, the available helpers, and the patterns the Concourse provider and its compiler follow.

## The Two Classes

A platform takes one class on each side, and each class inherits from one base.

| Class | Base | What it answers for |
|-------|------|---------------------|
| `Genesis::CI::Provider::MyPlatform` | `Genesis::CI::Provider` | The configuration block, the capabilities, and the toolchain |
| `Genesis::CI::ProviderCompiler::MyPlatform` | `Genesis::CI::ProviderCompiler` | The artefact emitted from an AST |

The provider hands out the compiler and the compiler holds the provider that handed it out. Neither class inherits from the other, and neither one is reached except through `Genesis::CI::ProviderRegistry`.

```perl
package Genesis::CI::ProviderCompiler::MyPlatform;
use parent 'Genesis::CI::ProviderCompiler';

use Genesis;
```

Every package under `lib` sits at the path its name derives, so the file above is `lib/Genesis/CI/ProviderCompiler/MyPlatform.pm` and its provider is `lib/Genesis/CI/Provider/MyPlatform.pm`. The registry works the path out from the class name, so there is no path to write down anywhere.

## Required Compiler Methods

You must implement four methods from `Genesis::CI::ProviderCompiler`.

### platform_name

Returns a human-readable name for your platform. This appears in log messages and error output.

```perl
sub platform_name { return "My Platform" }
```

### provider_type

Returns the canonical type string, which is the same string the registry keys your entry under and the same string an operator writes as `pipeline.provider.type`.

```perl
sub provider_type { 'my-platform' }
```

### generate_from_ast

This is the main compilation method. It receives a fully-populated AST (with both source representation and generic pipeline resolved) and must return either a YAML string or a hashref mapping filenames to content strings.

```perl
sub generate_from_ast {
    my ($self, $ast) = @_;

    # Read the generic pipeline
    my $resource_types = $ast->resource_types;   # arrayref
    my $resources      = $ast->pipeline_resources; # arrayref
    my $jobs           = $ast->jobs;             # arrayref
    my $groups         = $ast->groups;           # arrayref

    # Serialize to your platform's format
    my $yaml = $self->dump_yaml({
        resource_types => $resource_types,
        resources      => $resources,
        jobs           => $jobs,
        groups         => $groups,
    });

    return "---\n$yaml\n";
}
```

If your platform produces several files rather than one, return a hashref instead, and declare `multi_file_output` as true on the provider. That capability gates no key of its own, because the key it would gate is declared by the provider that can use it and by nobody else, so a provider that cannot simply offers no such key:

```perl
return {
    'deploy.yml'    => $deploy_yaml,
    'notify.yml'    => $notify_yaml,
};
```

### output_files

Returns a hashref describing what files your compiler writes. The keys are filenames and the values are human-readable descriptions.

```perl
sub output_files {
    return { 'pipeline.yml' => 'My Platform pipeline definition' };
}
```

## Required Provider Methods

The provider class answers for the configuration block and the toolchain. Two of its methods are abstract on the base, so a provider that leaves either one out fails at configuration load rather than at run time.

### provider_options_schema

Declares the keys your provider takes under `pipeline.provider`, in the shape Top's repository schema uses, so the configuration layer can merge them in and validate them for you. A key's `default` is declared here and nowhere else, because the compiler reads it back through `provider_option`.

```perl
sub provider_options_schema {
    return {
        target => {type => 'string', description => 'The platform target'},
        team   => {type => 'string', default => 'main', description => 'Team name'},
    };
}
```

### capabilities

Declares what your provider is able to do, as the six booleans the base names, so a key whose ability your provider lacks is refused at load rather than discovered at run time.

```perl
sub capabilities {
    return {
        deployment_locks      => 1,
        cross_pipeline_events => 1,
        optional_git_triggers => 1,
        scheduled_jobs        => 1,
        per_commit_runs       => 1,
        multi_file_output     => 0,
    };
}
```

All six names have to be present, and the base checks the declaration against its own list, so a name misspelled or left out is caught rather than read as a no.

### validate_config

Applies your provider's own rules to the block an operator wrote. The base declares the shape and this is where anything the shape cannot express goes.

### check_prereqs

Answers whether the toolchain your provider needs is present, returning true when it is and calling `error()` and returning false when it is not. The base answers true, which is the honest answer for a provider that needs no tool, so override this only when there is a tool to look for.

```perl
sub check_prereqs {
    my ($self) = @_;
    my ($path) = run({stderr => 0}, 'type -p myplatform');
    chomp($path //= '');
    return 1 if $path;
    error("The my-platform provider requires the #C{myplatform} CLI.");
    return 0;
}
```

A floor that cannot be compared against is a floor that is not enforced, so if you check a version, refuse by name when the tool prints something you cannot read rather than carrying on past it.

## Construction

You do not write a constructor on the compiler side. The base builds every compiler, and a caller reaches it through the provider.

```perl
my $provider = Genesis::CI::Provider->new(type => 'my-platform', %block);
my $compiler = $provider->compiler(ast => $ast, top => $top);
```

The base blesses the provider, the AST, the `Genesis::Top` object, and the provider options, and it refuses a call that names no AST, because a compiler blessed over an undefined AST fails much later and says far less about why. Your compiler can ask for the provider that built it at any time with `$self->provider`.

## Registering Your Provider

There is one registry and one entry. Add it to `%_providers` in `Genesis::CI::ProviderRegistry`.

```perl
'my-platform' => {
    class     => 'Genesis::CI::ProviderCompiler::MyPlatform',
    cli_class => 'Genesis::CI::Provider::MyPlatform',
},
```

An entry names its classes and nothing else. The registry works each file path out from the class beside it, so a path written here would be a second spelling of the same fact, and the two could disagree. Leave `class` out entirely if your platform has nothing to emit, which is what the manual provider does.

The schema's enum, every class lookup, and every message that lists the valid types all read this one map, so an entry added here is an entry every reader sees. There is no second place to register it.

A provider shipping outside the tree calls `register_provider` at run time instead, which takes the same shape and refuses four things. A missing name would register the entry where nothing could look it up. A name already registered is refused rather than replaced. An entry with no `cli_class` is refused, because a resolver that finds none behaves like `manual` instead of saying so. And a file path that disagrees with the class beside it is refused rather than honoured.

## Available Helpers

The `ProviderCompiler` base class provides several helpers you can use:

### dump_yaml

Serializes a Perl data structure to YAML without requiring an external YAML module. Handles hashes, arrays, scalars, booleans (`JSON::PP::Boolean`), multi-line strings (using `|` block scalar), and proper quoting of strings that could be confused with YAML keywords.

```perl
my $yaml = $self->dump_yaml($data_structure);
```

Be aware that this serializer sorts hash keys alphabetically, uses two-space indentation, and does not produce flow-style collections. A compiler that needs a more capable serializer can use `YAML::PP` directly, but that introduces an external dependency the rest of the tree does not carry.

### git_uri

Builds a Git URI from the source control configuration. Handles GitHub (`git@github.com:org/repo.git`), GitLab (`git@gitlab.com:org/repo.git`), explicit `uri` fields, and bare repository strings.

```perl
my $uri = $self->git_uri($ast->integrations->{source_control});
```

### secret_ref

Formats a secret reference for your platform. The default implementation returns Concourse-style `(($ref))` interpolation. Override this if your platform uses a different syntax.

```perl
sub secret_ref {
    my ($self, $ref) = @_;
    # GitHub Actions style
    return '${{ secrets.' . uc($ref) . ' }}';
}
```

### topological_sort

Performs a topological sort on a workflow graph. Takes a graph hashref with `nodes` and `edges` keys and returns an ordered list of node names. Bails on cycles.

```perl
my @order = $self->topological_sort($workflow->{graph});
```

### matches_pattern

Checks if a name matches a glob pattern (`*` matches any sequence, `?` matches one character).

```perl
if ($self->matches_pattern('us-sandbox', '*-sandbox')) { ... }
```

## Accessing Source Data

While a compiler should primarily read the generic pipeline (via `$ast->resource_types`, `$ast->pipeline_resources`, `$ast->jobs`, `$ast->groups`), there are cases where you need source data. A compiler that has to set up its own vault authentication steps reads `$ast->integrations`, and one that has to name its output reads `$ast->metadata`.

The source accessors are: `$ast->branches`, `$ast->integrations`, `$ast->targets`, `$ast->workflows`, `$ast->configuration`, `$ast->provider_config`.

## Example: The Concourse Compiler

The Concourse compiler in `_generate_native()` is a minimal serializer:

```perl
sub _generate_native {
    my ($self, $ast) = @_;
    $self->_ensure_pipeline_resolved();
    my $pipeline = {
        groups         => $ast->groups,
        resources      => $ast->pipeline_resources,
        resource_types => $ast->resource_types,
        jobs           => $ast->jobs,
    };
    return "---\n" . $self->dump_yaml($pipeline) . "\n";
}
```

It reads the four generic pipeline arrays and dumps them to YAML. The `_ensure_pipeline_resolved()` call is a safety check that runs PipelineDescriptor if the generic pipeline has not been built yet.

The `generate_from_ast()` method in Concourse also has the legacy bridge path for backward compatibility, but a new compiler would not need that.

## Testing Your Provider

Place the two files at the paths their package names derive, which are `lib/Genesis/CI/Provider/MyPlatform.pm` and `lib/Genesis/CI/ProviderCompiler/MyPlatform.pm`. There is no `--platform` flag to select a provider with, so set `pipeline.provider.type` to `my-platform` in `.genesis/config` and run:

```bash
genesis pipeline-apply --dry-run
```

Use `--debug-dir` to inspect intermediate artifacts and verify that your compiler receives the expected AST data. Use `--output-dir` to write all generated files to disk for manual review.
