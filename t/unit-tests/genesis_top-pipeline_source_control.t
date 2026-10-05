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
use Genesis::Exit qw/CONFIG/;
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

# Every row here goes through the harness loader, and this puts the named
# repository into the body on the way, because that is what this file wants
# of nearly every row and the harness has no business knowing it.  A row
# that is about the derivation asks for derive_repository and gets the body
# it wrote.
sub load_control {
	my ($body, %opts) = @_;
	$body = with_repository($body) unless $opts{derive_repository};
	return load_with($h, $body);
}

sub with_remote {
	my ($url) = @_;
	run({dir => $h->a}, 'git', 'remote', 'remove', 'origin');
	run({dir => $h->a}, 'git', 'remote', 'add', 'origin', $url);
}

subtest 'the two branch-naming keys are declared' => sub {
	plan tests => 4;

	my $top = load_control(join("\n",
		'pipeline:', '  enabled: true',
		'  source_control:', '    control_branch: trunk'));
	is $top->config->get('pipeline.source_control.control_branch'), 'trunk',
		'control_branch is a declared key';
	is $top->config->get('pipeline.source_control.pr_prefix'), 'pr/',
		'pr_prefix resolves to pr/ when absent';

	throws_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    control_branch: [a, b]'))}
		qr/pipeline\.source_control\.control_branch: expected a string/,
		'a control_branch outside its type is refused by name';

	throws_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    pr_prefix: [pr, review]'))}
		qr/pipeline\.source_control\.pr_prefix/,
		'a pr_prefix outside its type is refused by name';
};

subtest 'the block declares three tiers and refuses runtime state' => sub {
	plan tests => 5;

	my $top = load_control("pipeline:\n  enabled: true");
	my $sc  = $top->_repo_config_schema->{pipeline}{schema}{source_control}{schema};
	is_deeply [sort grep {!$sc->{$_}{required}} keys %$sc],
		[qw/control_branch control_requires_pr pr_prefix remote repository uri/],
		'the overridable and defaulted fields are the six the design names';
	is_deeply [sort grep {$sc->{$_}{required}} keys %$sc],
		[qw/auth identity/],
		'auth and identity are the required pair';

	# Required under an automated provider, tolerated as absent under manual.
	lives_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual'))}
		'manual tolerates an absent auth and identity';
	throws_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: concourse', '    target: ci',
		'  source_control:', '    remote: origin'))}
		qr/pipeline\.source_control: missing required key/,
		'an automated provider requires them';

	# The deployment root and the running branch take no key at all.
	throws_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    branch: feature/x'))}
		qr/pipeline\.source_control\.branch: unknown configuration key/,
		'a key naming the branch a command runs from is refused by name';
};

subtest 'an empty pull request prefix is refused' => sub {
	plan tests => 3;

	throws_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', "    pr_prefix: ''"))}
		qr/pipeline\.source_control\.pr_prefix.*empty/s,
		'an empty prefix is refused by name';
	lives_ok {load_control("pipeline:\n  enabled: true")}
		'the default pr/ passes';
	lives_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    pr_prefix: pr-'))}
		'an explicit prefix passes';
};

subtest 'an empty control branch is refused' => sub {
	plan tests => 2;

	throws_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', "    control_branch: ''"))}
		qr/pipeline\.source_control\.control_branch.*empty/s,
		'an empty control branch is refused by name';
	lives_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    control_branch: trunk'))}
		'and a named one passes';
};

subtest 'the MVP supports GitHub and says so' => sub {
	plan tests => 4;

	with_remote('https://git.example.com/team/bosh.git');
	throws_ok {load_control("pipeline:\n  enabled: true", derive_repository => 1)}
		qr/pipeline\.source_control\.repository/,
		'a non-GitHub host is refused naming the key';
	throws_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual'), derive_repository => 1)}
		qr/pipeline\.source_control\.repository/,
		'and the manual provider takes no exception';

	with_remote('https://github.example.com/team/bosh.git');
	lives_ok {load_control("pipeline:\n  enabled: true", derive_repository => 1)}
		'GitHub Enterprise passes, because its URL carries owner/repo';

	with_remote('git@github.com:team/bosh.git');
	my $top = load_control("pipeline:\n  enabled: true", derive_repository => 1);
	is $top->_source_control->{repository}, 'team/bosh',
		'the ssh form parses to owner/repo';
};

subtest 'the url is asked of git only where it is needed' => sub {
	plan tests => 2;

	with_remote('git@github.com:team/bosh.git');

	my $named = load_control("pipeline:\n  enabled: true");
	is $named->source_control_uri, undef,
		'a named repository leaves the fetch url unasked for';

	my $derived = load_control("pipeline:\n  enabled: true",
		derive_repository => 1);
	is $derived->source_control_uri, 'git@github.com:team/bosh.git',
		'and the url is read where the repository comes out of it';
};

subtest 'the uri row says whether git was asked' => sub {
	plan tests => 4;

	with_remote('git@github.com:team/bosh.git');

	my $named = load_control("pipeline:\n  enabled: true");
	my ($unasked) = grep {$_->{key} eq 'uri'}
		@{$named->source_control_resolved};
	is $unasked->{source}, 'unset',
		'a url nobody asked git for is not reported as derived';
	is $unasked->{value}, '(none)', 'and the row says it has no value';

	my $derived = load_control("pipeline:\n  enabled: true",
		derive_repository => 1);
	my ($answered) = grep {$_->{key} eq 'uri'}
		@{$derived->source_control_resolved};
	is $answered->{source}, 'derived', 'a url git answered for is derived';
	is $answered->{value}, 'git@github.com:team/bosh.git',
		'and the row carries what git said';
};

# Proves T57's parsing half under D118: a repository is one identity, host,
# owner and repo, however it is written.
subtest 'a repository is one identity however it is written' => sub {
	plan tests => 10;

	my $id = \&Genesis::Top::_repository_identity;
	my $want = {host => 'github.com', owner => 'team', repo => 'bosh'};
	is_deeply($id->('team/bosh'), $want, 'owner/repo assumes github.com');
	is_deeply($id->('https://github.com/team/bosh'), $want, 'an https URL');
	is_deeply($id->('https://github.com/team/bosh.git/'), $want,
		'with a .git suffix and a trailing slash dropped');
	is_deeply($id->('git@github.com:team/bosh.git'), $want, 'the scp-like ssh form');
	is_deeply($id->('ssh://git@github.com/team/bosh.git'), $want, 'an ssh URL');
	is_deeply($id->('https://GitHub.com/Team/Bosh.git'),
		{host => 'github.com', owner => 'Team', repo => 'Bosh'},
		'the host is lowercased and owner and repo keep their spelling');
	is(Genesis::Top::_identity_key($id->('https://GitHub.com/Team/Bosh.git')),
		Genesis::Top::_identity_key($want),
		'and two spellings of one repository compare equal');
	is_deeply($id->('https://github.example.com/team/bosh'),
		{host => 'github.example.com', owner => 'team', repo => 'bosh'},
		'an Enterprise host keeps its own name');
	is($id->('https://git.example.com/team/bosh.git'), undef,
		'a host that is not GitHub carries no identity in the MVP');
	is($id->('just-a-name'), undef, 'and neither does a bare word');
};

subtest 'the resolved remote is set on the shared handle' => sub {
	plan tests => 3;

	my $top = load_control("pipeline:\n  enabled: true");
	my $remote = $top->source_control_remote;
	isa_ok($top->git, 'Service::Git', 'Top->git');
	is($top->git, Service::Git->new($h->a),
		'is the one handle every caller of the repository shares');
	is($top->git->pipeline_remote, $remote,
		'and it carries the remote the source-control block resolved');
};

subtest 'repository may be written as owner/repo or as a URL' => sub {
	plan tests => 4;

	for my $written ('team/bosh', 'https://github.com/team/bosh.git',
	                 'git@github.com:team/bosh.git') {
		my $body = join("\n", 'pipeline:', '  enabled: true',
			'  source_control:', "    repository: $written");
		is(load_control($body, derive_repository => 1)->source_control_repository,
			'team/bosh', "$written is read as team/bosh");
	}

	throws_ok {load_control(join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    repository: not-a-repository'),
		derive_repository => 1)}
		qr/pipeline\.source_control\.repository/,
		'and a value that names no repository is refused by the key';
};

# The remote a clone's configuration resolves to, with the clone's remotes
# swapped for the ones a row names.  The configuration is loaded and published
# through the real origin first, and the named remotes go in without a fetch,
# because finding the remote reads URLs and contacts nothing; origin is put
# back, fetched, before the row reads anything else.
sub resolved {
	my (%o) = @_;
	load_control(join("\n", 'pipeline:', '  enabled: true',
		(defined $o{repository}
			? ('  source_control:', "    repository: $o{repository}") : ())),
		derive_repository => 1);
	my ($origin) = run({dir => $h->a}, 'git', 'remote', 'get-url', 'origin');
	chomp $origin;

	set_remotes($h, remotes => $o{remotes}, upstream => $o{upstream} // 0,
		fetch => 0);
	run({dir => $h->a}, 'git', 'config', @$_) for @{$o{git_config} || []};

	local $ENV{GENESIS_IGNORE_EVAL} = '';
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	my $remote = eval {$top->source_control_remote};
	my $error  = $@;
	my $repository = $remote ? $top->source_control_repository : undef;

	run({dir => $h->a, passfail => 1}, 'git', 'config', '--unset-all', $_->[0])
		for @{$o{git_config} || []};
	set_remotes($h, remotes => {origin => $origin}, upstream => 'origin');
	return ($remote, $error, $repository);
}

# Proves T354 at the resolver: the remote is the one that points at the
# repository, under any name and in any spelling (D118).
subtest 'the remote is found by the repository it points at' => sub {
	plan tests => 10;

	# A remote pointing elsewhere sorts ahead of every name below, so a row
	# that passes did not pass by taking the first remote git lists.
	my $decoy = 'git@github.com:someone/else.git';

	is((resolved(repository => 'team/bosh', remotes => {
			aaa => $decoy, upstream => 'git@github.com:team/bosh.git'}))[0],
		'upstream', 'a remote not named origin, over ssh');
	is((resolved(repository => 'team/bosh', remotes => {
			aaa => $decoy, origin => 'https://GitHub.com/Team/Bosh.git/'}))[0],
		'origin', 'a URL differing in case and carrying a trailing slash');

	# ssh reads its configuration from the home the user database names, not
	# from $HOME, so a test cannot write an alias for it to read.  The alias
	# is answered here, and ssh_hostname's own reading of ssh -G is proved
	# against a host that needs no configuration at all.
	{
		no warnings 'redefine';
		local *Service::Git::ssh_hostname = sub {
			$_[1] eq 'gh-work' ? 'github.com' : $_[1];
		};
		is((resolved(repository => 'team/bosh', remotes => {
				aaa => $decoy, work => 'git@gh-work:team/bosh.git'}))[0],
			'work', 'an ssh host alias resolved to github.com');
	}
	is($h->git('a')->ssh_hostname('github.com'), 'github.com',
		'and ssh_hostname reads the host ssh -G prints');

	is((resolved(repository => 'team/bosh',
			remotes => {aaa => $decoy, short => 'gh:team/bosh'},
			git_config => [['url.git@github.com:.insteadOf', 'gh:']]))[0],
		'short', 'a shorthand resolved through its insteadOf rewrite');

	my ($remote, undef, $repository) = resolved(
		remotes => {upstream => 'git@github.com:team/bosh.git'});
	is($remote, 'upstream', 'with no repository set, the one remote is used');
	is($repository, 'team/bosh', 'and the repository is derived from it');

	($remote) = resolved(repository => 'team/bosh',
		remotes => {origin => '/srv/git/bosh.git'});
	is($remote, 'origin', 'a single remote that is a path is used as it stands');

	my (undef, $error) = resolved(repository => 'team/bosh',
		remotes => {origin => 'git@github.com:other/repo.git'});
	like($error, qr{team/bosh}, 'a single remote naming another repository is refused');
	like($error, qr{other/repo}, 'and the refusal shows what it points at');
};

# Proves T355 at the resolver: a fork is never chosen (D118).
subtest 'a fork never wins' => sub {
	plan tests => 4;

	my %remotes = (origin => 'git@github.com:me/bosh.git',
	               upstream => 'git@github.com:team/bosh.git');

	is((resolved(repository => 'team/bosh', remotes => \%remotes,
			upstream => 'origin'))[0],
		'upstream', 'the canonical remote, though control tracks the fork');

	my (undef, $error) = resolved(remotes => \%remotes, upstream => 'origin');
	like($error, qr{more than one repository},
		'with no repository set, remotes naming two repositories are refused');
	like($error, qr{me/bosh.*team/bosh|team/bosh.*me/bosh}s,
		'naming both repositories');
	like($error, qr{pipeline\.source_control\.repository},
		'and the key that settles it');
};

# Proves T356 at the resolver: two spellings of one repository (D118).
subtest 'two remotes for one repository' => sub {
	plan tests => 3;

	my %remotes = (https => 'https://github.com/team/bosh.git',
	               ssh   => 'git@github.com:team/bosh.git');

	is((resolved(repository => 'team/bosh', remotes => \%remotes,
			upstream => 'ssh'))[0],
		'ssh', "control's upstream chooses between them");

	my (undef, $error) = resolved(repository => 'team/bosh', remotes => \%remotes);
	like($error, qr{\bhttps\b.*\bssh\b}s, 'with no upstream, both are named');
	like($error, qr{set-upstream-to}, 'and the way to choose is given');
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

subtest 'a pipeline outside a git checkout is refused by name' => sub {
	plan tests => 3;

	# A directory under no git control at all, built beside the harness
	# because both harness copies are checkouts.  The refusal has to say
	# what a pipeline needs a repository for, since an operator who has
	# just turned one on is not asking about paths.
	my $dir = workdir() . '/no-checkout-' . int(rand(1_000_000));
	mkdir_or_fail($dir);
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", join("\n",
		'---', 'deployment_type: bosh', 'version: "3"',
		'creator_version: 3.2.0',
		'pipeline:', '  enabled: true',
		'  source_control:',
		'    control_branch: trunk',
		'    repository: team/bosh', ''));

	my $top = Genesis::Top->new($dir, no_vault => 1);

	# The refusal is wrapped for the terminal before it is raised, so
	# reading the message back would rest on where a line break landed.
	# The arguments are read as the refusal composed them instead.
	my @raised;
	# once as well as redefine, because Genesis::Top is required at run time
	# here and the glob is therefore new at compile time.
	no warnings qw/once redefine/;
	local *Genesis::Top::bail = sub {push @raised, [@_]; die "refused\n"};

	my $sc = eval { $top->_source_control };

	is($sc, undef, 'the resolution does not answer');
	ok(scalar(grep {!ref($_) && /is not a git checkout/} @{$raised[0] || []}),
		'the refusal names the repository as the thing that is missing')
		or diag('the refusal was raised with: '
			. join(', ', map {ref($_) ? ref($_) : $_} @{$raised[0] || []}));
	is((ref($raised[0][0]) eq 'HASH' ? $raised[0][0]{exitcode} : undef), CONFIG,
		'and it exits CONFIG, the misconfigured environment');
};

done_testing;
