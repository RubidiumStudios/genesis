#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;
use Test::Exit;

use Genesis::Commands;
use PadWalker qw/closed_over/;
use Genesis;

# Initialize the Genesis environment
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

subtest 'bin/genesis' => sub {

	require_ok './bin/genesis';

	# TODO: Add tests to make sure all the defined commands are valid in their definitions in general (ie: specify existing function groups, correct format of options, etc)

};

subtest 'genesis terminate' => sub {
	plan tests => 59;

	ok(has_command('terminate'), "Terminate command is registered");

	ok(is_equivalent_command('destroy' => 'terminate'), "terminate command aliases to 'destroy'");
	ok(is_equivalent_command(terminate => 'kill'), "terminate command aliases to 'delete'");
	not_ok(is_equivalent_command(terminate => 'deploy'), "terminate command does not alias to 'deploy'");
	not_ok(is_equivalent_command('','terminate'), "terminate command does not alias to 'init'");
	cmp_bag([equivalent_commands('terminate')], ['terminate', 'implode', 'destroy', 'kill'], "terminate command aliases to 'implode', 'destroy', and 'kill' (and itself), but no others");

	is(command_properties('terminate')->{function_group}, Genesis::Commands::ENVIRONMENT, "Terminate command belongs to environment group"); # This works becaus its a constant
	is(command_properties('terminate')->{scope}, 'env', "Terminate command has env scope");
	is(command_properties('terminate')->{option_group}, Genesis::Commands::ENV_OPTIONS, "Terminate command uses ENV_OPTIONS");

	my %terminate_opts = command_properties('terminate')->{options}->@*;
	ok(exists $terminate_opts{'keep-secrets|S'}, "terminate has keep-secrets option");
	ok(exists $terminate_opts{'keep-resources|R'}, "terminate has keep-resources option");
	ok(exists $terminate_opts{'force|f'}, "terminate has force option");
	ok(exists $terminate_opts{'yes|y'}, "terminate has yes (no-prompt) option");
	ok(exists $terminate_opts{'dry-run|n'}, "terminate has dry-run option");
	is(scalar(keys %terminate_opts), 5, "terminate only has the 5 options above");

	my %terminate_args = command_properties('terminate')->{arguments}->@*;
	is(scalar(keys %terminate_args), 1, "terminate has one argument");
	ok(exists $terminate_args{reason}, "terminate has a 'reason' argument");

	not_ok(command_properties('terminate')->{deprecated}, "terminate command is not deprecated");

	my $subref = $Genesis::Commands::RUN{terminate};
	is(ref($subref), 'CODE', "terminate command has a subroutine reference");
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Env::terminate',
		'$fn_require' => \'Genesis/Commands/Env.pm',
		'$name' => \'terminate',
	}, "terminate command subroutine has the correct closed-over variables");

	# Setup a dry-run terminate command
	prepare_command('terminate', 'my-env','-f','-SR','--dry-run','--yes','reason');
	build_command_environment

	my @args = get_args();
	$args[0] = mock 'Genesis::Env' => {
		name => 'my-env',
		type => 'my-type',
		notify => sub {
			my ($self, $msg) = @_;
			info("[my-env/my-type] ".$msg);
		},
		terminate => sub {
			my ($self, %opts) = @_;
			
			is($self->name, 'my-env', "terminate called with correct environment name");
			is($opts{reason}, 'reason', "terminate called with correct reason");
			ok($opts{force},"terminate called with force");
			ok($opts{'keep-secrets'}, "terminate called with keep-secrets");
			ok($opts{'keep-resources'}, "terminate called with keep-resources");
			ok($opts{'dry-run'}, "terminate called with dry-run");
			not_ok($opts{yes}, "terminate called with yes (should be stripped)");

			return 1;
		},
	};

	my ($stdout, $stderr) = output_from {
		exits_zero { $subref->(@args) } "terminate dry-run command exits with 0";
	};
	like($stderr, qr/\[my-env\/my-type] This would terminate this deployment/, "terminate dry-run command prints dry-run message");
	like($stderr, qr/- all its VMs and persistent disks would be destroyed/, "terminate dry-run command prints VM and disk destruction message");
	like($stderr, qr/- this environment's secrets would be left in place/, "terminate dry-run command prints secret retention message (--keep-secrets)");
	like($stderr, qr/- all unused resources would be left in place/, "terminate dry-run command prints resource retention message (--keep-resources)");
	like($stderr, qr/my-env\/my-type termination dry-run completed/, "terminate dry-run command prints termination message");
	is($stdout, '', "terminate dry-run command prints nothing to stdout");

	# Run a successful terminate command
	prepare_command('terminate', 'my-env','-f','-y');
	build_command_environment;

	@args = get_args();
	$args[0] = mock 'Genesis::Env' => {
		name => 'my-env',
		type => 'my-type',
		notify => sub {
			my ($self, $msg) = @_;
			info("[my-env/my-type] ".$msg);
		},
		terminate => sub {
			my ($self, %opts) = @_;
			
			is($opts{reason}, undef, "terminate called with no reason");
			ok($opts{force},"terminate called with force");
			not_ok($opts{'keep-secrets'}, "terminate called without keep-secrets");
			not_ok($opts{'keep-resources'}, "terminate called without keep-resources");
			not_ok($opts{'dry-run'}, "terminate called without dry-run");
			not_ok($opts{yes}, "terminate called with yes (should be stripped)");

			return 1;
		},
	};
	($stdout, $stderr) = output_from {
		exits_zero { $subref->(@args) } "terminate command exits with 0";
	};

	like($stderr, qr/\[my-env\/my-type] This will terminate this deployment/, "terminate dry-run command prints dry-run message");
	like($stderr, qr/- all its VMs and persistent disks will be destroyed/, "terminate dry-run command prints VM and disk destruction message");
	like($stderr, qr/- this environment's secrets will be removed \(use --keep-secrets to skip\)/, "terminate dry-run command prints secret destruction message");
	like($stderr, qr/- all unused resources will be removed from the BOSH director \(use\n\s*--keep-resources to skip\)/, "terminate dry-run command prints resource destruction message");
	like($stderr, qr/my-env\/my-type terminated successfully/, "terminate command prints successful termination message");
	is($stdout, '', "terminate successful command prints nothing to stdout");

	# Run a terminal command with prompt, but abort
	prepare_command('terminate', 'my-env', 'trying to do something bad');
	build_command_environment;

	my $return_value = 1;
	@args = get_args();
	$args[0] = mock 'Genesis::Env' => {
		name => 'my-env',
		type => 'my-type',
		notify => sub {
			my ($self, $msg) = @_;
			info("[my-env/my-type] ".$msg);
		},
		terminate => sub {
			my ($self, %opts) = @_;
			
			is($opts{reason}, 'trying to do something bad', "terminate called with correct reason");
			not_ok($opts{force},"terminate called without force");
			not_ok($opts{'keep-secrets'}, "terminate called without keep-secrets");
			not_ok($opts{'keep-resources'}, "terminate called without keep-resources");
			not_ok($opts{'dry-run'}, "terminate called without dry-run");
			not_ok($opts{yes}, "terminate called without yes");

			return $return_value;
		},
	};
	# Redirect STDIN to answer 'n' to the prompt
	set_stdin("n\n");
	$ENV{GENESIS_IGNORE_EVAL} = 1; # Prevent the eval from catching the exit
	($stdout, $stderr) = output_from {
		exits_nonzero { $subref->(@args) } "terminate command exits with non-zero";
	};
	# Clean up the STDIN redirection
	reset_stdin;

	is($stdout, '', "terminate failed command prints nothing to stdout");
	$stderr =~ s/\e\[\?25h$//; # Strip ANSI show cursor code
	eq_or_diff($stderr, <<'EOF', "terminate failed command prints failure message");
[my-env/my-type] This will terminate this deployment:
  - all its VMs and persistent disks will be destroyed
  - this environment's secrets will be removed (use --keep-secrets to skip)
  - all unused resources will be removed from the BOSH director (use
    --keep-resources to skip)

[WARNING] This action is irreversible and cannot be undone!

Are you sure you want to terminate my-env/my-type deployment? [y|N] > 
[FATAL] Aborted by user!

EOF

	# Run a failing terminate command with --yes, don't abort
	$return_value = 0;
	set_stdin("y\n");
	$ENV{GENESIS_IGNORE_EVAL} = 1; # Prevent the eval from catching the exit
	($stdout, $stderr) = output_from {
		exits_nonzero { $subref->(@args) } "terminate command exits with non-zero";
	};
	reset_stdin;

	is($stdout, '', "terminate failed command prints nothing to stdout");
	$stderr =~ s/\e\[\?25h$//; # Strip ANSI show cursor code
	eq_or_diff($stderr, <<'EOF', "terminate failed command prints failure message");
[my-env/my-type] This will terminate this deployment:
  - all its VMs and persistent disks will be destroyed
  - this environment's secrets will be removed (use --keep-secrets to skip)
  - all unused resources will be removed from the BOSH director (use
    --keep-resources to skip)

[WARNING] This action is irreversible and cannot be undone!

Are you sure you want to terminate my-env/my-type deployment? [y|N] > 
[FATAL] my-env/my-type termination failed!

EOF

};

done_testing;
