# Using Mixins for Common Methods in Genesis Addon Hooks

When developing multiple addon hooks for a Genesis kit, you often find yourself duplicating common functionality across multiple files. This guide shows how to use Perl's mixin pattern to share common methods cleanly across your addon hooks.

## The Problem: Code Duplication

Consider a typical addon hook that needs to:
- Connect to Cloud Foundry
- Retrieve service broker credentials 
- Handle version checking
- Perform similar setup tasks

Without a shared approach, each addon file would duplicate 30+ lines of identical CF login logic:

```perl
# Repeated in every addon file!
my $cf_deployment_env = $env->exodus_lookup('cf_deployment_env');
my $cf_deployment_type = $env->exodus_lookup('cf_deployment_type');
# ... 25 more lines of CF connection logic
```

## The Solution: Pure Mixin Pattern

Instead of complex inheritance hierarchies, we can use Perl's `do` statement to literally include common method definitions into each addon class.

### Step 1: Create the Mixin File

Create `hooks/_addon.pm` with pure method definitions (no package declaration, no imports):

```perl
# CF App Autoscaler Addon Mixin
# This file provides common methods for CF App Autoscaler addon hooks
# Include with: do dirname(__FILE__) . '/_addon.pm';
#
# Note: This file relies on the importing module to have the necessary
# 'use' statements for Genesis, Genesis::UI, etc.

# Override init to add version check
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}

# Common CF login method for all CF App Autoscaler addons
sub cf_login {
	my ($self) = @_;
	my $env = $self->env;

	# Get CF deployment info from exodus
	my $cf_deployment_env = $env->exodus_lookup('cf_deployment_env');
	my $cf_deployment_type = $env->exodus_lookup('cf_deployment_type');
	bail("CF deployment environment not found in exodus data") unless $cf_deployment_env;
	bail("CF deployment type not found in exodus data") unless $cf_deployment_type;

	# Get CF credentials from the CF deployment's exodus data
	my $system_domain = $env->exodus_lookup('system_domain', undef, "${cf_deployment_env}/${cf_deployment_type}");
	my $username = $env->exodus_lookup('admin_username', undef, "${cf_deployment_env}/${cf_deployment_type}");
	my $password = $env->exodus_lookup('admin_password', undef, "${cf_deployment_env}/${cf_deployment_type}");
	
	bail("CF system domain not found in exodus data") unless $system_domain;
	bail("CF admin username not found in exodus data") unless $username;
	bail("CF admin password not found in exodus data") unless $password;
	
	my $api_url = "https://api.$system_domain";

	# CF login
	info("Connecting to CF API at %s", $api_url);
	run('cf', 'api', $api_url, '--skip-ssl-validation');
	run('cf', 'auth', $username, $password);

	# Check for cf-targets plugin
	my ($out, $rc) = run('cf plugins | grep -q \'^cf-targets\'');
	if ($rc == 0) {
		run('cf', 'save-target', '-f', $cf_deployment_env);
	} else {
		info("#Y{The cf-targets plugin does not seem to be installed} -- cannot save current target");
	}
	
	run('cf', 'target');
	return 1;
}

# Common method to get service broker credentials
sub get_service_broker_credentials {
	my ($self) = @_;
	my $env = $self->env;

	my $sb_username = $env->exodus_lookup('service_broker_username');
	my $sb_password = $env->exodus_lookup('service_broker_password');
	my $sb_domain = $env->exodus_lookup('service_broker_domain');
	
	bail("Service broker username not found in exodus data") unless $sb_username;
	bail("Service broker password not found in exodus data") unless $sb_password;
	bail("Service broker domain not found in exodus data") unless $sb_domain;

	return ($sb_username, $sb_password, "https://$sb_domain");
}

1;
```

### Step 2: Include the Mixin in Each Addon

In each addon file, use this minimal pattern to include the mixin:

```perl
package Genesis::Hook::Addon::CFAppAutoscaler::BindAutoscaler;

use v5.20;
use warnings;

# Only needed for development
BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME} . '/.genesis/lib' }

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info run bail/;

# Include common methods from mixin
BEGIN {
	require File::Basename;
	my $mixin_file = File::Basename::dirname(__FILE__) . '/_addon.pm';
	do $mixin_file or die "Failed to include addon mixin $mixin_file: $!";
}

sub cmd_details {
	return "Binds the Autoscaler service broker to your deployed CF.";
}

sub perform {
	my ($self) = @_;
	my $env = $self->env;

	# Use mixin methods - they're now part of this class!
	$self->cf_login();
	my ($sb_username, $sb_password, $sb_url) = $self->get_service_broker_credentials();

	# Create and enable service broker
	run('cf', 'create-service-broker', 'autoscaler', $sb_username, $sb_password, $sb_url);
	run('cf', 'enable-service-access', 'autoscaler');

	info("\n#G{[OK]} Successfully created the service broker.");
	return $self->done();
}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
```

## How It Works

1. **Pure Mixin**: The `_addon.pm` file contains only method definitions - no package declaration, no imports
2. **Runtime Inclusion**: The `do` statement literally includes the mixin code at compile time
3. **Method Availability**: Methods from the mixin become part of each addon class as if they were copy-pasted
4. **Single Source of Truth**: All common logic lives in one place but is available everywhere

## Benefits Over Other Approaches

### ✅ Cleaner Than Inheritance
- No complex package hierarchies
- No `-norequire` parent options
- No symbol table checking

### ✅ Simpler Than Modules
- No need for the mixin to compile independently
- No `use` statements in the mixin file
- No package loading complexity  

### ✅ More Maintainable Than Copy-Paste
- Update common logic in one place
- Consistent behavior across all addons
- Easy to add new common methods

### ✅ More Efficient Than Runtime Resolution
- Methods are included at compile time
- No inheritance chain lookups
- Direct method calls

## Usage Pattern Summary

For each new addon that needs common functionality:

1. **Create the addon file** with the standard Genesis addon structure
2. **Add the mixin inclusion** with the 5-line BEGIN block pattern
3. **Call mixin methods** directly on `$self` as if they were local methods
4. **Focus on addon-specific logic** - let the mixin handle the boilerplate

## File Organization

```
hooks/
├── _addon.pm                          # Pure mixin file
├── addon-bind-autoscaler~bind.pm      # Uses mixin
├── addon-test-bind-autoscaler~test.pm # Uses mixin  
├── addon-update-autoscaler~update.pm  # Uses mixin
├── addon-setup-cf-plugin.pm           # Uses mixin
└── addon-config-autoscaler~config.pm  # Uses mixin
```

## Best Practices

1. **Keep the mixin pure** - no imports, no package declarations
2. **Include early** - use BEGIN block to ensure methods are available
3. **Error handling** - die with clear message if mixin fails to load
4. **Method prefixing** - consider prefixing mixin methods to avoid conflicts
5. **Documentation** - clearly document which methods come from the mixin

## Compatibility with Genesis

This pattern is fully compatible with Genesis's hook loading mechanism:

- Genesis reads the package name from the first line
- Genesis calls `require` on the addon file  
- The mixin is included during compilation
- Genesis calls `->init()` which can be overridden by the mixin
- Everything works seamlessly

The mixin pattern provides a clean, efficient way to share common functionality across Genesis addon hooks without the complexity of inheritance hierarchies or module loading boilerplate.