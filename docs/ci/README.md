# Genesis CI Pipeline Documentation

Genesis includes a CI pipeline system that generates deployment automation for CI/CD platforms. A repository names the platform it uses under `pipeline.provider.type` in `.genesis/config`, and Genesis ships a Concourse provider that compiles and sets a pipeline, a GitHub Actions provider that validates its configuration but has nothing to emit yet, and a manual provider that sets no pipeline at all.

This documentation is split into two audiences:

## For Operators and Users

If you are an operator who wants to set up automated deployment pipelines for your Genesis environments, start here:

| Document | What It Covers |
|----------|----------------|
| [Getting Started](user/getting-started.md) | Configuring a pipeline in `.genesis/config` and the environment files, then applying and propagating |
| [Configuration Reference](user/configuration-reference.md) | The per-environment `genesis.pipeline` keys, and every option the legacy `ci.yml` format took |
| [Layout DSL](user/layout-dsl.md) | The pipeline layout language for defining environment progression |
| [Pipeline Section Configuration](user/multi-file-configuration.md) | The `pipeline:` section of `.genesis/config`, and the one override file that sits beside it |
| [CLI Commands](user/cli-commands.md) | `genesis propagate` and the `pipeline-*` commands |

## For Developers

If you are contributing to the Genesis CI compiler or writing a new CI platform provider, start here:

| Document | What It Covers |
|----------|----------------|
| [Architecture Overview](dev/architecture.md) | System design, module relationships, and data flow |
| [Compiler Pipeline](dev/compiler-pipeline.md) | The six-stage compilation process in detail |
| [AST and PipelineDescriptor](dev/ast-and-descriptor.md) | The two-layer AST design and how generic pipelines are built |
| [Writing a Provider](dev/writing-a-provider.md) | How to implement a new CI platform provider |
| [Legacy Bridge](dev/legacy-bridge.md) | How `Legacy.pm` interoperates with the modern compiler |
| [Module Reference](dev/module-reference.md) | Every Perl module, its role, and its public API, on both the compiler side and the propagation side |
