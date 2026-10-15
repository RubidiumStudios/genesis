#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Test::Exit;

# Explicit import: Genesis exports its own workdir() which would otherwise
# clobber helper's.
use Genesis qw/mkdir_or_fail mkfile_or_fail slurp pushd popd run/;
use Genesis::Commands;
use Genesis::Exit;
use Genesis::Commands::Core;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Registers the commands and runs Genesis::Init, which prepare_command and
# the logger both depend on.
require './bin/genesis';

sub config_repo {
	my ($name, %opts) = @_;

	# Harness::GitEnv, so no inherited GIT_DIR aims this at another repository.
	scrub_git_env();

	my $dir = workdir($name);

	# A row that switches the provider type wants the gate off, because an
	# enabled pipeline under an automated provider also requires the clone
	# credential and the committer identity, which is a different subject.
	my $enabled = (exists $opts{enabled} ? $opts{enabled} : 1) ? 'true' : 'false';

	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: $enabled
  provider:
    type: manual
version: 3
EOF

	# The enabled pipeline derives its remote and its repository from git, so
	# the fixture is a checkout with a GitHub remote rather than a bare
	# directory holding a configuration file.
	run({dir => $dir}, 'git', 'init', '-q');
	run({dir => $dir}, 'git', 'remote', 'add', 'origin',
		'https://github.com/genesis/test-kit-deployments.git');

	return $dir;
}

subtest 'config with no arguments dumps the repository configuration' => sub {
	plan tests => 1;

	pushd config_repo('config-dump');
	prepare_command('config');
	build_command_environment;
	my $out = stdout_from { Genesis::Commands::Core::config() };
	popd;

	like($out, qr/manifest_store:\s*exodus/,
		"dump reports the repository's manifest_store");
};

subtest 'config with one argument prints that value' => sub {
	plan tests => 1;

	pushd config_repo('config-get');
	prepare_command('config');
	build_command_environment;
	my $out = stdout_from { Genesis::Commands::Core::config('manifest_store') };
	popd;

	is($out, "exodus\n", "prints the bare scalar, without YAML framing");
};

subtest 'config resolves a dotted path' => sub {
	plan tests => 1;

	pushd config_repo('config-get-dotted');
	prepare_command('config');
	build_command_environment;
	my $out = stdout_from { Genesis::Commands::Core::config('pipeline.provider.type') };
	popd;

	is($out, "manual\n", "walks into nested keys");
};

subtest 'config renders a non-scalar key as YAML' => sub {
	plan tests => 1;

	pushd config_repo('config-get-section');
	prepare_command('config');
	build_command_environment;
	my $out = stdout_from { Genesis::Commands::Core::config('pipeline') };
	popd;

	like($out, qr/^provider:\n(?:.*\n)*?\s+type:\s*manual$/m,
		"renders the section rather than stringifying the reference");
};

subtest 'config keeps values on stdout and messages off it' => sub {
	plan tests => 2;

	pushd config_repo('config-streams');
	prepare_command('config');
	build_command_environment;
	my ($out, $err) = output_from { Genesis::Commands::Core::config('manifest_store') };
	popd;

	is($out, "exodus\n", "the value goes to stdout");
	is($err, '', "nothing is written to stderr alongside it");
};

subtest 'config reports an unset key without pretending it is empty' => sub {
	plan tests => 3;

	pushd config_repo('config-unset');
	prepare_command('config');
	build_command_environment;
	my ($out, $err, $rc);
	($out, $err) = output_from { $rc = Genesis::Commands::Core::config('no_such_key') };
	popd;

	is($out, '', "prints nothing to stdout, so a script capturing it gets nothing");
	like($err, qr/\(unset\)/, "says the key is unset, on stderr");
	isnt($rc, 0, "exits non-zero so callers can branch on it");
};

subtest 'config --set persists a value' => sub {
	plan tests => 1;

	# Disabled, because an enabled pipeline requires the exodus store and
	# the row is about the write, not the pipeline.
	my $dir = config_repo('config-set', enabled => 0);
	pushd $dir;
	prepare_command('config', '--set', 'manifest_store', 'repository');
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*repository/,
		"writes the new value to .genesis/config");
};

subtest 'config --set refuses a value the schema rejects' => sub {
	plan tests => 2;

	my $dir = config_repo('config-set-invalid');
	pushd $dir;
	prepare_command('config', '--set', 'manifest_store', 'nonsense');
	build_command_environment;
	# $@ has to be taken inside the block: popd runs before the assertions
	# and clears it.
	my $raised = '';
	my ($out, $err) = output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*exodus/,
		"leaves the original value on disk");
	like($err.$raised, qr/manifest_store/,
		"names the offending key");
};

subtest 'config --unset removes a key' => sub {
	plan tests => 2;

	my $dir = config_repo('config-unset');
	pushd $dir;
	prepare_command('config', '--unset', 'manifest_store');
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	my $cfg = slurp("$dir/.genesis/config");
	unlike($cfg, qr/^manifest_store:/m, "the key is gone from the file");
	like($cfg, qr/^deployment_type:/m, "the rest of the config is left alone");
};

subtest 'config --unset removes several keys' => sub {
	plan tests => 3;

	my $dir = config_repo('config-unset-many');
	pushd $dir;
	prepare_command('config', '--unset', 'manifest_store', '--unset', 'pipeline.enabled');
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	my $cfg = slurp("$dir/.genesis/config");
	unlike($cfg, qr/^manifest_store:/m, "the first key is gone");
	unlike($cfg, qr/^\s+enabled:/m,     "the nested key is gone");
	like($cfg, qr/type:\s*manual/,      "its sibling is untouched");
};

subtest 'config mixes --set and --unset in one run' => sub {
	plan tests => 2;

	my $dir = config_repo('config-set-and-unset');
	pushd $dir;
	prepare_command('config', '--set', 'manifest_store', 'repository',
	                          '--unset', 'pipeline.enabled');
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	my $cfg = slurp("$dir/.genesis/config");
	like($cfg, qr/manifest_store:\s*repository/, "the set is applied");
	unlike($cfg, qr/^\s+enabled:/m,              "the unset is applied");
};

subtest 'config refuses to set and unset the same key' => sub {
	plan tests => 2;

	# Getopt::Long collects each option into its own list, so the order the
	# two were typed in cannot be recovered: '--set a 1 --unset a' and
	# '--unset a --set a 1' arrive identical.  Rather than pick one and be
	# wrong half the time, refuse the invocation.
	my $dir = config_repo('config-set-unset-clash');
	pushd $dir;
	prepare_command('config', '--set', 'manifest_store', 'repository',
	                          '--unset', 'manifest_store');
	build_command_environment;
	my $raised = '';
	my ($out, $err) = output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	like($err.$raised, qr/manifest_store/, "names the contested key");
	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*exodus/,
		"leaves the file exactly as it was");
};

subtest 'config will not read and write in the same run' => sub {
	plan tests => 2;

	# There is no sensible output contract for "print this and also change
	# that", and silently dropping the read is how the argument used to
	# disappear without comment.
	my $dir = config_repo('config-read-and-write');
	pushd $dir;
	prepare_command('config', 'deployment_type', '--set', 'manifest_store', 'repository');
	build_command_environment;
	output_from {
		exits_nonzero { Genesis::Commands::Core::config(get_args()) }
			"exits non-zero rather than picking one";
	};
	popd;

	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*exodus/,
		"and writes nothing");
};

subtest 'config will not read more than one key' => sub {
	plan tests => 1;

	my $dir = config_repo('config-multi-get');
	pushd $dir;
	prepare_command('config', 'manifest_store', 'deployment_type');
	build_command_environment;
	output_from {
		exits_nonzero { Genesis::Commands::Core::config(get_args()) }
			"exits non-zero rather than silently ignoring the rest";
	};
	popd;
};

subtest 'config --unset accepts a key that is already unset' => sub {
	plan tests => 2;

	# Unset states a desired end state, and the end state is the same
	# whether or not the key happened to be there.
	my $dir = config_repo('config-unset-absent');
	pushd $dir;
	prepare_command('config', '--unset', 'kits_path');
	build_command_environment;
	my $raised = '';
	output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	is($raised, '', "does not complain about a key that was not set");
	like(slurp("$dir/.genesis/config"), qr/^deployment_type:/m,
		"leaves the rest of the config alone");
};

subtest 'config --unset rejects a key the schema does not know' => sub {
	plan tests => 2;

	# A key the file does not carry and no schema declares is a typo.  A
	# presence check alone could never catch one, because a typo is always
	# absent; a key the file does carry is removable, declared or not.
	my $dir = config_repo('config-unset-bogus');
	pushd $dir;
	prepare_command('config', '--unset', 'manifest_stroe');
	build_command_environment;
	my $raised = '';
	my ($out, $err) = output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	like($err.$raised, qr/manifest_stroe/, "names the key it does not recognise");
	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*exodus/,
		"writes nothing");
};

subtest 'config refuses to set inside a key it is unsetting' => sub {
	plan tests => 2;

	# Unsetting the parent removes what the set just wrote into, and which
	# of the two wins depends on an order that was not preserved.
	my $dir = config_repo('config-set-under-unset');
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.provider.type', 'concourse',
	                          '--unset', 'pipeline.provider');
	build_command_environment;
	my $raised = '';
	my ($out, $err) = output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	like($err.$raised, qr/pipeline\.provider/, "names the overlapping keys");
	like(slurp("$dir/.genesis/config"), qr/type:\s*manual/,
		"leaves the file as it was");
};

subtest 'config allows set and unset of unrelated nested keys' => sub {
	plan tests => 2;

	# A shared prefix is not an overlap: neither key contains the other.
	my $dir = config_repo('config-set-unset-siblings');
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.provider.type', 'concourse',
	                          '--unset', 'pipeline.enabled');
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	my $cfg = slurp("$dir/.genesis/config");
	like($cfg, qr/type:\s*concourse/, "the set is applied");
	unlike($cfg, qr/^\s+enabled:/m,   "the unset is applied");
};

subtest 'config --set-from-file reads a scalar, less one newline' => sub {
	plan tests => 1;

	# Disabled, for the reason 'config --set persists a value' gives.
	my $dir = config_repo('config-from-file-scalar', enabled => 0);
	mkfile_or_fail("$dir/value.txt", "repository\n");
	pushd $dir;
	prepare_command('config', '--set-from-file', 'manifest_store', "$dir/value.txt");
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*repository\s*$/m,
		"stores the text without its trailing newline");
};

subtest 'config --set-from-file parses a collection' => sub {
	plan tests => 2;

	my $dir = config_repo('config-from-file-collection', enabled => 0);
	mkfile_or_fail("$dir/provider.yml", "type: concourse\ntarget: prod\n");
	pushd $dir;
	prepare_command('config', '--set-from-file', 'pipeline.provider', "$dir/provider.yml");
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	my $cfg = slurp("$dir/.genesis/config");
	like($cfg, qr/type:\s*concourse/, "the parsed structure is stored");
	like($cfg, qr/target:\s*prod/,    "including its other keys");
};

subtest 'config --set coerces against the provider the same run names' => sub {
	plan tests => 2;

	# Part of the schema is built from the configuration's own values: the
	# provider's keys are declared by whichever provider the type names.  A
	# run that writes the type and one of that provider's keys together has
	# to coerce the second against the schema the first has just made true,
	# or the string "false" is stored, and every non-empty string is true.
	my $dir = config_repo('config-set-provider-boolean', enabled => 0);
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.provider.type', 'concourse',
	                          '--set', 'pipeline.provider.insecure', 'false');
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	my $cfg = slurp("$dir/.genesis/config");
	like($cfg, qr/type:\s*concourse/, "the provider type is saved");
	like($cfg, qr/insecure:\s*false/,
		"and the boolean saves as what was typed, on the run that names it");
};

subtest 'config --unset of the provider type refuses what it orphans' => sub {
	plan tests => 4;

	# The provider type is one of the values the schema is built from, so
	# clearing it takes the fragment that declares every other provider key
	# away with it.  The check that guards the save has to read the schema
	# as it stands after the removal, or the run saves a file whose next
	# reader cannot load it.
	my $dir = config_repo('config-unset-provider-type', enabled => 0);
	mkfile_or_fail("$dir/.genesis/config", <<'CFG');
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: false
  provider:
    target: ci
    type: concourse
version: 3
CFG

	pushd $dir;
	prepare_command('config', '--unset', 'pipeline.provider.type');
	build_command_environment;

	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($out, $err, $code);
	($out, $err) = output_from {
		$code = exit_code { Genesis::Commands::Core::config() };
	};
	popd;

	is($code, Genesis::Exit::CONFIG,
		"the run is refused at the configuration exit code");
	like($err, qr/pipeline\.provider\.target: unknown configuration key/,
		"because target is declarable only while the provider that declares it is named");
	unlike($err, qr/group_commits|insecure|pause_after_set|tagged|team|public|task/,
		"and it names only the key the operator wrote, not the departing defaults");
	like(slurp("$dir/.genesis/config"), qr/type:\s*concourse/,
		"and the file is left exactly as it was");
};

# A provider block holding nothing but the type, so removing the type
# orphans no key at all and every route out of the provider is legitimate.
sub concourse_repo {
	my ($name) = @_;
	my $dir = config_repo($name, enabled => 0);
	mkfile_or_fail("$dir/.genesis/config", <<'CFG');
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: false
  provider:
    type: concourse
version: 3
CFG
	return $dir;
}

# An assertion helper, so it lives beside the rows that use it: it runs the
# prepared command and reports the exit code and what went to stderr.
sub run_config {
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($out, $err, $code, $rc);
	($out, $err) = output_from {
		$code = exit_code { $rc = Genesis::Commands::Core::config() };
	};
	# A refusal exits and a success returns, so the answer is whichever of
	# the two the command actually gave.
	return (defined $code ? $code : $rc, $err);
}

subtest "a provider's own rules wait for the section to be turned on" => sub {
	plan tests => 4;

	# The repository names Concourse and gives it no target, which is the
	# one key that provider cannot run without.  Nobody has turned the
	# pipeline on, so the rule has nothing to be about yet, and an operator
	# building a provider block a key at a time is not refused for a key
	# the block does not carry so far.
	my $dir = concourse_repo('config-gate-off');
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.provider.team', 'main');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, 'a disabled pipeline takes a provider key without complaint');
	unlike($err, qr/'target' is required/,
		"and the provider's own rule says nothing while the section is off");

	# Turning the section on is what asks the provider to run, and the
	# refusal that follows is the provider's own sentence rather than
	# anything the framework composed for it.
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.enabled', 'true');
	build_command_environment;
	($code, $err) = run_config();
	popd;

	is($code, Genesis::Exit::CONFIG,
		'turning the section on is refused, at the configuration exit');
	like($err, qr/'target' is required for the Concourse provider/,
		"in the provider's own words");
};

subtest 'config --unset of the provider type orphans nothing and goes through' => sub {
	plan tests => 3;

	# The departing provider's schema filled defaults the operator never
	# wrote.  A removal that leaves those behind is reported as a pile of
	# unknown keys, and there is then no way at all to turn a provider off.
	my $dir = concourse_repo('config-unset-type-alone');
	pushd $dir;
	prepare_command('config', '--unset', 'pipeline.provider.type');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, "the run succeeds, because nothing is orphaned");
	is($err, '', "and says nothing about keys the operator never wrote");
	unlike(slurp("$dir/.genesis/config"), qr/provider:/,
		"the provider block is gone from the saved file");
};

subtest 'config --unset of the whole provider block goes through' => sub {
	plan tests => 2;

	my $dir = concourse_repo('config-unset-provider-block');
	pushd $dir;
	prepare_command('config', '--unset', 'pipeline.provider');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, "removing the block is not refused");
	unlike(slurp("$dir/.genesis/config"), qr/provider:/,
		"and the block is gone from the saved file");
};

subtest 'config --unset of the whole section goes through' => sub {
	plan tests => 2;

	my $dir = concourse_repo('config-unset-pipeline-section');
	pushd $dir;
	prepare_command('config', '--unset', 'pipeline');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, "removing the section is not refused");
	unlike(slurp("$dir/.genesis/config"), qr/pipeline:/,
		"and the section is gone from the saved file");
};

subtest 'config --unset still refuses a key no schema declares' => sub {
	plan tests => 3;

	my $dir = config_repo('config-unset-unknown');
	my $before = slurp("$dir/.genesis/config");
	pushd $dir;
	prepare_command('config', '--unset', 'pipeline.provider.nonesuch');
	build_command_environment;

	# The refusal exits rather than dies, so the eval Test::Exit wraps the
	# block in has to be told to let it through.
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($out, $err, $code);
	($out, $err) = output_from {
		$code = exit_code { Genesis::Commands::Core::config() };
	};
	popd;

	like($err, qr/Cannot unset unknown configuration key/,
		"a key no schema declares is still refused by name");
	is($code, Genesis::Exit::CONFIG,
		"and the refusal carries the configuration exit code");
	is(slurp("$dir/.genesis/config"), $before,
		"and nothing is written");
};

subtest 'config --unset reads the schema the same run makes true' => sub {
	plan tests => 2;

	my $dir = config_repo('config-unset-new-provider-key', enabled => 0);
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.provider.type', 'concourse',
	                          '--unset', 'pipeline.provider.team');
	build_command_environment;
	my $raised = '';
	my ($out, $err) = output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	unlike($err.$raised, qr/unknown configuration key/,
		"a key the newly named provider declares is not refused as unknown");
	like(slurp("$dir/.genesis/config"), qr/type:\s*concourse/,
		"and the run saves what it set");
};

subtest "swapping the provider takes the old one's defaults with it" => sub {
	plan tests => 3;

	# The block's shape is a function of its own type, and the defaults a
	# provider filled belong to that provider.  Nothing empties the whole
	# default store between one validation and the next, so what keeps a
	# swap clean is the sweep the block's own path gets when the provider
	# the new type names validates it.  The block holds nothing but the
	# type, so every other key under it at the moment of the swap is a
	# default the departing provider filled.
	my $dir = concourse_repo('config-swap-provider');

	pushd $dir;
	prepare_command('config', '--set', 'pipeline.provider.type', 'github-actions');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, 'the swap goes through');
	unlike($err, qr/unknown configuration key/,
		'and no key of the departing provider is left behind to be refused');
	like(slurp("$dir/.genesis/config"), qr/type:\s*github-actions/,
		'the new type is saved');
};

subtest 'config --set-from-file will not overlap --set or --unset' => sub {
	plan tests => 2;

	my $dir = config_repo('config-from-file-overlap');
	mkfile_or_fail("$dir/value.txt", "concourse\n");
	pushd $dir;
	prepare_command('config', '--set-from-file', 'pipeline.provider.type', "$dir/value.txt",
	                          '--unset', 'pipeline.provider');
	build_command_environment;
	my $raised = '';
	my ($out, $err) = output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	like($err.$raised, qr/pipeline\.provider/, "names the overlapping keys");
	like(slurp("$dir/.genesis/config"), qr/type:\s*manual/,
		"leaves the file as it was");
};

subtest 'config --set-from-file reports a file it cannot read' => sub {
	plan tests => 2;

	my $dir = config_repo('config-from-file-missing');
	pushd $dir;
	prepare_command('config', '--set-from-file', 'manifest_store', "$dir/no-such-file");
	build_command_environment;
	my $raised = '';
	my ($out, $err) = output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	like($err.$raised, qr/no-such-file/, "names the file");
	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*exodus/,
		"writes nothing");
};

# A configuration the load refuses: the rc builds wrote a ci: block that no
# schema declares, and every command but this one refuses the file because
# of it.  genesis config is how an operator repairs it, so it has to be able
# to read the file, and to write the file it is repairing.
sub ci_repo {
	my ($name, %opts) = @_;
	my $dir = config_repo($name);
	my $enabled = (exists $opts{enabled} ? $opts{enabled} : 1) ? 'true' : 'false';
	mkfile_or_fail("$dir/.genesis/config", <<CFG);
---
ci:
  enabled: true
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: $enabled
  provider:
    type: manual
version: 3
CFG
	return $dir;
}

# Whether the next command could load the file, asked the way the next
# command asks it: a Top over the directory, and its configuration.
sub loads_cleanly {
	my ($dir) = @_;
	require Genesis::Top;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($code, $err);
	$err = stderr_from {
		$code = exit_code { Genesis::Top->new($dir, no_vault => 1)->config };
	};
	return (defined $code ? $code : 0, $err);
}

subtest 'config reads a configuration the load refuses' => sub {
	plan tests => 2;

	my $dir = ci_repo('config-read-refused');
	pushd $dir;
	prepare_command('config', 'deployment_type');
	build_command_environment;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($out, $err, $code);
	($out, $err) = output_from {
		$code = exit_code { Genesis::Commands::Core::config('deployment_type') };
	};
	popd;

	is($code, undef, "the read is not refused by the key it would be asked to repair");
	is($out, "test-kit\n", "and prints the value it was asked for");
};

subtest 'config --unset repairs a configuration the load refuses' => sub {
	plan tests => 5;

	my $dir = ci_repo('config-unset-refused');
	pushd $dir;
	prepare_command('config', '--unset', 'ci');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, "a key the file carries can be unset, though no schema declares it");
	my $cfg = slurp("$dir/.genesis/config");
	unlike($cfg, qr/^ci:/m, "the block is gone from the file");
	like($cfg, qr/^deployment_type:\s*test-kit$/m, "the rest of the file is left alone");
	like($cfg, qr/type:\s*manual/, "including the pipeline section");

	my ($load) = loads_cleanly($dir);
	is($load, 0, "and the next command loads the file it leaves");
};

subtest 'config --unset removes a nested key the file carries and no schema declares' => sub {
	plan tests => 2;

	my $dir = config_repo('config-unset-carried-nested');
	mkfile_or_fail("$dir/.genesis/config", <<'CFG');
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: true
  provider:
    nonesuch: x
    type: manual
version: 3
CFG
	pushd $dir;
	prepare_command('config', '--unset', 'pipeline.provider.nonesuch');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, "what the file carries can be unset at any depth");
	unlike(slurp("$dir/.genesis/config"), qr/nonesuch/, "and the key is gone");
};

subtest 'a run whose result the load would refuse writes nothing' => sub {
	plan tests => 4;

	my $dir = ci_repo('config-set-still-refused');
	my $before = slurp("$dir/.genesis/config");
	pushd $dir;
	prepare_command('config', '--set', 'manifest_store', 'repository');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, Genesis::Exit::CONFIG,
		"the run is refused at the configuration exit code");
	like($err, qr/ci: unknown configuration key/,
		"naming the key the result still carries");
	like($err, qr/configuration this run would write/,
		"as a problem with what the run would write, which has not been written");
	is(slurp("$dir/.genesis/config"), $before, "and the file is as it was");
};

subtest 'config --set and --unset of a refused file are judged on the result' => sub {
	plan tests => 3;

	# Disabled, for the reason 'config --set persists a value' gives.
	my $dir = ci_repo('config-unset-and-set-refused', enabled => 0);
	pushd $dir;
	prepare_command('config', '--unset', 'ci', '--set', 'manifest_store', 'repository');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, "the result loads, so the run goes through");
	my $cfg = slurp("$dir/.genesis/config");
	unlike($cfg, qr/^ci:/m, "the unset is applied");
	like($cfg, qr/manifest_store:\s*repository/, "and so is the set");
};

# A version 2 repository: no pipeline section on disk, and the older ci.yml
# beside it.  The load injects a v3-shaped pipeline default so the rest of
# Genesis sees a uniform shape, and that injected key is one the version 2
# schema never declares.
sub v2_repo {
	my ($name) = @_;

	# Harness::GitEnv, so no inherited GIT_DIR aims this at another repository.
	scrub_git_env();

	my $dir = workdir($name);

	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<'CFG');
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
version: 2
CFG
	mkfile_or_fail("$dir/ci.yml", <<'CI');
---
pipeline:
  name: test-kit
CI

	run({dir => $dir}, 'git', 'init', '-q');
	run({dir => $dir}, 'git', 'remote', 'add', 'origin',
		'https://github.com/genesis/test-kit-deployments.git');

	return $dir;
}

subtest 'config writes on a version 2 repository are not refused' => sub {
	plan tests => 6;

	# Loading a version 2 repository injects a pipeline default the version
	# 2 schema does not declare, and the write path validates again before
	# it saves.  A validation that inherited that injected default would
	# report it as an unknown key and refuse every write the repository can
	# make.
	my $dir = v2_repo('config-v2-writes');

	pushd $dir;
	prepare_command('config', '--set', 'minimum_version', '3.0.0');
	build_command_environment;
	my ($set_code, $set_err) = run_config();
	popd;

	is($set_code, 0, "--set goes through on a version 2 repository");
	unlike($set_err, qr/pipeline: unknown configuration key/,
		"and the injected pipeline default is not reported as a key nobody declared");
	like(slurp("$dir/.genesis/config"), qr/minimum_version:\s*3\.0\.0/,
		"the value is saved");

	pushd $dir;
	prepare_command('config', '--unset', 'minimum_version');
	build_command_environment;
	my ($unset_code, $unset_err) = run_config();
	popd;

	is($unset_code, 0, "--unset goes through too");
	unlike($unset_err, qr/pipeline: unknown configuration key/,
		"for the same reason, on the removal side");
	unlike(slurp("$dir/.genesis/config"), qr/minimum_version/,
		"and the key is gone from the saved file");
};

subtest 'a pipeline section is refused on a version 2 repository' => sub {
	plan tests => 4;

	# The version 2 schema declares the pipeline key so that the default
	# the load injects survives the first write.  Declaring a key is also
	# what makes it writable, so the write is refused on its own, and an
	# operator who wants a pipeline is told which upgrade gives them one.
	my $dir = v2_repo('config-v2-pipeline-write');

	pushd $dir;
	prepare_command('config', '--set', 'pipeline.enabled', 'true');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, Genesis::Exit::CONFIG,
		'the write is refused, at the configuration exit');
	like($err, qr/pipeline section belongs to a version 3 repository/,
		'and the refusal says where a pipeline section belongs');
	like($err, qr/genesis config --set version 3/,
		'and names the command that gets it there');
	unlike(slurp("$dir/.genesis/config"), qr/^pipeline:/m,
		'with nothing written to the file');
};

subtest 'config --set version 3 migrates a version 2 repository' => sub {
	plan tests => 3;

	# The version 3 schema is the version 2 schema with a version 3 and a
	# pipeline section, so a version 2 file whose version reads 3 is a
	# version 3 file.  The run is judged by the version it writes, not by
	# the one it found.
	my $dir = v2_repo('config-v2-to-v3');
	pushd $dir;
	prepare_command('config', '--set', 'version', '3');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, 'the version is set');
	like(slurp("$dir/.genesis/config"), qr/^version:\s*['"]?3['"]?$/m,
		'and saved');
	my ($load) = loads_cleanly($dir);
	is($load, 0, 'and the next command loads it as version 3');
};

subtest 'config migrates and writes a pipeline section in one run' => sub {
	plan tests => 3;

	# Setting the version changes the schema the run uses from that point,
	# so the pipeline keys beside it are read as version 3 keys.
	my $dir = v2_repo('config-v2-to-v3-with-pipeline');
	pushd $dir;
	prepare_command('config', '--set', 'version', '3',
	                          '--set', 'pipeline.enabled', 'true');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, 'the run is not refused for a pipeline section it makes legal');
	like(slurp("$dir/.genesis/config"), qr/^\s+enabled:\s*true$/m,
		'the pipeline section is saved');
	my ($load) = loads_cleanly($dir);
	is($load, 0, 'and the next command loads it');
};

subtest 'config --set version 2 is refused while a pipeline section remains' => sub {
	plan tests => 3;

	my $dir = config_repo('config-v3-to-v2-with-pipeline');
	my $before = slurp("$dir/.genesis/config");
	pushd $dir;
	prepare_command('config', '--set', 'version', '2');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, Genesis::Exit::CONFIG, 'the run is refused at the configuration exit');
	like($err, qr/pipeline section belongs to a version 3 repository/,
		'by the version 2 rule the result would be judged by');
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

subtest 'config --set version refuses a version Genesis does not support' => sub {
	plan tests => 3;

	my $dir = config_repo('config-unsupported-version');
	my $before = slurp("$dir/.genesis/config");
	pushd $dir;
	prepare_command('config', '--set', 'version', '4');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, Genesis::Exit::CONFIG, 'the run is refused at the configuration exit');
	like($err, qr/version 4 is not supported/, 'naming the version');
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

# A repository whose remote is a path, so nothing can derive the
# repository the pipeline lives in, with the pipeline not yet turned on.
sub path_remote_repo {
	my ($name) = @_;
	my $dir = config_repo($name, enabled => 0);
	run({dir => $dir}, 'git', 'remote', 'set-url', 'origin', "$dir/../no-such-remote.git");
	return $dir;
}

subtest 'config refuses a result the next command would refuse' => sub {
	plan tests => 3;

	# The schema accepts an enabled manual pipeline, but the load goes on to
	# ask where the pipeline lives, and a path remote cannot say.  A writer
	# that judged by the schema alone saved a file every command refused.
	my $dir = path_remote_repo('config-enable-underivable');
	my $before = slurp("$dir/.genesis/config");
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.enabled', 'true');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, Genesis::Exit::CONFIG, 'the run is refused at the configuration exit');
	like($err, qr/could not be derived/, "in the load's own words");
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

subtest 'config judges the end of the run, not the steps through it' => sub {
	plan tests => 2;

	# Turning the pipeline on before naming the repository would be refused
	# on its own; in one run with the repository beside it, it is not.
	my $dir = path_remote_repo('config-enable-with-repository');
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.enabled', 'true',
	                          '--set', 'pipeline.source_control.repository',
	                          'genesis/test-kit-deployments');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, 0, 'the run goes through');
	my ($load) = loads_cleanly($dir);
	is($load, 0, 'and the next command loads what it saved');
};

subtest 'config refuses a retired key in the load\'s own words' => sub {
	plan tests => 3;

	my $dir = config_repo('config-set-retired-remote');
	my $before = slurp("$dir/.genesis/config");
	pushd $dir;
	prepare_command('config', '--set', 'pipeline.source_control.remote', 'origin');
	build_command_environment;
	my ($code, $err) = run_config();
	popd;

	is($code, Genesis::Exit::CONFIG, 'the run is refused at the configuration exit');
	like($err, qr/is no longer read/, 'with the sentence that says what replaces it');
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

subtest 'a deployment root outside its repository exits 1' => sub {
	plan tests => 2;

	# Genesis::Exit keeps three numbers out of its table on purpose, and the
	# first of them is that a fatal system error stays a bare 1.  A
	# deployment root that is not inside its own repository is that kind of
	# defect, so the refusal takes the bare exit and a pipeline job reading
	# the number gets the one Genesis has always answered with.
	# Test::Exit runs the block inside an eval, and bail dies rather than
	# exits inside one unless it is told to ignore it, which is what the
	# other exit-code rows here do too.
	local $ENV{GENESIS_IGNORE_EVAL} = 1;

	my $dir = config_repo('carries-outside');
	require Service::Git;
	require Genesis::Top;
	my $git = Service::Git->new($dir);

	# A second repository root, so the Top's path is genuinely outside the
	# one the git handle answers for rather than merely named differently.
	my $elsewhere = config_repo('carries-elsewhere');
	my $top = Genesis::Top->new($elsewhere, no_vault => 1);

	# One call, so the refusal is read rather than printed past the row.
	my $code;
	my $said = stderr_from {
		$code = exit_code {
			Genesis::Commands::branch_carries_repository($top, $git, 'qa/bosh')
		};
	};

	is($code, 1, 'the refusal exits a bare 1 rather than a named code');
	like($said, qr/is not inside the repository at/,
		'and names the root, the repository, and the branch');
};

done_testing;
