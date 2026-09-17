#!perl
#
# The compiler asks two questions about a repository's .genesis/config,
# and they have to be about the same section.  Genesis::CI::Compiler's
# can_compile_from_genesis_config decides whether the configuration is
# inline, and Genesis::CI::Compiler::Parser::parse then reads it.  D18
# renamed that section from ci to pipeline and left no alias behind, so
# both reads name pipeline and a section still spelled ci is nothing the
# compiler will look at.
#
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use Test::More;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';
$ENV{NOCOLOR}         = 1;

use_ok 'Genesis::CI::Compiler';
use_ok 'Genesis::CI::Compiler::Parser';

# Stands in for Genesis::Config and Genesis::Top: the parser asks the
# config whether a key is there and then for its value, and asks the top
# for the path it would name as the source and for the deployment type
# the pipeline's name falls back to.
{
	package MockConfig;
	sub new { my ($class, %data) = @_; return bless {data => \%data}, $class }
	sub has { my ($self, $k) = @_; return exists $self->{data}{$k} }
	sub get { my ($self, $k) = @_; return $self->{data}{$k} }
}
{
	package MockTop;
	sub new {
		my ($class, %opts) = @_;
		return bless {config => $opts{config}, base => $opts{base} || '/fake',
			type => $opts{type} || 'bosh'}, $class;
	}
	sub config { $_[0]->{config} }
	sub type   { $_[0]->{type} }
	sub path {
		my ($self, $rel) = @_;
		return defined $rel ? "$self->{base}/$rel" : $self->{base};
	}
}

# The shape D27 leaves behind: the provider and the integrations sit
# under the section, and the topology comes from the environment files
# rather than from a workflows block.
my $SECTION = {
	enabled  => 1,
	provider => {type => 'concourse'},
	vault    => {url  => 'https://vault.example.com'},
	source_control => {control_branch => 'trunk'},
};

subtest 'a pipeline section is the one the parser reads' => sub {
	plan tests => 5;

	my $top = MockTop->new(config => MockConfig->new(pipeline => $SECTION));

	ok(Genesis::CI::Compiler->can_compile_from_genesis_config($top),
		'the gate says this repository configures its pipeline inline');

	my $parsed = Genesis::CI::Compiler::Parser->new(top => $top)->parse;
	is($parsed->{_source_format}, 'genesis-config',
		'and the parser read the section rather than looking for a file');
	is($parsed->{_source_path}, '/fake/.genesis/config',
		'naming .genesis/config as where the configuration came from');
	is($parsed->{integrations}{vault}{url}, 'https://vault.example.com',
		"and the section's own integrations came through");

	# The section names no pipeline of its own, so the name falls back to
	# the deployment type, which is what the schema says pipeline.name
	# does and what the AST every command reads the name off carries.
	is($parsed->{pipeline}{metadata}{name}, 'bosh',
		'and the pipeline is named after the deployment type');
};

subtest 'a pipeline that names itself keeps the name it wrote' => sub {
	plan tests => 1;

	# The row above answers for a section that names no pipeline of its
	# own.  A section that does name one keeps that name, which is the
	# half of the rule a fallback row alone cannot tell apart: both
	# would pass against a parse that read the key and against one that
	# ignored it, whenever the name and the deployment type agree.
	my $top = MockTop->new(config => MockConfig->new(
		pipeline => {%$SECTION, name => 'west-deployments'}));

	my $parsed = Genesis::CI::Compiler::Parser->new(top => $top)->parse;
	is($parsed->{pipeline}{metadata}{name}, 'west-deployments',
		'the name the section wrote is the name the AST carries');
};

subtest 'a section still spelled ci is not read' => sub {
	plan tests => 3;

	my $top = MockTop->new(config => MockConfig->new(ci => $SECTION));

	ok(!Genesis::CI::Compiler->can_compile_from_genesis_config($top),
		'the gate does not take the old spelling for an inline pipeline');

	# There is no configuration directory and no file either, so the
	# parser has nothing left to fall back to and says so.
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	my $parsed = eval {
		Genesis::CI::Compiler::Parser->new(top => $top)->parse;
	};
	is($parsed, undef, 'the parser finds nothing to read');
	like($@, qr/pipeline:/,
		'and the refusal names the section the repository is meant to carry');
};

done_testing;
