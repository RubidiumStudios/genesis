package Genesis::Hook::Blueprint;

use v5.20;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->{features} = [$obj->env->features];
	$obj->{files} = [];
	return $obj
}

sub validate_features {
	my ($self, @features) = @_;
	return 1
}

sub add_files {
	my $self = shift;
	push(@{$self->{files}}, @_);
}


sub add_files_if_wants {
	my ($self, $feature_test, @files) = @_;
	return unless $self->want_feature($feature_test);
	$self->add_files(@files);
}

sub add_files_if_exists {
	my ($self, @files) = @_;
	for my $file (@files) {
		next unless -f $self->kit->path($file);
		$self->add_files($file);
	}
}

# TODO: Add a generalized add_files method that takes an option hashref as first argument
# if_wants => want_feature_match,
# if_exists => 1,
# before => file-match, -or- after => file-match

sub remove_files {
	my $self = shift;
	my @files = @_;
	($self->{files}) = compare_arrays(
		$self->{files},
		\@files
	);
}

sub exchange_files {
	my ($self, %exchange) = @_;
	# Exchange in place any files that match the keys with the values
	for my $i (0 .. $#{$self->{files}}) {
		$self->{files}[$i] = delete $exchange{$self->{files}[$i]}
			if (exists $exchange{$self->{files}[$i]});
		last if (scalar(keys %exchange) == 0);
	}
}

sub results {
	bail(
		"Blueprint hook could not be run"
	) unless $_[0]->{complete};
	bail(
		"Could not determine which YAML files to merge: 'blueprint' specified no files"
	) unless scalar(@{$_[0]->{files}});
	return $_[0]->{files}
}
1;
