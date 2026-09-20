# Module Reference

This document catalogs every Perl module in the Genesis CI system, its purpose, its public API, and its relationships with other modules. The compiler half comes first, in dependency order, with the foundational modules before the modules that depend on them, and the propagation half follows it. Every module's own `.pod` beside it is the full reference, and the entries here say what each one is for.

## Genesis::CI::ProviderRegistry

**File:** `lib/Genesis/CI/ProviderRegistry.pm`

**Purpose:** The one map of provider types to classes. It sits in neither family because both consult it. The provider side asks which class answers for a type, and the compiler side asks which class emits for one. An entry names its classes and nothing else, because every package under `lib` derives its own file path, so a path written beside a class would be a second spelling of the same fact.

**Public API:**

- `known_providers()`
  every registered type, sorted. The configuration schema's enum, every class lookup, and every valid-types message read this, so a provider cannot be spelled one way in the schema and another in the code.

- `provider_info($type)`
  one entry as a shallow copy, or undef. `cli_class` and `cli_file` name the class the CLI builds, which every type has. `class` and `file` name the compiling class, which the manual and GitHub Actions providers do not have. Each path is worked out from the class beside it rather than read from the entry.

- `automated_providers()`
  every type that is not `manual`, so no caller writes that exclusion by hand.

- `register_provider($type, $info)`
  adds an entry at run time, for a test that stands a class up and for a provider shipping outside the tree. Refuses a missing name, a name already registered, an entry with no `cli_class`, and a file path that disagrees with the class beside it.

- `provider_class($type)`
  the CLI class for a type, loaded.

- `compiler_class($type)`
  the compiling class for a type, loaded. Refuses a type that has no compiling class, because emitting a pipeline and validating a block are different questions and a provider may answer the second while having nothing to answer the first with.

Both resolvers exit `CONFIG` on a type the registry does not hold, since a repository whose configured provider Genesis cannot compile for is a repository the operator can put right.

**Internal:**

- `_path_of($package)`
  the file path a package name derives. This is the one place that turns a class into something `require` can take.

- `_unknown($type)`
  the refusal for a type the registry does not hold.

**Dependencies:** `Genesis`, `Genesis::Exit`.

---

## Genesis::CI::Legacy

**File:** `lib/Genesis/CI/Legacy.pm`

**Purpose:** Original monolithic Concourse pipeline generator. Handles the entire pipeline from YAML parsing through Concourse YAML generation using string concatenation and embedded spruce operators.

**Public API:**

- `Genesis::CI::Legacy::parse($config_file, $top, $layout)`
  loads `$config_file` via `spruce merge`, validates structure, parses layout DSL, normalizes defaults. Returns `($pipeline_hashref, $layout_name)`.

- `Genesis::CI::Legacy::generate_pipeline_concourse_yaml($pipeline, $top)`
  generates complete Concourse pipeline YAML from the parsed hashref. Returns a YAML string.

- `Genesis::CI::Legacy::generate_pipeline_graphviz_source($pipeline)`
  generates Graphviz DOT source from parsed pipeline. Returns a string.

- `Genesis::CI::Legacy::generate_pipeline_human_description($pipeline)`
  prints human-readable pipeline description to stdout. No return value.

**Dependencies:** `Genesis`, `Genesis::Top`, `Genesis::UI`, `JSON::PP`.

---

## Genesis::CI::Compiler

**File:** `lib/Genesis/CI/Compiler.pm`

**Purpose:** Orchestrates the six-stage compilation pipeline. Constructs each stage module, passes data between stages, and returns the final result.

**Public API:**

- `Genesis::CI::Compiler->new(ci_dir => $dir, file => $file, top => $top)`
  constructor. Provide `ci_dir` for a named configuration directory or `file` for the legacy format. `top` is a `Genesis::Top` object, and a caller that names neither `ci_dir` nor `file` is asking for the `pipeline:` section of `.genesis/config`, which the parser reads through that object.

- `$compiler->compile(provider => $type)`
  runs all stages. `$type` is any registered type that has a compiling class. The type the caller names wins over the type the block declares, because the caller is the one that named it and a block that disagrees would otherwise pick the class silently. Returns:

```perl
{
    ast      => $ast_object,
    output   => { filename => $content, ... },
    provider => $provider_object,
    compiler => $compiler_object,
    parsed   => $parsed_hashref,
}
```

Both halves come back, so a caller that wants an emitted artefact reads `compiler` and a caller that wants to know whether the toolchain is there reads `provider`.

**Class Methods:**

- `Genesis::CI::Compiler->can_compile($ci_dir)`
  returns true if `$ci_dir` exists and contains `pipeline.yml`. The caller names the directory, because there is no conventional one to fall back on.

- `Genesis::CI::Compiler->can_compile_from_env_files($ci_dir)`
  returns true if `$ci_dir` holds `targets.yml` and `integrations.yml` but no `pipeline.yml`, meaning the topology comes from the environment files.

- `Genesis::CI::Compiler->can_compile_from_genesis_config($top)`
  returns true if `$top`'s config carries a `pipeline` key. Nothing calls it. `_compile_pipeline()` builds a compiler and calls `compile()` without asking first, and the parser does its own format detection, so this stands as a predicate a caller could use rather than one any caller does.

- `Genesis::CI::Compiler->validate_config_section($data, $top)`
  the owner check for the `pipeline:` section, called by `Genesis::Top` during configuration validation.

**Internal:**

- `_apply_provider_overrides($output, $type)`
  merges the override files over the emitted output.

- `_report_unread_overrides(...)`
  names an override file the layout is passing over.

There is no resolver here. `compile()` builds a `Genesis::CI::Provider` and asks it for its compiler, and the class lookup behind both is the registry's.

---

## Genesis::CI::Compiler::Parser

**File:** `lib/Genesis/CI/Compiler/Parser.pm`

**Purpose:** Loads CI configuration from a named configuration directory, from the `pipeline:` section of `.genesis/config`, or from a single legacy file, and normalizes any of the three into a common intermediate structure.

**Public API:**

- `Genesis::CI::Compiler::Parser->new(ci_dir => $dir, file => $file, top => $top)`
  constructor.

- `$parser->parse()`
  detects format and delegates to `_parse_multi_file()`, `_parse_genesis_config()`, or `_parse_legacy_file()`, tried in that order. Returns a hashref. The middle branch is taken when `top`'s config has a `pipeline` key, which is the same section `can_compile_from_genesis_config()` reads. The comment above that read says the two have to be about the same section, and that no alias was left behind for the older `ci` spelling.

**Internal Methods:**

- `_parse_multi_file($ci_dir)`
  loads `pipeline.yml`, `targets.yml`, `integrations.yml`, optionally `scripts/manifest.yml` and `provider-config/*.yml`.

- `_parse_genesis_config($data)`
  maps the section's `pipeline`, `targets`, `integrations`, `scripts`, `provider`, and `provider_config` blocks onto the same structure `_parse_multi_file()` produces, accepting `vault` and `source_control` flat as well as nested under `integrations`. Sets `_source_format` to `genesis-config`.

- `_parse_legacy_file($file)`
  loads single YAML file and normalizes it. Calls `_normalize_legacy_boshes()`, `_normalize_legacy_integrations()`, and `_normalize_legacy_layouts()`.

- `_normalize_legacy_boshes($boshes)`
  converts boshes map to targets format with `type` and `connection` fields.

- `_normalize_legacy_integrations($pipeline)`
  extracts vault, git, notifications, and locker into a unified integrations structure.

- `_normalize_legacy_layouts($pipeline)`
  extracts layout/layouts and parses the DSL.

- `_parse_layout_dsl($src, $boshes)`
  tokenizes layout string, processes `auto` directives and environment chains, returns structured workflow data.

- `_load_yaml_file($path)`
  loads a YAML file via `spruce merge`.

---

## Genesis::CI::Compiler::Validator

**File:** `lib/Genesis/CI/Compiler/Validator.pm`

**Purpose:** Validates parsed configuration for structural correctness, required fields, allowed keys, and cross-reference integrity.

**Public API:**

- `Genesis::CI::Compiler::Validator->new(top => $top)`
  constructor.

- `$validator->validate($parsed)`
  dispatches to format-specific validation. Returns `$self`.

- `$validator->has_errors()`
  returns true if errors were found.

- `$validator->errors()`
  returns arrayref of error message strings.

- `$validator->has_warnings()`
  returns true if warnings were found.

- `$validator->warnings()`
  returns arrayref of warning message strings.

**Internal Methods:**

- `_validate_legacy($parsed)`
  validates against legacy schema. Calls `_validate_required_keys`, `_validate_vault`, `_validate_git`, `_validate_boshes`, `_validate_notifications`, `_validate_layouts`, `_validate_locker`, `_validate_task`, `_validate_registry`, `_validate_groups`, `_validate_auto_update`, `_validate_notifications_style`, and checks allowed top-level keys.

- `_validate_multi_file($parsed)`
  validates pipeline, targets, and integrations sections, plus cross-references.

- `_validate_dag($wf_name, $graph)`
  depth-first cycle detection on workflow graph.

- `_validate_cross_references($parsed)`
  checks that workflow trigger patterns match targets and script references resolve.

---

## Genesis::CI::Compiler::ScriptDiscovery

**File:** `lib/Genesis/CI/Compiler/ScriptDiscovery.pm`

**Purpose:** Discovers script metadata from manifest files, inline annotations, and filename conventions.

**Public API:**

- `Genesis::CI::Compiler::ScriptDiscovery->new(repo_path => $path)`
  constructor.

- `$discovery->discover($parsed_config)`
  discovers scripts from all sources. Returns hashref of `script_id => metadata_hashref`.

**Internal Methods:**

- `_load_manifest($manifest)`
  loads from `scripts/manifest.yml` data.

- `_extract_inline_metadata($file)`
  parses `@genesis-script` annotations. Supported annotations: `@description`, `@version`, `@requires`, `@input`, `@output`, `@env-required`, `@env-optional`, `@timeout`, `@privileged`.

- `_infer_metadata($file, $rel_path)`
  generates metadata from filename.

- `_path_to_id($path)`
  converts file path to script ID by stripping prefix and extension.

- `_validate_script($id, $script)`
  ensures required fields have defaults.

---

## Genesis::CI::Compiler::AST

**File:** `lib/Genesis/CI/Compiler/AST.pm`

**Purpose:** Central data structure with two-layer design. Holds both the Genesis-specific source representation and the fully-resolved generic pipeline.

**Constructor:**

- `Genesis::CI::Compiler::AST->new(%data)`
  accepts all source and pipeline fields. Source fields are stored in `$self->{_source}`.

**Generic Pipeline Accessors (for providers):**

- `pipeline()`
  returns the full pipeline hashref.

- `metadata()`
  returns metadata hashref.

- `scripts()`
  returns scripts hashref.

- `resource_types()`
  shortcut to `$self->{pipeline}{resource_types}`.

- `pipeline_resources()`
  shortcut to `$self->{pipeline}{resources}`.

- `jobs()`
  shortcut to `$self->{pipeline}{jobs}`.

- `groups()`
  shortcut to `$self->{pipeline}{groups}`.

- `graphviz()`
  returns pre-built DOT source string.

- `description()`
  returns pre-built description string.

- `set_pipeline($pipeline)`
  stores the resolved generic pipeline.

**Source Accessors (for PipelineDescriptor and internal use):**

`branches()`, `integrations()`, `targets()`, `workflows()`, `configuration()`, `provider_config()`, `triggers()`, `resources()`.

**Query Methods:**

- `target_names()`
  sorted list of target names.

- `workflow_names()`
  sorted list of workflow names.

- `resource_names()`
  sorted list of resource names.

- `trigger_names()`
  sorted list of trigger names.

- `resources_matching($pattern)`
  resources matching a glob.

- `targets_matching($pattern)`
  targets matching a glob.

- `workflow_stage_order($wf_name)`
  topologically sorted stage names.

- `script_for_stage($wf_name, $stage_name)`
  script metadata for a stage.

- `env_vars_for_target($target_name)`
  complete env var map for a target.

---

## Genesis::CI::Compiler::ASTBuilder

**File:** `lib/Genesis/CI/Compiler/ASTBuilder.pm`

**Purpose:** Constructs AST objects from parsed configuration and discovered scripts.

**Public API:**

- `Genesis::CI::Compiler::ASTBuilder->new(top => $top, env_dir => $dir)`
  constructor. `env_dir` is what the env-file topology reads, and `Genesis::CI::Compiler::compile` passes it alongside `top`.

- `$builder->build($parsed, $scripts)`
  dispatches to format-specific builder. Returns `Genesis::CI::Compiler::AST` object.

**Internal Methods:**

- `_build_from_legacy($parsed, $scripts)`
  builds from legacy format. Computes metadata, branches, integrations, targets, workflows (via `_build_legacy_workflows`), configuration, and provider_config.

- `_build_legacy_workflows($parsed, $pipeline)`
  builds workflow graphs from parsed layout data. Computes aliases, genesis_envs, auto_envs (via glob pattern matching), triggers (inverse of will_trigger), and DAG nodes/edges. Preserves `_legacy` data on each workflow.

- `_build_from_multi_file($parsed, $scripts)`
  builds from multi-file format. Passes most data through, builds workflows via `_build_modern_workflows`.

- `_build_modern_workflows($defs, $scripts)`
  builds graphs from stage lists via `_build_workflow_graph`.

- `_build_workflow_graph($stages, $scripts)`
  creates sequential DAG from a list of stage definitions.

---

## Genesis::CI::Compiler::PipelineDescriptor

**File:** `lib/Genesis/CI/Compiler/PipelineDescriptor.pm`

**Purpose:** Converts the AST source representation into a fully-resolved generic pipeline. This is the boundary between Genesis domain logic and generic CI generation. At approximately 1300 lines, it is the largest module in the compiler.

**Public API:**

- `Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast, top => $top)`
  constructor.

- `$descriptor->describe()`
  builds the full generic pipeline. Returns a hashref with `resource_types`, `resources`, `jobs`, `groups`, `graphviz`, and `description` keys. Also stores the result in the AST via `set_pipeline()`.

- `$descriptor->graphviz()`
  generates DOT source from workflow graphs.

- `$descriptor->description()`
  generates human-readable text.

**Internal Methods (resource generation):**

- `_resource_types($ast)`
  base resource types (script, email, slack-notification, bosh-config, locker).

- `_git_resource($ast)`
  main git resource.

- `_notification_resources($ast)`
  slack and email resources.

- `_env_resources($ast, $env, $alias, $trigger_from, $is_create_env, $wf_data)`
  per-environment resources (changes, cache, cloud-config, runtime-config).

- `_locker_resources($ast, $env, $alias, $deploy_type, $is_create_env)`
  BOSH lock and deployment lock resources.

- `_auto_update_resources($ast)`
  kit-release and genesis-release resources.

**Internal Methods (job generation):**

- `_notify_job(...)`
  notification job for non-auto environments.

- `_deploy_job(...)`
  deployment job with full plan assembly.

- `_auto_update_job($ast)`
  update-genesis-assets job.

**Internal Methods (task configuration):**

- `_task_config(...)`
  deploy/show-changes task config with all env vars.

- `_errand_config(...)`
  errand execution task config.

- `_notification_step($ast, $message)`
  slack/email notification plan step.

**Internal Methods (helpers):**

- `_extract_workflow_data($ast, $workflow)`
  unified extraction from any workflow type.

- `_git_uri($source_control)`
  builds git URI.

- `_unwrap_ref($value)`
  unwraps `{secret_ref => '...'}` to `((...))`.

- `_is_create_env($ast, $env)`
  checks target type.

- `_env_file_patterns($env_name)`
  hierarchical YAML file list.

- `_unique_env_files($env, $trigger_from)`
  files unique to downstream env.

- `_shared_env_files($env, $trigger_from)`
  files shared between envs.

- `_topological_sort($graph)`
  standard topological sort.

---

## Genesis::CI::Provider

**File:** `lib/Genesis/CI/Provider.pm`

**Purpose:** Abstract base class for CI providers. A provider answers for the configuration block an operator wrote, for what the platform is able to do, and for whether the toolchain is present. It also hands out the compiler that emits its artefact.

**Class Methods:**

- `new(type => $type, %config)`
  builds the provider class the registry names for `$type`, defaulting to `manual`. It builds and nothing more, because the rules for a block are asked of the class against the configuration the block sits in.

- `init(%opts)`
  the same, from parsed CLI options rather than a config block.

- `provider_class($type)`
  a one-line delegation to the registry.

- `parse_opts($args, $ci_opts)`
  two-pass extraction of `--ci-provider` and then the provider-specific flags.

**Abstract Methods (must override):**

- `provider_options_schema()`
  the keys this provider takes under `pipeline.provider`, in the shape Top's repository schema uses. A key's default is declared here and nowhere else.

- `capabilities()`
  what this provider is able to do, as six booleans.

- `config()`
  the hash written back to the `pipeline.provider` section.

- `interactive_wizard($top)`
  prompts an operator through the block.

**Instance Methods:**

- `type()`
  the registered type this provider was built under, set where the type is known rather than derived by indexing a hash.

- `compiler(%opts)`
  the compiler that emits this provider's artefact, built with the provider held inside it. Takes `ast`, `top`, `provider_opts`, and `required`. Answers undef for a provider with nothing to emit unless `required` is passed, in which case the registry's refusal comes back instead.

- `check_prereqs()`
  whether the toolchain is present. The base answers true, which is the honest answer for a provider that needs no tool.

- `label()`
  the human-readable name this provider object holds.

**More Class Methods:**

- `validate_config($config, $path, $discriminator)`
  the provider's own rules for its block, on top of the generic pass the declaration gives it. `$path` is where the block sits in the configuration, not a `Genesis::Top`, and `$discriminator` names the one key the pass leaves alone, defaulting to `type`.

- `declared_capabilities($provider)`
  one provider class's declaration, checked against the six names the base holds.

- `capability_gates()`
  which configuration key each capability gates.

- `section_enabled($config, $path)`
  whether the section the block sits in is switched on.

---

## Genesis::CI::Provider::Concourse

**File:** `lib/Genesis/CI/Provider/Concourse.pm`

**Purpose:** The Concourse provider. Declares the `pipeline.provider` keys Concourse takes, validates them, and checks for the `fly` CLI.

**Inherits:** `Genesis::CI::Provider`

**Notable Methods:**

- `provider_options_schema()`
  declares `target`, `url`, `team`, `insecure`, `min_fly_version`, and the rest. The one `DEFAULT_TEAM` lives here, as the `team` key's declared default, and the compiler reads it back through `provider_option('team')`.

- `check_prereqs()`
  looks for `fly` on the `PATH` and, when the repository declares `min_fly_version`, enforces that floor. A `fly --version` that does not yield three dotted integers is refused by name, because a floor that cannot be compared against is a floor that is not enforced. A leading `v` on the declared floor is stripped before the comparison.

- `validate_config($config, $path, $discriminator)`
  requires a `target` once the section is switched on, and requires that a `url` begins with `http://` or `https://`. It calls `SUPER` first, because the declaration is the floor rather than a subset of what wants checking.

- `team()`
  the team this provider object holds, for the CLI's own use.

- `interactive_wizard($top)`
  prompts for target, URL, team, and the rest.

**Internal:**

- `_load_fly_targets()`, `_derive_target_name()`, `_token_expired()`
  read the operator's `fly` targets file.

---

## Genesis::CI::ProviderCompiler

**File:** `lib/Genesis/CI/ProviderCompiler.pm`

**Purpose:** Abstract base class for the classes that emit a platform's artefact. A compiler holds the provider it emits for rather than a copy of that provider's settings, so a change on the provider is visible here with nothing rebuilt.

**Constructor:**

- `new(provider => $p, ast => $ast, top => $top, provider_opts => $o)`
  a caller reaches this through `$provider->compiler(ast => $ast)` rather than calling it directly. Refuses a direct instantiation of the base, and refuses a call that names no AST, because a compiler blessed over an undefined AST fails much later and says far less about why.

**Abstract Methods (must override):**

- `platform_name()`
  return platform name string.

- `provider_type()`
  return the canonical type string.

- `generate_from_ast($ast)`
  generate platform-specific output.

- `output_files()`
  describe generated files.

**Provider Options:**

- `provider_option($key)`
  one option, with the fragment's declared default behind it. A key written with no value is the operator declining to choose, so it still resolves to the default.

- `provider_options_defaults()`
  the defaults, read off the held provider's schema rather than listed again beside it.

- `provider_config()`
  the stored options, excluding anything still at its default.

- `cli_opts()`, `cli_opts_help()`, `parse_cli_opts(...)`, `cli_opt_keys($type)`, `normalize_provider_opts($opts)`, and `cli_key_to_config_key($key)`
  the deploy-time flag plumbing.

- `describe_provider()`
  a structured self-description for display.

**Accessors and Helpers:**

- `provider()`
  the provider this compiler was built by.

- `ast()`
  returns stored AST.

- `top()`
  returns stored `Genesis::Top`.

- `dump_yaml($data)`
  serializes Perl data to YAML string.

- `git_uri($source_control)`
  builds git URI.

- `secret_ref($ref)`
  formats secret reference (default: `(($ref))`).

- `topological_sort($graph)`
  topological sort on workflow graph.

- `matches_pattern($name, $pattern)`
  glob pattern matching.

Nothing here answers for a toolchain. That question goes to the provider.

---

## Genesis::CI::ProviderCompiler::Concourse

**File:** `lib/Genesis/CI/ProviderCompiler/Concourse.pm`

**Purpose:** The Concourse compiler. Emits Concourse pipeline YAML from an AST, and carries the legacy bridge for backward compatibility.

**Inherits:** `Genesis::CI::ProviderCompiler`

**Compiler Interface:**

- `generate_from_ast($ast)`
  checks for the legacy marker and delegates to either `_generate_from_legacy_ast()` or `_generate_native()`.

- `output_files()`
  returns `{ 'pipeline.yml' => '...' }`.

- `platform_name()`, `provider_type()`, and `file_extension()`
  the platform's name, the string `concourse`, and `.yml`.

**Built From a Configuration File:**

- `init(%opts)`
  builds a compiler from a configuration file rather than from an AST, which is the only route that populates the `config` key.

- `parse()`
  loads and validates the Concourse configuration, and is what sets `config`.

`generate()`, `deploy(%opts)`, `graph_md()`, `describe()`, and `generate_description()` all refuse unless `parse()` has run. See the known defect below.

`deploy(%opts)` uploads the pipeline through the `fly` CLI, supports dry-run, yes, and paused options, and handles the pause, set-pipeline, unpause, and expose cycle.

**Internal:**

- `_generate_from_legacy_ast($ast)`
  reconstructs the `$P` hashref from the AST's legacy data and delegates to `Legacy::generate_pipeline_concourse_yaml`.

- `_generate_native($ast)`
  serializes the generic pipeline to YAML.

- `_ensure_pipeline_resolved()`
  runs PipelineDescriptor if needed.

**A known defect:**

Four of the five methods above guard on the `config` key, and `generate_description` reaches one of the four through an alias. A compiler built on the compile path never has it, because the constructor blesses only the provider, the AST, the `Genesis::Top` object, and the provider options. So `genesis pipeline-apply`, `genesis pipeline-graph`, and `genesis pipeline-describe` all reach a "Must call parse() before ..." refusal under the Concourse provider once the compile has finished. Reading `provider_option`, `output_files`, or the `output` hash the compile returns works, because none of those reads that key.

---

## Genesis::Commands::Pipelines

**File:** `lib/Genesis/Commands/Pipelines.pm`

**Purpose:** Command handler for every pipeline command. There is no routing on a `--platform` flag, because D27 took that flag away. The provider is the one the repository configures under `pipeline.provider.type`, and an absent type is the manual provider.

**Public Subroutines:**

- `apply()`
  gives the pipeline its shape on every provider, and is `genesis pipeline-apply`. It refuses a repository that declares no pipeline, cuts the deployment branches, applies branch protection, writes the exodus records, and then compiles and sets the pipeline where the provider has one.

- `propagate()`
  delivers each due control commit to the branches that want it, and is `genesis propagate`.

- `pipeline_status()`
  shows propagation state across all environments, and is `genesis pipeline-status`.

- `pipeline_graph()`
  writes `pipeline.md` with a Mermaid flowchart, and is `genesis pipeline-graph`.

- `pipeline_describe()`
  prints the pipeline progression in words, and is `genesis pipeline-describe`.

- `diff()`
  shows the compiled pipeline against the live one, and is `genesis pipeline-diff`.

- `status()`
  shows per-environment job health, and is `genesis pipeline-jobs`.

- `pause()` and `resume()`
  pause or resume one environment's job or the whole pipeline, and are `genesis pipeline-pause` and `genesis pipeline-resume`.

- `embed()`
  embeds the Genesis binary into the deployment repository, and is `genesis embed`.

- `run_status($record)`
  the exit status D97 gives the run's second stage.

- `Genesis::CI::Preflight::assert_not_disowned($top, %opts)`
  refuses a pipeline the configuration has disowned, and `propagate()` calls it. It lives in `Genesis::CI::Preflight` because `genesis <env> deploy` asks the same question and is answered with a warning instead.

- `assert_provider_gate($top, $opts)`
  the propagate run's break-glass past the pipeline.

- `open_control_session($top, $git)`
  begins a session and stands it on the control branch.

**Deprecated Subroutines:**

- `repipe()`
  warns and delegates to `apply()`. It keeps the `push` alias and a `--config` option that nothing reads any more.

- `graph()`
  warns, then calls `Genesis::CI::Legacy` directly for DOT source. This is the one route in the module that reaches Legacy without the bridge.

- `describe()`
  warns and delegates to `pipeline_describe()`.

**Retired Commands:**

`ci_pipeline_deploy()`, `ci_show_changes()`, `ci_generate_cache()`, and `ci_pipeline_run_errand()` are gone from this module. Their commands are still registered in `bin/genesis` with a `retired` property, so dispatch bails before anything runs and a legacy pipeline fails loudly rather than deploying inconsistently.

**Internal:**

- `_compile_pipeline($top, $platform)`
  the shared compile. It parses the provider-specific CLI flags, builds a `Genesis::CI::Compiler`, calls `compile()`, honours `--debug-dir`, and returns the result with the parsed flags added under `provider_cli_opts`.

- `_dump_debug_artifacts($debug_dir, $result, $platform)`
  writes numbered intermediate files for debugging.

- `_get_top($opts)`
  creates the `Genesis::Top`, optionally skipping vault.

- `_refuse_disabled_pipeline()`
  D64's refusal on a pipeline nobody declared, which reads `.genesis/config` raw so it lands ahead of any vault connection.

- `_concourse_fly_flags($result, $opts, $name)`
  derives the `fly` target and the `-k` flag from the compiled result, reading both through the compiler's `provider_option`.

- `_job_status_label($job)`
  derives a display status from a `fly jobs` entry.

The branch, protection, record, and propagation helpers are `_apply_init_branches`, `_protection_rules_for`, `_apply_branch_protection`, `_apply_records`, `_preview_warnings`, `_push_failure`, `_verify_deployed`, `_describe_source_control`, and `_describe_topology`.

## Genesis::CI::Preflight

**File:** `lib/Genesis/CI/Preflight.pm`

**Purpose:** The first stage of a propagation run, which settles what the repository holds before anything is written, and the two refusals about the pipeline itself that more than one command makes. A violation of the initial state stops the run before it writes, and the refusal names the branch and the way out. Each refusal spends a named exit code rather than a number, which is `CONFIG` for control that exists nowhere, `DATAERR` for an initial state the design calls illegal, and `TEMPFAIL` for a remote this clone cannot reach.

**Public Subroutines:**

- `initial_state($top, $git, %opts)`
  runs the whole first stage and returns what it found, as the refresh, the control divergence, a classification of every deployment branch in scope, and the events to print. It refuses before it writes anything, then resets a branch whose only local commits are ones a re-run reproduces and fast-forwards a branch that is merely behind. Under `dry_run` it writes nothing and reports each write it would have made as a warning.

- `require_control($top, $git, %opts)`
  settles the control branch before anything else is read, because the topology is read from it. Control that exists nowhere is refused at `CONFIG`. A caller that passes `on_divergence => 'report'` is handed the divergence instead of being refused on it, which is how `genesis <env> deploy` and `genesis pipeline-status` reach a report where `genesis propagate` refuses.

- `local_only_commits($git, $branch)`
  lists the commits a branch holds that no remote has, newest first, each classified by the propagation marker it carries. A commit with a marker is one a re-run reproduces and a commit without one is an operator's hand edit, which nothing here may discard. It runs before any prune, because a prune removes the refs that answer it.

- `assert_not_disowned($top, %opts)`
  refuses a pipeline the configuration has disowned. It lives here because `genesis <env> deploy` asks the same question and is answered with a warning instead of a refusal.

- `assert_provider_gate($top, $opts, %how)`
  refuses a command-line run of work an automated provider's pipeline owns, because such a run takes none of the locks the pipeline's own jobs take. `--force` at a terminal turns the refusal into an acknowledgement, which `--yes` does not suppress, and outside a terminal the refusal stands even with the flag.

**Internal:** `_shares_history`, `_illegal_state_refusal`, `_local_only_refusal`, `_unrelated_refusal`, `_hand_commit_refusal`, and `_commits`.

## Genesis::BranchClass

**File:** `lib/Genesis/BranchClass.pm`

**Purpose:** The branch-class gate, which decides whether the branch an operator is standing on may run the command they typed. It classifies the branch, refreshes control before it reads anything, and refuses a pre-deploy command off a branch that may not carry a hand commit. It switches nothing, because the operator chose the branch and the fix is theirs. Each refusal spends a named exit code, which is `CONFIG` for a control branch that exists nowhere, `DATAERR` for a branch the design will not let the command run from, and `TEMPFAIL` for a remote this clone cannot reach.

**Public Subroutines:**

- `classify_branch($top, $branch)`
  answers which of `control`, `deployment`, `pr`, `artifacts`, or `feature` a branch name belongs to. The three derived classes are composed from the environments the repository declares rather than matched against a naming pattern, because the branch is per deployment and its name is the deployment slug. A name that matches none of them is a feature branch, and so is an undefined name.

- `artifacts_branch_for($top, $env_name)`
  composes the artifacts branch of a deployment, which is the deployment slug behind one fixed prefix. It is composed here rather than in `Genesis::Top` because nothing writes to that branch and only this gate reads it.

- `refresh_control($top, $git)`
  brings control from the remote into the remote-tracking ref before the ancestry check, and fails loudly where it cannot. Only control is named, because a deployment branch's tip answers a question no pre-deploy command asks. A clone that has lost its control branch is left for the pre-flight to repair and report, so no branch is materialised here silently.

- `permitted_feature_branch($top, $git, $branch, %opts)`
  answers whether a feature branch meets the three conditions, and otherwise answers false with the condition that failed and the command that fixes it, so the caller writes one refusal and the reasons stay here. The conditions are that control has been fetched, that the branch descends from control's refreshed tip, and that the branch is not named for an environment. `adding` names an environment the command is about to create, because a branch may collide with a name that does not exist yet, and `refresh` says whether the caller allowed a network call.

- `assert_pre_deploy($top, $git, %opts)`
  refuses a pre-deploy command off a branch that may not carry one, at `DATAERR`, naming the class of branch and the checkout that moves the operator off it. Control is permitted, except where the repository requires a pull request and the command commits, and a detached HEAD is let through for the two landed behaviours that own that state to speak for.

**Internal:** none, in the sense that no sub here carries a leading underscore. Only `assert_pre_deploy` has a caller outside this module today, in `Genesis::Commands`, and the other four are the steps it is built from, each documented in the module's own `.pod` and each covered by rows of its own.

## The Propagation Half

These modules run under `genesis propagate` and `genesis pipeline-status`. None of them compiles anything, and none of them is reached by `genesis pipeline-apply` except through the branch work that command does before it compiles. Each one's `.pod` beside it in `lib/Genesis/CI/` is the reference for its API.

| Module | File | Purpose |
|--------|------|---------|
| `Genesis::CI::Preflight` | `lib/Genesis/CI/Preflight.pm` | The initial state a propagation run may find, and the refusals it owes before the walk begins. `assert_not_disowned` lives here because `genesis <env> deploy` asks the same question and is answered with a warning instead |
| `Genesis::CI::Walk` | `lib/Genesis/CI/Walk.pm` | The per-commit walk and its record. It visits every environment and decides, for each control commit in control order, whether that commit is delivered or held, and with what reason |
| `Genesis::CI::Marker` | `lib/Genesis/CI/Marker.pm` | The propagation marker and the Genesis commit trailers. The marker is where the next run starts each branch from |
| `Genesis::CI::Propagation` | `lib/Genesis/CI/Propagation.pm` | One sub, `_apply_propagation_commit`, which copies a control commit's changed files onto the branch it is on, removes the ones that commit deleted, and writes the commit the marker names |
| `Genesis::CI::PullRequest` | `lib/Genesis/CI/PullRequest.pm` | The pull request arm of the run, for the environments whose `require_pr` asks for one |
| `Genesis::CI::Publish` | `lib/Genesis/CI/Publish.pm` | The run's third stage, which is one push per branch |
| `Genesis::CI::Report` | `lib/Genesis/CI/Report.pm` | The run's report, on the three axes the design gives it |
| `Genesis::CI::RunFailure` | `lib/Genesis/CI/RunFailure.pm` | The two classes of failure that end a run, and what each one leaves behind |
| `Genesis::CI::Status` | `lib/Genesis/CI/Status.pm` | The `pipeline-status` read model. It renders the record the walk wrote, which is why the two commands cannot disagree |
| `Genesis::CI::Shuttle` | `lib/Genesis/CI/Shuttle.pm` | The object store behind every deployment's request queue and `_ran` event, with `Shuttle/S3.pm` and `Shuttle/GCS.pm` declaring the keys each backend reads |
| `Genesis::CI::Layout` | `lib/Genesis/CI/Layout.pm` | The layout DSL parser. A v3 repository writes no layout, and the legacy configuration still reaches this |
