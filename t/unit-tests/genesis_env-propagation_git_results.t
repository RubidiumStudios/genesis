#!/usr/bin/env perl
use strict;
use warnings;

# propagation_diff and last_propagated_sha read git's output and exit code
# from run(), but asked for passfail, which makes run() return only a
# boolean.  propagation_diff took that boolean for git's output, so any
# successful diff, even an empty one, named a file called "1", and
# last_propagated_sha never found a marker and always returned undef.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Cwd qw(getcwd);

use Genesis;
use Genesis::Env;

my $repo = workdir('propagation-git-results');
sub git { system('git', '-C', $repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', @_) == 0
	or die "git @_ failed\n" }

git('init', '-q', '-b', 'control');
put_file("$repo/env.yml", "a: 1\n");
put_file("$repo/other.yml", "b: 1\n");
git('add', '.');
git('commit', '-q', '-m', 'Start control');
git('checkout', '-q', '-b', 'an-env');
put_file("$repo/other.yml", "b: 0\n");
git('commit', '-q', '-am', 'Propagate control@0123abcd to an-env');
git('checkout', '-q', 'control');
put_file("$repo/env.yml", "a: 2\n");
put_file("$repo/other.yml", "b: 2\n");
git('commit', '-q', '-am', 'Change control');

my $env = bless({name => 'an-env'}, 'Genesis::Env');
no warnings qw(redefine once);
local *Genesis::Env::propagation_files = sub { ('env.yml') };
use warnings qw(redefine once);

my $cwd = getcwd;
chdir $repo or die "chdir $repo: $!";

subtest 'propagation_diff names the files git reports' => sub {
	is_deeply([$env->propagation_diff('control')], ['env.yml'],
		'a changed file in the pathspec is returned');
	is_deeply([$env->propagation_diff('an-env')], [],
		'a diff with no changes returns nothing');
	is_deeply([$env->propagation_diff('no-such-commit')], [],
		'a failed diff returns nothing');
};

subtest 'last_propagated_sha reads the marker from the branch log' => sub {
	is($env->last_propagated_sha, '0123abcd', 'the control SHA in the last propagation commit');
};

chdir $cwd;
done_testing;
