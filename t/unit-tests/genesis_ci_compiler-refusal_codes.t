#!perl
# Every refusal the compiler and its parser raise over something an
# operator wrote exits at the configuration code, so a pipeline job or a
# shell script reading the code can tell a repository it has to fix from
# a system that failed underneath it.  The exits are named rather than
# numbered, and the names are what these rows assert.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
# Test::Exit installs the hook that makes an exit catchable in a BEGIN
# block, and the exit it has to catch is the one Genesis::bail spends, so
# it comes before anything that compiles Genesis.
use Test::Exit;
use helper;
use Test::More;
use Test::Output;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Exit qw/CONFIG/;
provide_rc();
use_ok 'Genesis::CI::Compiler';
use_ok 'Genesis::CI::Compiler::Parser';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Runs the refusal with its output swallowed and answers the code it spent.
sub refusal_code {
	my ($run) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my $code;
	output_from {$code = exit_code {$run->()}};
	return $code;
}

subtest 'the parser refuses what it cannot find at the configuration code' => sub {
	plan tests => 3;

	my $missing = tempdir(CLEANUP => 1) . '/nowhere';

	is refusal_code(sub {
		Genesis::CI::Compiler::Parser->new(ci_dir => $missing)->parse
	}), CONFIG, 'a named configuration directory that is not there';

	is refusal_code(sub {
		Genesis::CI::Compiler::Parser->new(file => "$missing/ci.yml")->parse
	}), CONFIG, 'a named configuration file that is not there';

	is refusal_code(sub {
		Genesis::CI::Compiler::Parser->new->parse
	}), CONFIG, 'and nothing named at all';
};

subtest 'a configuration directory missing a required file is refused' => sub {
	plan tests => 2;

	my $dir = tempdir(CLEANUP => 1);
	mkdir "$dir/ci";

	is refusal_code(sub {
		Genesis::CI::Compiler::Parser->new(ci_dir => "$dir/ci")->parse
	}), CONFIG, 'targets.yml is the first one missed';

	mkfile_or_fail("$dir/ci/targets.yml", "---\nsandbox: {}\n");
	is refusal_code(sub {
		Genesis::CI::Compiler::Parser->new(ci_dir => "$dir/ci")->parse
	}), CONFIG, 'and integrations.yml the second';
};

subtest 'a legacy file the parser cannot make sense of is refused' => sub {
	plan tests => 4;

	my $dir = tempdir(CLEANUP => 1);
	my $parser = Genesis::CI::Compiler::Parser->new;

	mkfile_or_fail("$dir/no-key.yml", "---\nsomething: else\n");
	is refusal_code(sub {$parser->_parse_legacy_file("$dir/no-key.yml")}),
		CONFIG, 'a file with no top-level pipeline key';

	mkfile_or_fail("$dir/not-a-map.yml", "---\npipeline: a string\n");
	is refusal_code(sub {$parser->_parse_legacy_file("$dir/not-a-map.yml")}),
		CONFIG, 'a pipeline key holding something other than a map';

	is refusal_code(sub {
		$parser->_normalize_legacy_layouts({layout => 'a', layouts => {}})
	}), CONFIG, 'both layout spellings at once';

	is refusal_code(sub {$parser->_normalize_legacy_layouts({})}),
		CONFIG, 'and neither of them';
};

subtest 'the compiler refuses a configuration section of the wrong shape' => sub {
	plan tests => 1;

	is refusal_code(sub {
		Genesis::CI::Compiler->validate_config_section('a string')
	}), CONFIG, 'a pipeline section that is not a hash';
};

subtest 'a configuration the validator rejects is refused' => sub {
	plan tests => 1;

	# The validator's own errors are the operator's to fix, and this is the
	# refusal they meet every time it finds anything.
	my $dir = tempdir(CLEANUP => 1);
	mkdir "$dir/ci";
	mkfile_or_fail("$dir/ci/pipeline.yml", "---\nname: broken\n");
	mkfile_or_fail("$dir/ci/targets.yml", "---\nsandbox: {}\n");
	mkfile_or_fail("$dir/ci/integrations.yml", "---\nvault: {}\n");

	is refusal_code(sub {
		Genesis::CI::Compiler->new->compile(
			provider => 'concourse', ci_dir => "$dir/ci")
	}), CONFIG, 'a configuration the validator finds errors in';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
