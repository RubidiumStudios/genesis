#!perl
# Proves T497: how a secret reference written in .genesis/config is spelled
# in the pipeline (D167).  An operator writes <path>:<key>, which becomes
# Concourse's ((path.key)); a value already in Concourse's own form, which
# is how a value passed straight to Concourse is written, goes through as
# it was given.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use_ok 'Genesis::CI::ProviderCompiler';
use_ok 'Genesis::Top';

sub spelled { Genesis::CI::ProviderCompiler->secret_ref($_[0]) }

subtest 'a <path>:<key> reference becomes ((path.key))' => sub {
	is(spelled('git:private_key'), '((git.private_key))', 'the colon before the key becomes a dot');
	is(spelled('ci/git/deploy:private_key'), '((ci/git/deploy.private_key))', 'whatever the depth of the path');
	is(spelled('webhook-token'), '((webhook-token))', 'a name with no key is wrapped as it is');
	is(spelled({secret_ref => 'git:private_key'}), '((git.private_key))', 'a wrapped reference is unwrapped first');
	is(spelled(undef), undef, 'and no reference stays none');
};

subtest 'a reference already written as ((...)) is passed through as given' => sub {
	for my $given (
		'((git.private_key))',
		'((ci/git/deploy.private_key))',
		'(( git.private_key ))',
		'((vault:ci/git.private_key))',
		'(("ci/git.v2".private_key))',
	) {
		is(spelled($given), $given, "$given is not wrapped again");
		is(spelled({secret_ref => $given}), $given, '... nor when it arrives wrapped');
	}
};

subtest 'a credential block takes either form for a component' => sub {
	my %cases = (
		'the secret named by path'       => [{type => 'ssh', path => 'git'}, {private_key => '((git.private_key))'}],
		'a component as <path>:<key>'    => [{type => 'ssh', path => 'git', private_key => 'ci/deploy:key'}, {private_key => '((ci/deploy.key))'}],
		'a component as ((path.key))'    => [{type => 'ssh', private_key => '((ci/deploy.key))'}, {private_key => '((ci/deploy.key))'}],
		'one component of each form'     => [
			{type => 'https', username => 'ci/git:user', password => '((ci/git.token))'},
			{username => '((ci/git.user))', password => '((ci/git.token))'},
		],
	);
	for my $case (sort keys %cases) {
		my ($auth, $want) = @{$cases{$case}};
		my $components = Genesis::Top::credential_components(source_control => $auth);
		is_deeply({map {($_ => spelled($components->{$_}))} sort keys %$components}, $want, $case);
	}
};

done_testing;
