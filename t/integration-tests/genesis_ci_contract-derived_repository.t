#!/usr/bin/env perl
# Proves T517 (D118; contract a1, a2): where pipeline.source_control.repository
# is not written, the pipeline's git resources clone the repository the
# deployment root is in, as Genesis::Top derives it from the clone's remote.
#
# The compiler read the key as written and nothing else, so a repository
# that left it to be derived, as the key allows, compiled every git resource
# with an empty uri.  Every harness writes the key, its remote being a path
# that names no repository, so no row had compiled a pipeline without it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

use Genesis qw/run/;
use Genesis::Config;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $ENV_NAME = $Harness::Contract::ENV_NAME;
my $ROOT     = $Harness::Contract::ROOT;

# A root with the key taken out, and its clone's one remote named by a URL
# whose traffic goes to the harness's bare repository.
sub underived {
	my (%o) = @_;
	my $h = contract_harness(config => $o{config} || {});

	my $path = "$ROOT/.genesis/config";
	my $config = Genesis::Config->new($h->a."/$path");
	$config->clear('pipeline.source_control.repository');
	$config->save;
	run({dir => $h->a}, 'git', 'add', '--', $path);
	run({dir => $h->a, onfailure => 'Failed to commit the config'},
		'git', 'commit', '-q', '-m', 'leave the repository to be derived');
	$h->_publish_control;

	if (my $remote = $o{remote}) {
		set_remotes($h, remotes => {origin => $remote}, upstream => 'origin', fetch => 0);
		run({dir => $h->a}, 'git', 'config', "url.@{[$h->r]}.insteadOf", $remote);
	}
	return $h;
}

sub git_uris {
	my ($p) = @_;
	return {map {($_->{name} => $_->{source}{uri})} grep {($_->{type} // '') eq 'git'} @{$p->{resources} || []}};
}

subtest 'the key as written still composes the uri' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is(git_uris($p)->{'control-branch'}, 'git@github.com:genesis/doomsday-deployments.git',
		'a2: from the repository the configuration names');
};

subtest "with no key, the uri is the clone's own repository" => sub {
	my $h = underived(remote => 'git@github.com:acme/doomsday-deployments.git');
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	my $uris = git_uris($p);
	is($uris->{'control-branch'}, 'git@github.com:acme/doomsday-deployments.git',
		'a2: the control resource clones the repository the remote names');
	is($uris->{"$ENV_NAME-branch"}, 'git@github.com:acme/doomsday-deployments.git',
		"a2: and so does the environment's");
	is_deeply([grep {!length($uris->{$_} // '')} sort keys %$uris], [], 'a2: no git resource has an empty uri');
};

subtest 'the form is the credential\'s, and the host the remote\'s' => sub {
	my $h = underived(
		remote => 'git@ghe.example.com:acme/doomsday-deployments.git',
		config => {
			'pipeline.source_control.auth.type' => 'https',
			'pipeline.source_control.auth.path' => 'gh',
		});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is(git_uris($p)->{'control-branch'}, 'https://ghe.example.com/acme/doomsday-deployments.git',
		'a2: an https credential clones over https, on the enterprise host the remote is on');
};

subtest 'a repository that cannot be derived is refused, not compiled empty' => sub {
	my $h = underived();   # the harness's own remote is a path, which names none
	my ($p, $why) = dry_pipeline($h);
	ok(!$p, 'the dry apply refuses') or return diag(explain(git_uris($p)));
	like($why, qr/^exit 78\b/, 'at CONFIG');
	like($why, qr/pipeline\.source_control\.repository/, 'naming the key');
};

done_testing;
