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

# Perl has no syntax for an invocant; these are the names the tree uses
# for one.  Anything else in first position is a real argument.
my %INVOCANT = map {$_ => 1} qw/$self $class $proto $invocant $class_or_ref $this/;

# Checks that report but do not fail, because the tree has a backlog they
# would otherwise block on.  Advisory is a debt marker, not a severity:
# each one is here because it is correct and unenforceable today, and each
# should be removed from this list once its backlog is cleared.
#
#   stale_error_quote  118 findings across 36 modules -- Errors blocks that
#                      quote text no longer emitted, mostly format-specifier
#                      damage from the comment-to-POD migration.
my %ADVISORY = map {$_ => 1} qw/stale_error_quote/;

sub is_advisory { return $ADVISORY{$_[0]} ? 1 : 0 }

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
		$result->{advisory} = [];
		$result->{ok}       = 0;
		return $result;
	}
	$result->{pod} = $pod;

	push @{$result->{failures}}, _syntax_failures($pod);

	my $code = extract_module($pm);
	my $doc  = parse_pod($pod);
	push @{$result->{failures}}, _coverage_failures($code, $doc);
	push @{$result->{failures}}, _contract_failures($code, $doc);
	push @{$result->{failures}}, _vocabulary_failure($code, $doc) // ();

	# Advisory findings are split out rather than filtered away: they stay
	# visible on every run, which is the only thing stopping a known
	# backlog from quietly becoming the permanent state.
	my (@failures, @advisory);
	for my $f (@{$result->{failures}}) {
		push @{$ADVISORY{$f->{check}} ? \@advisory : \@failures}, $f;
	}
	$result->{failures} = \@failures;
	$result->{advisory} = \@advisory;
	$result->{ok}       = @failures ? 0 : 1;

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

# Anything a caller has to react to counts: what it may be handed, what it
# gives back, and how it fails.  Checked per method rather than per module,
# since a single undocumented failure mode is what a caller trips over.
sub _contract_failures {
	my ($code, $doc) = @_;
	my @failures;

	for my $m (@{$code->{methods}}) {
		next if $m->{is_special};
		my $entry = $doc->{methods}{$m->{name}} or next;   # has_pod covers this

		if (@{$m->{die_messages}} && !$entry->{has_errors}) {
			push @failures, {
				check  => 'errors_documented',
				method => $m->{name},
				detail => sprintf('raises %d error(s) with no B<Errors:> block, first: "%s"',
					scalar @{$m->{die_messages}}, $m->{die_messages}[0]),
			};
		}

		push @failures, _stale_error_quotes($m, $entry);

		# Only where an example would say something the signature line does
		# not: arguments to get wrong, a failure to provoke, or a return
		# that changes with context.
		my $needs_example = @{$entry->{params}}
		                 || @{$m->{die_messages}}
		                 || $m->{has_wantarray};
		my $examples = $entry->{regions}{Examples} // '';

		if ($needs_example && $examples !~ /^\s{2,}\S/m) {
			push @failures, {
				check  => 'has_examples',
				method => $m->{name},
				detail => "takes arguments or raises, but has no B<Examples:> block",
			};
		}

		# There is deliberately no check that the example states its
		# outcome.  Whether one does is not mechanically decidable: these
		# both say exactly what happens and match no verb list --
		#
		#     # $class eq 'Boolean', @rest == ('foo')
		#     # Calls Genesis::Commands::Env::deploy('my-env') and exits 0
		#
		# and command modules document an invocation with no return value
		# to show at all.  Enumerating accepted phrasings makes it a rule
		# about wording, and a build that fails over wording gets routed
		# around rather than obeyed.

		push @failures, _arity_failure($m, $entry) // ();
	}

	return @failures;
}

# Perl draws no syntactic line between a method and a function -- the
# difference is only whether the sub takes an invocant -- so the heading is
# the sole record of which one a module provides.  That makes it easy to
# get wrong by starting from another module's skeleton, and impossible for
# a reader to detect.
#
# Judged for the module rather than per sub, and only where the answer is
# not in doubt:
#
#   - under three subs says nothing; a two-sub module can go either way
#   - a mixin's subs become methods of whatever composes it, whatever they
#     look like here
#   - a module carrying both headings is a class that also exports
#     helpers, which is legitimate
#   - anything between the extremes is a genuine mix
#
# What is left is a module whose subs are uniformly one thing and whose
# heading says the other.
sub _vocabulary_failure {
	my ($code, $doc) = @_;

	return undef if $code->{context}{is_mixin};

	my @methods = grep {!$_->{is_special}} @{$code->{methods}};
	return undef if @methods < 3;

	my $with_invocant = grep {
		@{$_->{params}} && $INVOCANT{$_->{params}[0]}
	} @methods;
	my $ratio = $with_invocant / scalar(@methods);

	my $says_methods   = grep {/\bMETHODS\b/}   @{$doc->{head1_order}};
	my $says_functions = grep {/\bFUNCTIONS\b/} @{$doc->{head1_order}};
	return undef if $says_methods && $says_functions;

	if ($ratio <= 0.1 && $says_methods) {
		return {
			check  => 'section_vocabulary',
			detail => sprintf(
				"%d of %d subs take no invocant, so these are functions; the heading says METHODS",
				scalar(@methods) - $with_invocant, scalar(@methods)),
		};
	}
	if ($ratio >= 0.9 && $says_functions) {
		return {
			check  => 'section_vocabulary',
			detail => sprintf(
				"%d of %d subs take an invocant, so these are methods; the heading says FUNCTIONS",
				$with_invocant, scalar(@methods)),
		};
	}

	return undef;
}

# The mirror of orphaned_pod, for error strings.
#
# Whether the prose of an Errors block is accurate is not decidable, and
# is not gated.  But an author who quotes C<"..."> has made a checkable
# claim: that this sub emits that text.  When no die or bail in the sub
# can produce it, the wording changed and the documentation did not.
#
# Compared with format specifiers and interpolated variables collapsed to
# wildcards, and only on quotes long enough to mean something -- C<"%s">
# is not a claim about anything.
sub _stale_error_quotes {
	my ($m, $entry) = @_;

	my $errors = $entry->{regions}{Errors} // '';
	return () unless length $errors;

	my @quoted = ($errors =~ /C<"([^"]{8,})">/g);
	return () unless @quoted;

	my @emitted = map {_error_shape($_)} @{$m->{die_messages}};
	return () unless @emitted;

	my @failures;
	for my $claim (@quoted) {
		my $shape = _error_shape($claim);
		next if grep {index($_, $shape) >= 0 || index($shape, $_) >= 0} @emitted;
		push @failures, {
			check  => 'stale_error_quote',
			method => $m->{name},
			detail => qq{Errors block quotes "$claim", which no die or bail here emits},
		};
	}
	return @failures;
}

# Everything that varies between the source and the rendered message --
# sprintf specifiers, interpolated variables, whitespace, case -- reduced
# so a quote is compared on the part the author actually wrote.
sub _error_shape {
	my ($text) = @_;
	$text = lc $text;
	$text =~ s/%-?\d*\.?\d*[sdifegxu]/\x00/g;
	$text =~ s/[\$\@][\{]?[\w:>\-\[\]\{\}']+/\x00/g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return $text;
}

# Only an over-count is a defect.
#
# Perl marks an optional parameter with //= or a defined test inside the
# body, not in `my (...) = @_`, so the minimum arity is not recoverable
# from the code at all.  Documenting a call with fewer arguments is how
# an optional parameter is shown -- Service::Github::pulls_url documents
# one and two, and both are right.  Requiring every documented call to
# pass every parameter rejects that idiom across most of the tree.
#
# Passing more arguments than the sub declares is unambiguous: they go
# nowhere.  That is the half worth failing a build over.
sub _arity_failure {
	my ($m, $entry) = @_;

	my $preamble = $entry->{regions}{preamble} // '';
	my $name     = $m->{name};
	my @stated;
	while ($preamble =~ /(?:\$\w+|[\w:]+)->\s*\Q$name\E\s*\(([^)]*)\)/g) {
		push @stated, _count_args($1);
	}
	return undef unless @stated;

	# Only where the parameter list is the whole list.  A shift chain or
	# index access recovers a fragment, and a fragment read as the full
	# signature says "takes at most 0" about subs that take an options
	# hash -- confident and wrong, on nineteen modules.
	return undef unless ($m->{param_source} // '') =~ /^(?:signature|unpack)$/;

	my @params = @{$m->{params}};
	return undef unless @params;

	# A slurpy parameter absorbs the rest of @_, so there is no maximum to
	# exceed.  Checked before the invocant is dropped: a plain function
	# declared sub f(@args) has one parameter and it is the slurpy one.
	return undef if grep {/^[\@\%]/} @params;

	# Drop the invocant only when it is named like one.  Functions have no
	# invocant, and taking their first parameter for one loses a real
	# argument and reports every documented call as one too many.
	shift @params if $INVOCANT{$params[0]};

	my $max = scalar @params;
	my %over = map {$_ => 1} grep {$_ > $max} @stated;
	return undef unless %over;

	return {
		check  => 'signature_arity',
		method => $name,
		detail => sprintf("documented with %s argument(s); the code takes at most %d",
			join('/', sort {$a <=> $b} keys %over), $max),
	};
}

# Commas inside brackets or braces belong to one argument, not two.
sub _count_args {
	my ($text) = @_;
	$text =~ s/^\s+|\s+$//g;
	return 0 unless length $text;

	my ($depth, $count) = (0, 1);
	for my $ch (split //, $text) {
		$depth++ if $ch =~ /[\[\{\(]/;
		$depth-- if $ch =~ /[\]\}\)]/;
		$count++ if $ch eq ',' && $depth == 0;
	}
	return $count;
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
