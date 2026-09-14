#!perl
# Proves T25 and T41: pipeline.name is the provider's label alone, is not
# checked as a git ref component and composes no branch, and the two keys
# that change how a deployment progresses are repository-wide and refused
# per environment.
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

# Every row here leaves the provider at manual, so the shuttle, the vault,
# and the locker are not required beside it, and a row adds the keys it is
# about rather than a whole configuration of its own.
#
# The repository is named rather than derived because copy A is cloned from
# a bare repository at a filesystem path, whose URL carries no GitHub
# owner/repo pair, and the derivation's own refusal belongs to the
# source-control rows rather than to these.
sub manual_config {
	my (@lines) = @_;
	return join("\n", 'pipeline:', '  enabled: true',
		'  source_control:',
		'    repository: genesis/bosh-deployments',
		map {"  $_"} @lines);
}

subtest "the label is the provider's alone" => sub {
	plan tests => 4;

	# A value that is a fine Concourse pipeline name and a hopeless git
	# ref component, so a ref check would have refused it.
	my $top = load_with($h, manual_config("name: 'bosh..lab.lock'"));
	is $top->config->get('pipeline.name'), 'bosh..lab.lock',
		'the label keeps whatever character set its provider allows';

	my $schema = $top->_repo_config_schema->{pipeline}{schema}{name};
	is $schema->{type}, 'string',
		'it is declared as a free string';

	# A guard rather than a red row: nothing under lib/ composes a branch
	# out of the label today, so this starts green and stays green only
	# while nobody starts.  Several files read the key for what it is, the
	# provider's own label, so the sweep reads each line that names it
	# together with the two lines below it rather than the whole file,
	# which would flag every one of those legitimate reads.
	#
	# Both spellings of the read open the window, because the label is
	# reached through the dotted key in some files and walked out of the
	# parsed configuration in others, and a branch built at either one is
	# the thing D66 rules out.  A branch is named by the word, by a ref
	# path, by the two porcelain forms that create one without saying
	# branch at all, and by the HEAD refspec a push composes.  The two
	# porcelain forms allow punctuation between the verb and its flag,
	# because git is called here as a list of arguments far more often
	# than as a command line.
	my @pms = sort split /\n/, qx{find lib -name '*.pm'};
	cmp_ok scalar(@pms), '>', 0,
		'the sweep has files to read, so a green row means something';

	my @offenders;
	for my $pm (@pms) {
		open my $fh, '<', $pm or next;
		my @lines = <$fh>;
		close $fh;
		for my $i (0 .. $#lines) {
			next unless $lines[$i] =~ m{pipeline\.name}
			         || $lines[$i] =~ m{\{pipeline\}\s*(?:->)?\s*\{name\}};
			my $last = $i + 2 > $#lines ? $#lines : $i + 2;
			push @offenders, sprintf('%s:%d', $pm, $i + 1)
				if join('', @lines[$i .. $last]) =~
					m{branch|refs/heads|checkout\W+-b\b|switch\W+-c\b|HEAD:};
		}
	}
	is_deeply \@offenders, [], 'and no branch name is composed from it'
		or diag(join("\n", map {"  $_"} @offenders));
};

subtest 'the two progression keys are repository-wide' => sub {
	plan tests => 7;

	my $top = load_with($h, manual_config());
	is $top->config->get('pipeline.recreate_on_deploy'), 'never',
		'recreate_on_deploy defaults to never';
	for my $value (qw/never redeploy-only always/) {
		lives_ok {load_with($h, manual_config("recreate_on_deploy: $value"))}
			"$value validates";
	}

	# The three rows above would pass against a free string, so one row
	# holds the key to its three values.
	throws_ok {load_with($h, manual_config('recreate_on_deploy: sometimes'))}
		qr/pipeline\.recreate_on_deploy:\s+unknown\s+value:\s+sometimes/s,
		'a fourth value is refused by name';

	write_env_file($h, 'qa', pipeline => {recreate_on_deploy => 'always'});
	throws_ok {load_with($h, manual_config())}
		qr/genesis\.pipeline\.recreate_on_deploy: unknown configuration key/,
		'and it is refused per environment';

	write_env_file($h, 'qa', pipeline => {group_commits => 0});
	throws_ok {load_with($h, manual_config())}
		qr/genesis\.pipeline\.group_commits: unknown configuration key/,
		'group_commits stays at pipeline.provider and is refused per environment';
};

done_testing;
