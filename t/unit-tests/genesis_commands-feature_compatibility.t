#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use_ok 'Genesis::Commands::Env';
use_ok 'Genesis::Commands::Info';
use_ok 'Genesis::Commands::Core';

# Make non-public helpers callable.
*format_deploy_tail   = \&Genesis::Commands::Env::_format_deploy_feature_opt_in;
*format_info_line     = \&Genesis::Commands::Info::_format_feature_compatibility_line;
*format_version_tail  = \&Genesis::Commands::Core::_format_feature_level_tail;
# _detect_feature_compatibility is exercised by the integration test
# because it constructs a real Genesis::Top from cwd.

# ---------------------------------------------------------------------------
# Genesis::Commands::Env::_format_deploy_feature_opt_in
# ---------------------------------------------------------------------------
subtest 'deploy header tail - empty when no floor declared' => sub {
	plan tests => 1;
	my $env = Mock->new(
		effective_minimum_version        => '0.0.0',
		effective_minimum_version_source => undef,
	);
	is(format_deploy_tail($env), '', 'no tail when floor is 0.0.0 sentinel');
};

subtest 'deploy header tail - empty when level is undef' => sub {
	plan tests => 1;
	my $env = Mock->new(
		effective_minimum_version        => undef,
		effective_minimum_version_source => undef,
	);
	is(format_deploy_tail($env), '', 'no tail when level is undef');
};

subtest 'deploy header tail - formatted when floor declared' => sub {
	plan tests => 1;
	my $env = Mock->new(
		effective_minimum_version        => '3.1.0',
		effective_minimum_version_source => 'environment',
	);
	is(
		format_deploy_tail($env),
		' (feature opt-in: #c{v3.1.0} from #c{environment})',
		'tail contains coloured version and source'
	);
};

subtest 'deploy header tail - repository source' => sub {
	plan tests => 1;
	my $env = Mock->new(
		effective_minimum_version        => '3.2.0',
		effective_minimum_version_source => 'repository',
	);
	is(
		format_deploy_tail($env),
		' (feature opt-in: #c{v3.2.0} from #c{repository})',
		'source label reflects repository when repo > env'
	);
};

# ---------------------------------------------------------------------------
# Genesis::Commands::Info::_format_feature_compatibility_line
# ---------------------------------------------------------------------------
subtest 'info opt-in line - empty when no field' => sub {
	plan tests => 1;
	my $d = Mock->new(
		lookup => sub {
			my ($self, $key) = @_;
			return undef if $key eq 'feature_compatibility';
			return undef;
		},
	);
	is(format_info_line($d), '', 'no line when deployment lacks the field');
};

subtest 'info opt-in line - rendered with source' => sub {
	plan tests => 1;
	my $d = Mock->new(
		lookup => sub {
			my ($self, $key) = @_;
			return '3.1.0'      if $key eq 'feature_compatibility';
			return 'environment' if $key eq 'feature_compatibility_source';
			return undef;
		},
	);
	is(
		format_info_line($d),
		"[[  #I{feature opt-in}>> #C{v3.1.0} (from environment)\n",
		'line shows level + source when both present'
	);
};

subtest 'info opt-in line - rendered without source' => sub {
	plan tests => 1;
	# Older audit records may lack the source field.
	my $d = Mock->new(
		lookup => sub {
			my ($self, $key) = @_;
			return '3.0.0' if $key eq 'feature_compatibility';
			return undef;
		},
	);
	is(
		format_info_line($d),
		"[[  #I{feature opt-in}>> #C{v3.0.0}\n",
		'line shows level only when source missing'
	);
};

# ---------------------------------------------------------------------------
# Genesis::Commands::Core::_format_feature_level_tail
# ---------------------------------------------------------------------------
subtest 'version tail - empty when level undef' => sub {
	plan tests => 1;
	is(format_version_tail(undef, undef), '', 'no tail when level undef');
};

subtest 'version tail - formatted when level present' => sub {
	plan tests => 2;
	is(
		format_version_tail('3.1.0', 'repository'),
		' (feature level: v3.1.0 [repository])',
		'tail formats level and source'
	);
	is(
		format_version_tail('3.2.0-rc.1', 'environment'),
		' (feature level: v3.2.0-rc.1 [environment])',
		'tail honours rc suffix and env source'
	);
};

done_testing;
