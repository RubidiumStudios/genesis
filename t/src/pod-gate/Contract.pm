package Contract;
# Error-path fixture: the contract blocks are wrong or absent.  Coverage
# and placement are deliberately correct here -- those faults live in
# Faulty.pm.  One defect per sub, no interactions.

use strict;
use warnings;

sub raises_undocumented {
	my ($self, $path) = @_;
	die "cannot reach $path" unless -e $path;
	return 1;
}

sub takes_args_without_examples {
	my ($self, $first, $second) = @_;
	return $first . $second;
}

sub example_without_outcome {
	my ($self, $v) = @_;
	return uc $v;
}

sub stale_error_quote {
	my ($self, $path) = @_;
	die "no such path: $path" unless -e $path;
	return 1;
}

sub wrong_arity {
	my ($self, $one, $two) = @_;
	return [$one, $two];
}

1;
