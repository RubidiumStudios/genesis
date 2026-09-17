#!perl
# Every package under lib derives its own path, the compiler family and
# the provider family each keep to their own subject, and the compiler
# base loads the concrete by the name it declares.  These are the three
# things D108's rename settles.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;

use File::Find;

# The registry is loaded here rather than left to whichever module pulls
# it in first, so that the row below asking what an entry holds is about
# the entry and not about the load order of the rows above it.
use Genesis::CI::ProviderRegistry;

$ENV{NOCOLOR} = 1;

# The compiler family, which is the base and everything beneath it.  Two
# roots rather than one, because the base sits beside the directory its
# concretes live in rather than inside it, and a scan of the directory
# alone would say nothing about the base at all.
my @COMPILER_FAMILY = (
	'lib/Genesis/CI/ProviderCompiler.pm',
	'lib/Genesis/CI/ProviderCompiler',
);

# Every sweep below is satisfied by an empty answer, and a root that is
# not on disk answers empty, so a family that moved out from under this
# file would read as a clean sweep rather than as a broken one.  The
# roots are asserted once, here, so that never happens quietly.
#
# A missing root stops the file rather than failing one row, because
# every row after it would pass on an empty sweep and a reader would have
# six green rows and one red one to explain.  The one red one is the
# whole story, so it is the only one told.  There is no row here saying
# the check ran: a bail is what this says when it has something to say,
# and a passing row that asserts nothing is a receipt.
{
	my @missing = grep {!-e} @COMPILER_FAMILY;
	BAIL_OUT(sprintf('the compiler family has moved: %s is not on disk',
		join(', ', @missing))) if @missing;
}

# An assertion helper, beside the test that uses it.  It reads each file
# whole and reports the subs named, because a sub's name and its body
# are what these rows are about and neither is spread over a boundary a
# line-at-a-time scan would have to carry.
sub subs_named_in {
	my ($where, @names) = @_;
	my $names = join('|', @names);

	# A root that is not there contributes nothing rather than dying, so
	# the rows below fail on what they assert rather than on a stat.  The
	# row above this sub is what makes sure that never happens silently.
	my @roots = grep {-e} (ref($where) eq 'ARRAY' ? @$where : $where);
	return () unless @roots;

	my @files;
	find(sub {push @files, $File::Find::name if -f && /\.pm$/}, @roots);

	my @found;
	for my $file (sort @files) {
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		while (my $line = <$fh>) {
			next if $line =~ /^\s*#/;
			push @found, "$file:$.: $1" if $line =~ /^\s*sub\s+($names)\b/;
		}
		close $fh;
	}
	return @found;
}

# The same sweep reduced to the files alone, each named once.  A row
# whose subject is which files define a sub says so with a path, because
# a line number is a second fact the row never asked about and one that
# any edit above the sub moves.
sub files_naming_subs {
	my ($where, @names) = @_;
	my %seen;
	return grep {!$seen{$_}++}
		map  {(split /:/, $_)[0]} subs_named_in($where, @names);
}

subtest 'every package under lib derives its own path' => sub {
	plan tests => 2;

	# Perl's two require forms disagree about this.  The bareword form
	# derives a path from the package name; the string form loads a
	# literal path and never looks at the package the file declares.  A
	# module the string form alone can reach is invisible to every
	# convention-based tool in the repository, and the registry carried
	# a file key to compensate.
	my @files;
	find(sub {push @files, $File::Find::name if -f && /\.pm$/}, 'lib');

	my @askew;
	for my $file (sort @files) {
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		my ($package) = map {/^package\s+([\w:]+)/ ? $1 : ()} <$fh>;
		close $fh;
		next unless $package;

		(my $derived = $package) =~ s{::}{/}g;
		push @askew, "$file declares $package"
			unless $file eq "lib/$derived.pm";
	}
	is_deeply(\@askew, [],
		'no module declares a package its path does not derive')
		or diag(join("\n", map {"  $_"} @askew));

	# The bareword form is the one that failed, so the row uses it.
	lives_ok {require Genesis::CI::ProviderCompiler::Concourse}
		'and the Concourse compiler loads by name rather than by path';
};

subtest 'the registry derives a path rather than carrying one' => sub {
	plan tests => 3;

	# The file key existed because Genesis::CI::Concourse sat at a path
	# its package could not derive.  With that package retired the path
	# follows the class everywhere, so an entry says the class and the
	# registry works the path out.
	my $info = Genesis::CI::ProviderRegistry->provider_info('concourse');
	is $info->{cli_file}, 'Genesis/CI/Provider/Concourse.pm',
		'the CLI path is derived from the CLI class';
	is $info->{file}, 'Genesis/CI/ProviderCompiler/Concourse.pm',
		'and the compiler path is derived from the compiler class';

	# A registration that names a path the class does not derive is the
	# mismatch coming back, so it is refused rather than compensated for.
	throws_ok {
		Genesis::CI::ProviderRegistry->register_provider('askew', {
			cli_class => 'Genesis::CI::Provider::Manual',
			cli_file  => 'Genesis/CI/Provider/Elsewhere.pm',
		})
	} qr/cli_file.*does not match.*cli_class/s,
		'a path that disagrees with its class is refused';
};

subtest 'no compiler module answers for which providers exist' => sub {
	plan tests => 2;

	my @found = subs_named_in(\@COMPILER_FAMILY,
		qw/known_providers provider_info automated_providers register_provider/);
	is_deeply(\@found, [],
		'the registry is not in the compiler namespace')
		or diag(join("\n", map {"  $_"} @found));

	ok !-e 'lib/Genesis/CI/Compiler/PipelineProvider.pm'
		&& !-d 'lib/Genesis/CI/Compiler/Providers',
		'and the two modules the rename replaces are gone with their directory';
};

subtest 'the capability contract sits with the class that declares one' => sub {
	plan tests => 2;

	use_ok 'Genesis::CI::Provider';
	ok Genesis::CI::Provider->can('declared_capabilities')
		&& Genesis::CI::Provider->can('capability_gates'),
		'the contract answers on the provider base';
};

subtest 'the concrete compiler takes the base constructor' => sub {
	plan tests => 1;

	# Its own new blessed ast, top, and provider_opts and dropped
	# everything else, so a provider handed in would have vanished and
	# T343 could not be written.
	my @found = files_naming_subs(\@COMPILER_FAMILY, 'new');
	is_deeply(\@found, ['lib/Genesis/CI/ProviderCompiler.pm'],
		'only the base defines a constructor')
		or diag(join("\n", map {"  $_"} @found));
};

subtest 'the namespace holds modules and nothing at its root' => sub {
	plan tests => 3;

	# Genesis::CI:: stays as a namespace, as Genesis::Hook:: does,
	# holding the modules beneath it with no module at its root.
	ok !-f 'lib/Genesis/CI.pm',
		'there is no module at the root of the namespace';

	# A deleted module with a live caller fails at load rather than at
	# run time, and a caller nothing in the suite loads reports nothing
	# at all, so the row reads the tree.
	my @files;
	find(sub {push @files, $File::Find::name if -f && /\.(pm|t)$/}, 'lib', 't');
	push @files, 'bin/genesis';

	my @callers;
	for my $file (sort @files) {
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		while (my $line = <$fh>) {
			next if $line =~ /^\s*#/;
			push @callers, "$file:$."
				if $line =~ /\bGenesis::CI\s*->\s*(new|compile)\b/
				|| $line =~ /\buse\s+parent\b.*'Genesis::CI'/
				|| $line =~ /\brequire\s+Genesis::CI\s*;/;
		}
		close $fh;
	}
	is_deeply(\@callers, [],
		'and nothing calls the factory or inherits the trait')
		or diag(join("\n", map {"  $_"} @callers));

	is_deeply([sort map {s{^lib/Genesis/CI/}{}r} glob('lib/Genesis/CI/*.pm')],
		[sort qw/Compiler.pm Layout.pm Legacy.pm Marker.pm Preflight.pm
		         Propagation.pm Provider.pm ProviderCompiler.pm
		         ProviderRegistry.pm Publish.pm Report.pm RunFailure.pm
		         Shuttle.pm Walk.pm/],
		'and the namespace holds the fourteen modules the step leaves it');
};

done_testing;
