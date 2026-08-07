package PodGate::Check;

use strict;
use warnings;

use Exporter qw/import/;
use File::Basename qw/basename/;
use Pod::Checker;

use PodGate::Extract qw/extract_module/;
use PodGate::Pod qw/parse_pod/;

our @EXPORT_OK = qw/check_module load_exclusions module_name_for/;

# Lifetimes, not severities.  Deferred is the only one that gets counted
# out loud, because it is the only one expected to go away.
my %KIND = map {$_ => 1} qw/vendored placeholder deferred/;

sub module_name_for {
	my ($pm) = @_;
	(my $mod = $pm) =~ s{^.*?lib/}{};
	$mod =~ s{\.pm$}{};
	$mod =~ s{/}{::}g;
	return $mod;
}

sub check_module {
	my ($pm) = @_;

	my $result = {
		module   => module_name_for($pm),
		pm       => $pm,
		pod      => undef,
		failures => [],
	};

	(my $pod = $pm) =~ s{\.pm$}{.pod};

	# A module with no POD is one failure, not one per sub.  The fix is a
	# file; listing forty undocumented methods buries that under detail
	# nobody can act on until the file exists.
	unless (-f $pod) {
		push @{$result->{failures}}, {
			check  => 'missing_pod',
			detail => "no $pod beside $pm",
		};
		$result->{ok} = 0;
		return $result;
	}
	$result->{pod} = $pod;

	push @{$result->{failures}}, _syntax_failures($pod);

	my $code = extract_module($pm);
	my $doc  = parse_pod($pod);
	push @{$result->{failures}}, _coverage_failures($code, $doc);

	$result->{ok} = @{$result->{failures}} ? 0 : 1;
	return $result;
}

# Reported as failures rather than as a separate counter.  Kept apart, a
# module whose POD does not parse at all reports zero failures and reads as
# passing -- which is how the two worst modules in the tree scored clean.
sub _syntax_failures {
	my ($pod) = @_;

	my $messages = '';
	open my $fh, '>', \$messages or return ();
	my $checker = Pod::Checker->new(-warnings => 1);
	$checker->parse_from_file($pod, $fh);
	close $fh;

	return () unless $checker->num_errors > 0;

	my @failures;
	for my $line (grep {/\S/} split /\n/, $messages) {
		next unless $line =~ /error/i;
		$line =~ s/^\s*\*\*\*\s*//;
		push @failures, {check => 'pod_syntax', detail => $line};
	}
	# Pod::Checker counted errors even if none of its lines matched; do not
	# let a formatting change upstream turn a hard failure into a pass.
	push @failures, {
		check  => 'pod_syntax',
		detail => sprintf("%s: %d POD syntax error(s)", $pod, $checker->num_errors),
	} unless @failures;

	return @failures;
}

sub _coverage_failures {
	my ($code, $doc) = @_;
	my @failures;

	my %documented = %{$doc->{methods}};
	my %defined    = map {$_->{name} => 1} @{$code->{methods}};

	for my $m (@{$code->{methods}}) {
		# Perl calls these; nobody documents them as API.
		next if $m->{is_special};

		my $entry = $documented{$m->{name}};
		unless ($entry) {
			push @failures, {
				check  => 'has_pod',
				method => $m->{name},
				detail => "sub $m->{name} (line $m->{line}) has no =head2",
			};
			next;
		}

		if ($m->{is_private} && !$entry->{is_interface}) {
			push @failures, {
				check  => 'private_placement',
				method => $m->{name},
				detail => "private sub $m->{name} documented under $entry->{section}",
			};
		}
		if (!$m->{is_private} && $entry->{section} =~ /\bINTERNAL\b/) {
			push @failures, {
				check  => 'public_placement',
				method => $m->{name},
				detail => "public sub $m->{name} documented under $entry->{section}",
			};
		}
	}

	for my $name (sort keys %documented) {
		next if $defined{$name};
		# Interface sections document what subclasses implement, so an
		# entry with no sub here is the point rather than a defect.
		next if $documented{$name}{is_interface};
		push @failures, {
			check  => 'orphaned_pod',
			method => $name,
			detail => "=head2 $name under $documented{$name}{section} has no matching sub",
		};
	}

	return @failures;
}

sub load_exclusions {
	my ($file) = @_;

	open my $fh, '<', $file
		or die "PodGate::Check: cannot read $file: $!\n";

	my %excluded;
	my $kind = '';
	while (my $line = <$fh>) {
		chomp $line;
		next unless $line =~ /\S/;
		next if $line =~ /^\s*#/;

		if ($line =~ /^\s*\[(\w+)\]\s*$/) {
			$kind = lc $1;
			die "PodGate::Check: $file: unknown section [$1]\n" unless $KIND{$kind};
			next;
		}

		my ($module, $reason) = $line =~ /^\s*([\w:]+)\s*(?:#\s*(.*?)\s*)?$/;
		next unless $module;
		die "PodGate::Check: $file: [$kind] $module has no reason\n"
			unless defined $reason && $reason =~ /\S/;

		$excluded{$module} = {kind => $kind, reason => $reason};
	}
	close $fh;

	return \%excluded;
}

1;
