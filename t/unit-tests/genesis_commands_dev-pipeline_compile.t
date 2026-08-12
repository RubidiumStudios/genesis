#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use Test::More;
use Test::Deep;
use Test::Exception;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';
$ENV{NOCOLOR}         = 1;

use_ok 'Genesis::Commands::Dev';
use_ok 'Genesis::CI::Compiler::AST';

my $FIXTURE = 't/fixtures/ci/lmelt-topology.json';
my $MGMT    = 'lmelt-vsphere-canwest-1-mgmt';
my $LAB     = 'lmelt-vsphere-canwest-1-lab';

# ======================================================================
# load_ast_file
# ======================================================================

subtest 'load_ast_file rebuilds an AST from a debug-dir source dump' => sub {
	plan tests => 6;

	my $ast = Genesis::Commands::Dev::load_ast_file($FIXTURE);
	isa_ok $ast, 'Genesis::CI::Compiler::AST';
	is $ast->metadata->{name}, 'bosh', 'metadata survives the round-trip';
	is $ast->branches->{control}, 'control', 'control branch survives';
	is $ast->integrations->{source_control}{root}, 'bosh',
		'source_control root survives';
	ok exists $ast->workflows->{default}, 'default workflow present';
	is_deeply [sort keys %{$ast->workflows->{default}{graph}{nodes}}],
		[$LAB, $MGMT], 'both env nodes survive';
};

subtest 'load_ast_file rejects a missing file' => sub {
	plan tests => 1;

	throws_ok { Genesis::Commands::Dev::load_ast_file('t/fixtures/ci/nope.json') }
		qr/no such file|cannot read/i,
		'missing fixture is reported rather than silently empty';
};

# ======================================================================
# stage_data
# ======================================================================

subtest 'stage_data ast returns the source representation' => sub {
	plan tests => 3;

	my $ast  = Genesis::Commands::Dev::load_ast_file($FIXTURE);
	my $data = Genesis::Commands::Dev::stage_data($ast, 'ast');

	is ref($data), 'HASH', 'ast stage yields a hash';
	ok exists $data->{workflows},   'ast stage exposes workflows';
	ok exists $data->{integrations},'ast stage exposes integrations';
};

subtest 'stage_data descriptor renders resources and jobs' => sub {
	plan tests => 4;

	my $ast  = Genesis::Commands::Dev::load_ast_file($FIXTURE);
	my $data = Genesis::Commands::Dev::stage_data($ast, 'descriptor');

	is ref($data),              'HASH',  'descriptor stage yields a hash';
	is ref($data->{resources}), 'ARRAY', 'descriptor emits resources';
	is ref($data->{jobs}),      'ARRAY', 'descriptor emits jobs';
	ok scalar(@{$data->{jobs}}) >= 1,    'descriptor emits at least one job';
};

subtest 'stage_data rejects an unknown stage' => sub {
	plan tests => 1;

	my $ast = Genesis::Commands::Dev::load_ast_file($FIXTURE);
	throws_ok { Genesis::Commands::Dev::stage_data($ast, 'bogus') }
		qr/unknown stage/i,
		'unknown stage names are rejected, not silently empty';
};

# ======================================================================
# render
# ======================================================================

subtest 'render emits parseable yaml and json' => sub {
	plan tests => 4;

	my $data = { jobs => [{ name => 'lab-bosh' }], resources => [] };

	my $yaml = Genesis::Commands::Dev::render($data, 'yaml');
	like $yaml, qr/jobs:/,     'yaml output carries the jobs key';
	like $yaml, qr/lab-bosh/,  'yaml output carries the job name';

	my $json = Genesis::Commands::Dev::render($data, 'json');
	my $back = JSON::PP->new->decode($json);
	is_deeply $back, $data, 'json output round-trips';
	like $json, qr/\n/, 'json output is pretty-printed for diffing';
};

subtest 'render rejects an unknown format' => sub {
	plan tests => 1;

	throws_ok { Genesis::Commands::Dev::render({}, 'toml') }
		qr/unknown format/i,
		'unknown formats are rejected';
};

done_testing;
