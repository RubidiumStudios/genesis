package Genesis::Kit::Dev;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis;
use Genesis::Term;
use Genesis::Helpers;

sub new {
	my ($class, $path) = @_;
	bless({
		source => $path,
	}, $class);
}

sub kit_bug {
	my ($self, @msg) = @_;
	$! = 2; die csprintf(@msg)."\n".
	            csprintf("#R{This is a bug in your dev/ kit.}\n").
	            csprintf("Please contact the author(s):\n").
	            csprintf("  - you\n\n"); # you're welcome, Tom
}

sub id {
	return sprintf("%s/%s (dev)", $_[0]->metadata->{name} || 'unknown', $_[0]->metadata->{version} || 'in-development');
}

sub name {
	return "dev";
}

sub version {
	return "latest";
}

sub is_dev {
	return 1;
}

# The directory is edited in place, so its name and version say nothing
# about its content, and every file under it is hashed instead.  Taken once
# per object, as extract copies the directory once per object.
sub fingerprint {
	my ($self) = @_;
	return $self->{__fingerprint} //= $self->_fingerprint;
}

sub _fingerprint {
	my ($self) = @_;
	require Cwd;
	require Digest::SHA;
	require File::Find;
	my $root = Cwd::abs_path($self->{source}) // $self->{source};
	my @files;
	File::Find::find({no_chdir => 1, follow => 1,
		wanted => sub {push @files, $_ if -f $_}}, $root);
	my $sha = Digest::SHA->new(1);
	for my $file (sort @files) {
		$sha->add(substr($file, length($root)), "\0");
		$sha->addfile($file);
		$sha->add("\0");
	}
	return $sha->hexdigest;
}

sub extract {
	my ($self) = @_;
	return if $self->{root};

	$self->{root} = workdir();
	run({ onfailure => 'Could not copy dev/ kit directory' },
		'cp -a "$1/" "$2/dev"', $self->{source}, $self->{root});
	$self->{root} .= "/dev";

	Genesis::Helpers->write("$self->{root}/.helper");
	return 1;
}

1;
