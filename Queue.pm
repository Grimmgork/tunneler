package Queue;

use strict;

sub new {
	my $class = shift;

	my $self = {
		filename => shift || 'queue',
		lock => undef
 	};

	bless $self, $class;
	return $self;
}

sub is_empty {
	my $self = shift;
	my $file = $self->{filename};
	return 1 if not -e $file;
	return -z $file;
}

sub enqueue {
	my $self = shift;
	my $file = $self->{filename};
	locks($self);
	my @queue = _deserialize($file);
	foreach(@_){
		unshift @queue, $_;
	}
	_serialize($file, @queue);
	unlocks($self);
}

sub dequeue {
	my $self = shift;
	return undef if is_empty($self);
	my $file = $self->{filename};
	my $n = shift || 1;
	locks($self);
	my @queue = _deserialize($file);
	my @elements;
	foreach(1..$n){
		my $element = pop @queue;
		push @elements, $element; 
	}
	_serialize($file, @queue);
	unlocks($self);
	return @elements;
}

sub _serialize {
	my $file = shift;
	open(my $fh, '>', $file) or die "could not open file!";
	my @queue = @_;
	foreach(@queue) {
		print $fh "$_\n";
	}
	close($fh);
}

sub _deserialize {
	my $file = shift;
	return () if not -e $file;
	open(my $fh, '<', $file) or die "could not open file!";
	my @queue;
	while(<$fh>) {
		chomp $_;
		push @queue, $_;
	}
	close($fh);
	return @queue; 
}

sub locks {
	my $self = shift;
	open($self->{lock}, '>', $self->{filename}.'.lock') or die "could not open lockfile!";
	flock($self->{lock}, 2) or die $!;
}

sub unlocks {
	my $self = shift;
	close($self->{lock});
	unlink($self->{filename}.'.lock');
}

sub DESTROY {
	my $self = shift;
	unlocks($self);
}

1;