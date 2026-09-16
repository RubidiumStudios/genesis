#!/usr/bin/env perl
# Proves T160 and T161 at the two subs that decide them: a commit is routed
# on its triggering content alone and records nothing where it has none, and
# the overlap that holds a descendant is read over triggering paths only.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::CI::Walk;
use Genesis::Env;
use Genesis::Top;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The repository the rows below read through, with one environment and a kit,
# because the at-commit reader refuses a commit that carries no kit.  The
# harness answers the environment, the handle, and the commit its seeding
# left, and every row lays its own commits on top of that.
sub fixture {
	my $h = make_harness(envs => ['qa'], root => '', kit => 'omega-v2.7.0');

	my $git = Service::Git->new($h->a);
	my $top = Genesis::Top->new($h->a);
	my $env = Genesis::Env->bare('qa', $top);
	return ($h, $git, $env);
}

subtest 'a commit is routed on its triggering content alone' => sub {
	plan tests => 3;

	my ($h, $git, $env) = fixture();

	# The configuration is changed through the writer that knows the schema,
	# because an undeclared key is refused by name at configuration load.
	set_repo_config($h, 'pipeline.name', 'touched', commit => 0);
	my $quiet = commit_on_control($h,
		files   => {'.genesis/config' => slurp($h->a . '/.genesis/config')},
		message => 'Adjust the config',
	);
	is(Genesis::CI::Walk::route_commit($git, $env, $quiet), undef,
		'a commit whose content is only non-triggering is routed nowhere');

	set_repo_config($h, 'pipeline.name', 'touched again', commit => 0);
	my $both = commit_on_control($h,
		files => {
			'.genesis/config' => slurp($h->a . '/.genesis/config'),
			'qa.yml'          => slurp($h->a . '/qa.yml') . "# tuned\n",
		},
		message => 'Tune qa and adjust the config',
	);
	my $routed = Genesis::CI::Walk::route_commit($git, $env, $both);
	is_deeply($routed->{triggering}, ['qa.yml'],
		'the environment file is what routes the commit');
	is_deeply($routed->{carried}, ['.genesis/config'],
		'and the configuration rides along as carried content');
};

subtest 'the overlap keeps only what both lists name' => sub {
	plan tests => 3;

	is_deeply([Genesis::CI::Walk::overlap(['qa.yml', 'dev/'], ['dev/', 'lab.yml'])],
		['dev/'], 'the shared path is the whole answer');
	is_deeply([Genesis::CI::Walk::overlap(['qa.yml'], ['lab.yml'])],
		[], 'two lists that share nothing overlap in nothing');
	is_deeply([Genesis::CI::Walk::overlap(['qa.yml'], [])],
		[], 'an ancestor with nothing undeployed holds nobody');
};

subtest 'a non-triggering commit behind a hold records no outcome' => sub {
	plan tests => 4;

	my ($h, $git, $env) = fixture();
	my $base = $git->sha($h->control);

	my $held = commit_on_control($h,
		files   => {'qa.yml' => slurp($h->a . '/qa.yml') . "# first\n"},
		message => 'Tune qa once',
	);
	set_repo_config($h, 'pipeline.name', 'touched', commit => 0);
	commit_on_control($h,
		files   => {'.genesis/config' => slurp($h->a . '/.genesis/config')},
		message => 'Adjust the config',
	);
	my $after = commit_on_control($h,
		files   => {'qa.yml' => slurp($h->a . '/qa.yml') . "# second\n"},
		message => 'Tune qa again',
	);

	my $record = {pending => [], held => []};
	Genesis::CI::Walk::walk_env(
		git     => $git,
		env     => $env,
		record  => $record,
		control => $git->sha($h->control),
		base    => $base,
		# The first due commit is held, so everything after it is read
		# through the behind-held-commit path, which is where a commit that
		# routes nowhere used to record an outcome of its own.
		hold_check => sub {
			my ($commit) = @_;
			return $commit->{sha} eq $held ? {reason => 'on-hold'} : undef;
		},
	);

	is(scalar @{$record->{pending}}, 0, 'the hold left nothing pending');
	is(scalar @{$record->{held}}, 2,
		'the held commit and the triggering one behind it are the whole record');
	is($record->{held}[0]{control_commit}, $held, 'the hold names its own commit');
	is($record->{held}[1]{control_commit}, $after,
		'the commit behind it is the next triggering one, not the config');
};

done_testing;
