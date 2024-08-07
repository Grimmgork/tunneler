package Dispatcher;

use strict;
use Worker;
use Worker 'WORKER_EVENT_DONE';
use Worker 'WORKER_EVENT_YIELD';

sub new {
	my $class = shift;
	my $number_of_workers = shift;
	my $work = shift;

	my @workers;
	for (1..$number_of_workers) {
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

	foreach(@workers) {
		$_->fork();
	}

	# handle init
	my $exit = $self->{on_init}->($self);

	while (1) {
		last if $exit;

		foreach (@workers) {
			next if not $_->has_response();

			my $workid = $_->get_work_id();
			my @res = $_->read_response();
			my $type = shift(@res);

			# if worker responds a yield
			if ($type eq WORKER_EVENT_YIELD)
			{
				# handle yield
				$exit = $self->{on_work_yield}->($self, $workid, @res);
				last if $exit;
			}

			# if worker responds done
			if ($type eq WORKER_EVENT_DONE)
			{
				push @{$self->{free_workers}}, $_; # mark worker as free
				
				my $code = shift(@res);
				if ($code)
				{
					# handle error
					$exit = $self->{on_work_error}->($self, $workid, $code);
					last if $exit;
				}
				else
				{
					# handle success
					$exit = $self->{on_work_success}->($self, $workid);
					last if $exit;
				}
			}
		}

		# sleep(1);
	}
	
	foreach (@workers) {
		$_->dispose();
	}
}

sub free_workers {
	my $self = shift;
	my $length = @{$self->{free_workers}};
	return $length;
}

sub start_work {
	my $self = shift;
	my $workid = shift;
	my $worker = shift(@{$self->{free_workers}});
	die "all workers busy!" if not $worker;
	$worker->start_work($workid, @_);
}

1;