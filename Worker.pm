package Worker;

use strict;
use Time::HiRes qw(usleep);
use IO::Select;
use Socket;
use IO::Handle;
use IO::Select;

sub new {
	my $class = shift;
	socketpair(my $child, my $parent, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
	$child->autoflush(1);
	$parent->autoflush(1);

	my $self = {
		work   => shift,
		child => $child,
		parent => $parent,
		pid => undef
	};

	bless $self, $class;
	return $self;
}

sub has_response {
	my $self = shift;
	my $select = IO::Select->new();
	$select->add($self->{child});
	return $select->can_read(0);
}

sub read_response {
	my $self = shift;
	my $child = $self->{child};
	my @response;
	my $type = <$child>;
	chomp $type;
	push @response, $type; # type
	my $length = <$child>+0; # length
	for(1..$length) {
		my $res = <$child>;
		chomp $res;
		push @response, $res;
	}
	return @response;
}

sub start_work {
	my $self = shift;
	my $child = $self->{child};
	print $child "w\n";
	my $length = @_;
	print $child "$length\n";
	foreach(@_){
		print $child "$_\n";
	}
}

sub dispose {
	my $self = shift;
	my $child = $self->{child};
	my $parent = $self->{parent};
	print $child "e\n";
	
	my $pid = $self->{pid};
	if (defined $pid) {
		waitpid($pid, 0);
	}
	close $parent;
	close $child;
}

# used by the "work" to respond data
sub yield {
	my $self = shift;
	my $parent = $self->{parent};
	print $parent "y\n";
	my $length = @_;
	print $parent "$length\n";
	foreach(@_){
		print $parent "$_\n";
	}
}

sub fork {
	my $self = shift;
	my $pid = fork;
	if ($pid == 0)
	{
		# child
		close $self->{child};
		print "## worker started!\n";
		thread($self);
		print "## worker shutdown!\n";
		close $self->{parent};
		exit(0); # - fork end
	}
	else
	{
		# parent
		$self->{pid} = $pid;
		close $self->{parent};
	}
}

sub thread {
	my $self = shift;
	my $parent = $self->{parent};
	while(<$parent>) {
		chomp($_);

		# end command
		if($_ eq 'e') {
			last;
		}

		# start work command
		if($_ eq 'w') {
			# read args
			my @args;
			my $length = <$parent>+0;
			for(1..$length) {
				my $arg = <$parent>;
				chomp $arg;
				push @args, $_;
			}

			# do work with gathered args and get error code
			my $code;
			eval {
				$code = $self->{work}->($self, @args);
			}; if($@) {
				$code = 99;
			}

			# signal work done
			print $parent "e\n";
			print $parent "1\n";
			print $parent "$code\n";
		}
	}
}

1;