package Worker;

use strict;
use Time::HiRes qw(usleep);

sub new {
	my $class = shift;
	my $writer, my $reader;
	pipe($reader, $writer);
	$writer->autoflush(1);

	my $self = {
		id	  => shift,
		work   => shift,
		writer => $writer,
		reader => $reader
	};

	bless $self, $class;
	return $self;
}

sub work {
	my $self = shift;
	my $writer = $self->{writer};
	print $writer "w\n";
	foreach(@_){
		print $writer "$_\n";
	}
}

sub _initialized {
	my($self, $out) = @_;
	my $id = $self->{id};
	print $out "$id\n";
	print $out "i\n";
}

sub _workdone {
	my($self, $out, $code) = @_;
	my $id = $self->{id};
	print $out "$id\n";
	print $out "e\n";
	print $out "$code\n";
}

sub _exit {
	my($self, $out) = @_;
	my $id = $self->{id};
	print $out "$id\n";
	print $out "x\n";
}

# used by the "work" subroutine to respond data
sub yield {
	my($self) = @_;
	my $out = $self->{writer};
	my $id = $self->{id};
	print $out "$id\n";
	print $out "y\n";
	foreach(@_){
		print $out "$_\n";
	}
}

sub fork {
	my $self = shift;
	my $out = shift;

	my $pid = fork(); # - fork
	unless($pid) { # child
		sleep(1);
		close $self->{writer};
		thread($self, $out);
		exit(0); # - fork end
	}
}

sub thread {
	my ($self, $out) = @_;

	my $id = $self->{id};
	print "## worker $id started!\n";
	_initialized($self, $out); # respond with "initialized"

	my $reader = $self->{reader};
	while(<$reader>) {
		chomp($_);
		next if $_ eq "";

		# end command
		if($_ eq 'e') {
			last;
		}

		# start work command
		if($_ eq 'w') {
			my @args;
			while(<$reader>) {
				chomp $_;
				last if $_ eq "";
				push @args, $_;
			}
			my $code;
			eval {
				$code = $self->{work}->($self, @args);
			}; if($@) {
				$code = 99;
			}
			_workdone($self, $out, $code);
		}
	}

	print "## worker $id shutdown!\n";
	_exit($self, $out);

	close $self->{reader};
	close $self->{writer};
	close $out;
}

1;