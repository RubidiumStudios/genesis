package Sample;
# Happy-path fixture for the POD gate's extractor.  Every sub here exists
# to exercise one extraction path; do not add failure cases to this file.

use strict;
use warnings;
use base 'Sample::Base';

our $VERSION = '1.0';
our @EXPORTS = qw/thing/;

use overload
	'""'  => \&to_string,
	'=='  => \&equals;

sub new {
	my ($class, %opts) = @_;
	return bless({%opts}, $class);
}

# my (...) = @_
sub listed_params {
	my ($self, $first, $second) = @_;
	return $first + $second;
}

# shift chain
sub shifted_params {
	my $self = shift;
	my $only = shift;
	return $only;
}

# $_[N] indexing
sub indexed_params {
	return $_[1] ? $_[2] : undef;
}

sub raises {
	my ($self, $path) = @_;
	die "no such path: $path" unless -e $path;
	bail "cannot read %s", $path unless -r $path;
	return 1;
}

sub context_sensitive {
	my ($self) = @_;
	my @all = (1, 2, 3);
	return wantarray ? @all : scalar(@all);
}

sub mutates {
	my ($self, $v) = @_;
	$self->{cached} = $v;
	return $self;
}

sub to_string { return "sample" }
sub equals    { return 0 }

sub optional_second {
	my ($self, $first, $second) = @_;
	$second //= 'default';
	return "$first/$second";
}

sub _private_helper {
	my ($self) = @_;
	return 42;
}

sub AUTOLOAD {
	my ($self) = @_;
	our $AUTOLOAD;
	return if $AUTOLOAD =~ /::DESTROY$/;
	return $self->{stash};
}

sub DESTROY {
	my ($self) = @_;
	return;
}

1;
