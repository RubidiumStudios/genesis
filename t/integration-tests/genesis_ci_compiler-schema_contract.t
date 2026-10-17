#!perl
# Proves T380: the compiler reads nothing the schema does not declare (D27,
# noted 2026-10-16).  The pipeline section the compiler is handed is wrapped
# so every key path it reads is recorded, a key it asks after and finds absent
# included, and each recorded path must be one the repository schema declares
# under pipeline.  A key the compiler reads and the load never checks is how a
# configuration the load accepted failed the compile with a Perl error.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

{
	# A hash that records every key read from it, and hands back its nested
	# hashes wrapped the same way, each under its own dotted path.
	package Recorder;
	sub wrap {
		my ($data, $path, $log) = @_;
		tie my %h, 'Recorder', $data, $path, $log;
		return \%h;
	}
	sub TIEHASH  {my ($c, $d, $p, $l) = @_; bless {d => $d, p => $p, l => $l}, $c}
	sub _path    {join('.', grep {length} $_[0]{p}, $_[1])}
	sub FETCH    {
		my ($s, $k) = @_;
		$s->{l}{$s->_path($k)}++;
		my $v = $s->{d}{$k};
		return ref($v) eq 'HASH' ? wrap($v, $s->_path($k), $s->{l}) : $v;
	}
	sub EXISTS   {my ($s, $k) = @_; $s->{l}{$s->_path($k)}++; exists $s->{d}{$k}}
	sub FIRSTKEY {my ($s) = @_; $s->{k} = [sort keys %{$s->{d}}]; shift @{$s->{k}}}
	sub NEXTKEY  {shift @{$_[0]{k}}}
	sub STORE    {$_[0]{d}{$_[1]} = $_[2]}
	sub DELETE   {delete $_[0]{d}{$_[1]}}
	sub CLEAR    {%{$_[0]{d}} = ()}
	sub SCALAR   {scalar %{$_[0]{d}}}
}

# Every path the schema declares under pipeline.  A block whose shape is not
# declared key by key, being free-form or chosen by a discriminator, declares
# everything beneath it.
sub declared {
	my ($schema, $path, $out) = @_;
	for my $key (keys %$schema) {
		my $spec = $schema->{$key};
		my $here = length $path ? "$path.$key" : $key;
		my $type = ref($spec) eq 'HASH' ? ($spec->{type} // '') : '';
		$out->{$here} = 1;
		if ($type =~ /^(?:any|custom_struct)$/) {
			$out->{"$here.*"} = 1;
		} elsif (ref($spec) eq 'HASH' && ref($spec->{schema}) eq 'HASH') {
			declared($spec->{schema}, $here, $out);
		}
	}
	return $out;
}

sub is_declared {
	my ($declared, $path) = @_;
	return 1 if $declared->{$path};
	my @parts = split /\./, $path;
	while (@parts > 1) {
		pop @parts;
		return 1 if $declared->{join('.', @parts) . '.*'};
	}
	return 0;
}

subtest 'every key the compiler reads is one the schema declares' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['lab', 'qa'], fanned => 'lab',
		provider => 'concourse', vault => 0);
	my $top = load_with($h, automated_config('concourse',
		'url: https://ci.example.com', 'team: main'));

	my %log;
	my $wrapped = Recorder::wrap($top->pipeline_section, '', \%log);
	my $result  = do {
		no warnings 'redefine';
		local *Genesis::Top::pipeline_section = sub {$wrapped};
		require Genesis::CI::Compiler;
		Genesis::CI::Compiler->new(top => $top)->compile(provider => 'concourse');
	};
	ok(scalar(%{$result->{output} || {}}), 'the pipeline compiled');

	my $declared   = declared($top->_repo_config_schema->{pipeline}{schema}, '', {});
	my @undeclared = sort grep {!is_declared($declared, $_)} keys %log;
	is_deeply(\@undeclared, [], 'and it read no key the schema leaves undeclared')
		or diag(join("\n", map {"  pipeline.$_"} @undeclared));
};

done_testing;
