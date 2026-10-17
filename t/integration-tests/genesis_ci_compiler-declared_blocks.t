#!perl
# Proves T382: every declared block the compiler uses reaches it (D27, noted
# 2026-10-16; the converse of T380).  The inline parser hands the compiler the
# pipeline section's locker and notifications as it hands it vault and
# source_control, so a compile over an environment whose BOSH director the
# pipeline manages does not refuse for want of a locker that is configured.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

subtest 'the parser hands the compiler the declared locker and notifications' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa'], provider => 'concourse', vault => 0);
	my $top = load_with($h, automated_config('concourse',
		'url: https://ci.example.com', 'team: main'));
	require Genesis::CI::Compiler::Parser;
	my $parsed = Genesis::CI::Compiler::Parser->new(top => $top)->parse;
	is($parsed->{integrations}{locker}{url}, $top->pipeline_section->{locker}{url},
		'the locker is the configured one');
	is_deeply($parsed->{integrations}{notifications}, $top->pipeline_section->{notifications},
		'and so are the notifications, absent or not');
};

subtest 'a pipeline-managed director compiles with the configured locker' => sub {
	# Two rows; the compile writes its output directory, so no restoration row.
	plan tests => 2;

	my $h = make_harness(envs => ['lab', 'qa'], chained => 1, provider => 'concourse');
	write_env_file($h, 'qa', genesis => {bosh_env => 'lab'}, pipeline => {prior_env => 'lab'},
		commit => 0);
	my $out = workdir('compiled');
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply',
		'--dry-run', '--skip-vault', '--output-dir', $out);
	is($exit, 0, 'the compile succeeds') or diag($err);
	unlike(unfolded($err), qr/no locker integration is configured/,
		'without asking for a locker the configuration has');
};

done_testing;
