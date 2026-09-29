#!perl
# Proves T353: configuration load validates what a deploy would merge.  The
# merged read is Genesis::Env's own unevaluated_environment manifest, which
# is spruce's merge with value operators left alone, so spruce's merge
# operators apply across the hierarchy exactly as they do at deploy time.
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
use Genesis::Top;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# A site file and a leaf beneath it, written as YAML text so the operators
# reach the files exactly as an operator would write them.  The keys are ones
# no capability gates, because the repository is on the manual provider and
# configuration load walks the site file as well as the leaf.
my $h = make_harness(envs => [], pipeline => 1, vault => 0);
commit_on_control($h, message => 'a site file and a leaf', files => {
	'us.yml' => <<'EOF',
---
genesis:
  pipeline:
    track_dependencies: [ops/dependency.yml]
    track_additional_files: [ops/a.yml, ops/b.yml]
EOF
	'us-east.yml' => <<'EOF',
---
genesis:
  env: us-east
  pipeline:
    track_dependencies: (( prune ))
    track_additional_files:
    - (( append ))
    - ops/c.yml
EOF
});
my $top = Genesis::Top->new($h->a, no_vault => 1);

subtest "spruce's merge operators apply across the hierarchy" => sub {
	plan tests => 3;

	my $pipeline = $top->_merged_env_params('us-east')->{genesis}{pipeline};
	is_deeply($pipeline->{track_additional_files},
		['ops/a.yml', 'ops/b.yml', 'ops/c.yml'],
		'(( append )) extends the site file\'s list with the leaf\'s');
	ok(!exists $pipeline->{track_dependencies},
		'(( prune )) takes away a key the site file set');
	is_deeply($top->_merged_env_params('us')->{genesis}{pipeline}{track_dependencies},
		['ops/dependency.yml'], 'while the site file read on its own still carries it');
};

subtest 'value operators are left unevaluated' => sub {
	plan tests => 1;

	commit_on_control($h, message => 'a grab in the leaf', files => {
		'us-west.yml' => "---\ngenesis:\n  env: us-west\n  bosh_env: (( grab meta.director ))\n",
	});
	my $fresh = Genesis::Top->new($h->a, no_vault => 1);
	is($fresh->_merged_env_params('us-west')->{genesis}{bosh_env},
		'(( grab meta.director ))',
		'a grab comes back as written, since nothing it could reach is read');
};

subtest 'an environment is merged once and the answer kept' => sub {
	plan tests => 1;

	my $first = $top->_merged_env_params('us-east');
	is($top->_merged_env_params('us-east'), $first,
		"the second read answers with the first read's hash");
};

done_testing;
