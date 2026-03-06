package Genesis::Kit::Compiled;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis;
use Genesis::Term;
use Genesis::Helpers;
use Archive::Tar;

sub new {
	my ($class, %opts) = @_;

	my $tar = $class->_validate_tar_archive(\%opts);
	my $obj =	bless({
		name     => $opts{name},
		version  => $opts{version},
		source   => $opts{archive},
		provider => $opts{provider},
		tar      => $tar,
	}, $class);

}

sub local_kits {
	my ($class, $provider, $path) = @_;
	$path ||= '.';
	$path =~ s{/$}{};

	my %kits;
	for (glob("$path/*")) {
		next unless m{/([^/]*)-(\d+(\.\d+(\.\d+([.-]rc[.-]?\d+)?)?)?).t(ar.)?gz$};
		$kits{$1}{$2} = $class->new(
			name     => $1,
			version  => $2,
			archive  => $_,
			provider => $provider
		);
	}
	return \%kits;
}

sub kit_bug {
	my ($self, @msg) = @_;
	my @errs = (
		csprintf(@msg),
		csprintf("#R{This is a bug in the %s kit.}", $self->id));

	my @authors;
	if ($self->metadata->{authors}) {
		@authors = @{$self->metadata->{authors}};
	} elsif ($self->metadata->{author}) {
		@authors = ($self->metadata->{author});
	}

	my $url = $self->metadata->{code} || '';
	if ($url =~ m/github/) {
		push @errs, csprintf("Please file an issue at #C{%s/issues}", $url);
	} elsif (@authors) {
		push @errs, "Please contact the author(s):";
		push @errs, "  - $_" for @authors;
	}

	$! = 2; die join("\n", @errs)."\n\n";
}

sub id {
	my ($self) = @_;
	return "$self->{name}/$self->{version}";
}

sub name {
	my ($self) = @_;
	return $self->{name};
}

sub version {
	my ($self) = @_;
	return $self->{version};
}

sub extract {
	my ($self) = @_;
	return if $self->{root};
	$self->{root} = workdir();
	my $basedir = sprintf("%s-%s/", $self->{name}, $self->{version});
	$self->{tar}->remove($basedir);
	$self->{tar}->setcwd($self->{root});
	for my $file (sort $self->{tar}->list_files) {
		$self->{tar}->extract_file($file, "$self->{root}/".($file =~ s{^$basedir}{}r));
	}
	Genesis::Helpers->write("$self->{root}/.helper");
	return 1;
}

### Private Class Methods
sub _validate_tar_archive {
	my($class, $opts) = @_;
	bail("Missing required option: archive") unless $opts->{archive};
	bail("Archive file does not exist: $opts->{archive}") unless -f $opts->{archive};
	my $tar = eval{Archive::Tar->new($opts->{archive})};
	bail("Archive file %s does not appear valid: %s", $opts->{archive}, $@) if $@;

	my ($basedir, @o) = grep {$_ !~ m{/.}} map {$_->full_path() =~ s{/*$}{/}r} grep {$_->is_dir} $tar->get_files;
	bail("Archive file %s does not appear to be a valid Genesis kit (missing base directory)", $opts->{archive}) unless $basedir;
	my ($base_name, $base_version) = $basedir =~ m{^([^/]+)-(\d+(\.\d+(\.\d+([.-]rc[.-]?\d+)?)?)?)/$} if $basedir;
	if ($opts->{name} && $opts->{version}) {
		$opts->{version} =~ s/^v//; # Strip leading v if any
		bail("Archive file %s name/version (%s/%s) does not match provided name/version (%s/%s)",
			$opts->{archive}, $base_name // 'unknown', $base_version // 'unknown',
			$opts->{name}, $opts->{version}
		) if (!$base_name || !$base_version || $base_name ne $opts->{name} || $base_version ne $opts->{version});
	} elsif (!$base_name || !$base_version) {
		bail("Archive file %s does not appear to be a valid Genesis kit (missing base director 'name-version')", $opts->{archive});
	} else {
		# Use from archive
		$opts->{name} = $base_name;
		$opts->{version} = $base_version;
	}
	bail(
		"Archive file %s does not appear to be a valid Genesis kit (missing kit.yml in base directory %s)",
		$opts->{archive}, $basedir
	) unless $tar->contains_file("${basedir}kit.yml");

	# TODO: Validate name/version aginst kit.yml contents?

	return $tar;
}



1;
