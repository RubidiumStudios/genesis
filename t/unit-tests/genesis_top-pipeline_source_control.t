#!perl
# Proves T17, T18, T311, and T19: the source-control block declares the
# two branch-naming keys with the pr/ default, it declares three tiers of
# field, it refuses an empty pull request prefix, and it refuses a host
# that is not GitHub with no exception under the manual provider.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;
use Test::Exception;

use Genesis;
provide_rc();
use_ok 'Genesis::Top';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

# The harness clones copy A from a bare repository at a filesystem path, so
# copy A's origin URL carries no GitHub owner/repo pair and the repository
# cannot be derived.  Every row that is not about the derivation therefore
# names the repository explicitly, and the rows that prove the refusal ask
# for the derivation and take the override away again.
sub with_repository {
	my ($body) = @_;
	my $override = '    repository: team/bosh';
	return $body if $body =~ s/^  source_control:$/  source_control:\n$override/m;
	return join("\n", $body, '  source_control:', $override);
}

# Two rows in a row can ask for the same configuration, and a commit needs
# a delta, so each load carries its own count beside the file under test.
my $loads = 0;

sub load_with {
	my ($body, %opts) = @_;
	$body = with_repository($body) unless $opts{derive_repository};
	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "3"',
			'creator_version: 3.2.0', $body, ''),
		'.load-count' => sprintf("%d\n", ++$loads),
	});
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

sub with_remote {
	my ($url) = @_;
	run({dir => $h->a}, 'git', 'remote', 'remove', 'origin');
	run({dir => $h->a}, 'git', 'remote', 'add', 'origin', $url);
}

subtest 'the two branch-naming keys are declared' => sub {
	plan tests => 4;

	my $top = load_with(join("\n",
		'pipeline:', '  enabled: true',
		'  source_control:', '    control_branch: trunk'));
	is $top->config->get('pipeline.source_control.control_branch'), 'trunk',
		'control_branch is a declared key';
	is $top->config->get('pipeline.source_control.pr_prefix'), 'pr/',
		'pr_prefix resolves to pr/ when absent';

	throws_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    control_branch: [a, b]'))}
		qr/pipeline\.source_control\.control_branch: expected a string/,
		'a control_branch outside its type is refused by name';

	throws_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    pr_prefix: [pr, review]'))}
		qr/pipeline\.source_control\.pr_prefix/,
		'a pr_prefix outside its type is refused by name';
};

subtest 'the block declares three tiers and refuses runtime state' => sub {
	plan tests => 5;

	my $top = load_with("pipeline:\n  enabled: true");
	my $sc  = $top->_repo_config_schema->{pipeline}{schema}{source_control}{schema};
	is_deeply [sort grep {!$sc->{$_}{required}} keys %$sc],
		[qw/control_branch control_requires_pr pr_prefix remote repository uri/],
		'the overridable and defaulted fields are the six the design names';
	is_deeply [sort grep {$sc->{$_}{required}} keys %$sc],
		[qw/auth identity/],
		'auth and identity are the required pair';

	# Required under an automated provider, tolerated as absent under manual.
	lives_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual'))}
		'manual tolerates an absent auth and identity';
	throws_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: concourse', '    target: ci',
		'  source_control:', '    remote: origin'))}
		qr/pipeline\.source_control: missing required key/,
		'an automated provider requires them';

	# The deployment root and the running branch take no key at all.
	throws_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    branch: feature/x'))}
		qr/pipeline\.source_control\.branch: unknown configuration key/,
		'a key naming the branch a command runs from is refused by name';
};

subtest 'an empty pull request prefix is refused' => sub {
	plan tests => 3;

	throws_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', "    pr_prefix: ''"))}
		qr/pipeline\.source_control\.pr_prefix.*empty/s,
		'an empty prefix is refused by name';
	lives_ok {load_with("pipeline:\n  enabled: true")}
		'the default pr/ passes';
	lives_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    pr_prefix: pr-'))}
		'an explicit prefix passes';
};

subtest 'the MVP supports GitHub and says so' => sub {
	plan tests => 4;

	with_remote('https://git.example.com/team/bosh.git');
	throws_ok {load_with("pipeline:\n  enabled: true", derive_repository => 1)}
		qr/pipeline\.source_control\.repository/,
		'a non-GitHub host is refused naming the key';
	throws_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual'), derive_repository => 1)}
		qr/pipeline\.source_control\.repository/,
		'and the manual provider takes no exception';

	with_remote('https://github.example.com/team/bosh.git');
	lives_ok {load_with("pipeline:\n  enabled: true", derive_repository => 1)}
		'GitHub Enterprise passes, because its URL carries owner/repo';

	with_remote('git@github.com:team/bosh.git');
	my $top = load_with("pipeline:\n  enabled: true", derive_repository => 1);
	is $top->_source_control->{repository}, 'team/bosh',
		'the ssh form parses to owner/repo';
};

subtest 'a required flag can be a predicate' => sub {
	plan tests => 3;

	# The branch the four blocks above hang on, read directly, because a
	# predicate that is quietly treated as a sibling name is required
	# nowhere and no row above would notice.
	my $yes = sub {1};
	my $no  = sub {0};
	is Genesis::Config::_is_required($yes, {}), 1,
		'a code reference that says yes makes the key required';
	is Genesis::Config::_is_required($no, {}), 0,
		'and one that says no does not';

	my $seen;
	Genesis::Config::_is_required(sub {$seen = $_[0]; 0}, {type => 'concourse'});
	is_deeply $seen, {type => 'concourse'},
		'the predicate is handed the siblings around the key';
};

done_testing;
