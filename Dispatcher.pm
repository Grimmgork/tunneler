package Dispatcher;

use Worker;
use strict;

sub new {
	my $class = shift;
	my $number_of_workers = shift;
	my $work = shift;

	my @workers;
	for(1..$number_of_workers) {
		push @workers, Worker->new($work);
	}
	
	my $self = {
		work => $work,
		on_init => shift,
		on_work_yield => shift,
		on_work_success => shift,
		on_work_error => shift,
		workers => [],
		free_workers => []
	};

	foreach(@workers) {
		push @{$self->{workers}}, $_;
		push @{$self->{free_workers}}, $_;
	}

	bless $self, $class;
	return $self;
}

sub loop {
	my $self = shift;

	my @workers = @{$self->{workers}};

	# prepare workers
	foreach(@workers) {
		$_->fork();
	}

	# run initialization
	my $exit = $self->{on_init}->($self);

	while(1) {
		last if $exit;

		foreach(@workers) {
			next if not $_->has_response();

			my @res = $_->read_response();
			my $type = shift(@res);

			# if worker responds a yield
			if ($type eq "y") 
			{
				$exit = $self->{on_work_yield}->($self, @res);
				last if $exit;
			}

			# if worker responds end
			if ($type eq "e") 
			{
				my $code = shift(@res);
				if ($code)
				{
					$exit = $self->{on_work_error}->($self, $code);
					last if $exit;
				}
				else
				{
					$exit = $self->{on_work_success}->($self);
					last if $exit;
				}

				push @{$self->{free_workers}}, $_;
			}
		}

		sleep(1);
	}
	
	# dispose workers
	foreach(@workers) {
		$_->dispose();
	}
}

sub free_workers {
	my $self = shift;
	my $length = $self->{free_workers};
	return $length;
}

sub start_work {
	my $self = shift;
	my $worker = shift(@{$self->{free_workers}});
	die "all workers busy!" if not $worker;
	$worker->start_work(@_);
}

1;