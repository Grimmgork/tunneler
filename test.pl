#!/usr/bin/perl -w
  # pipe6 - bidirectional communication using socketpair
  #   "the best ones always go both ways"
use strict;
use Socket;
use IO::Handle;
use IO::Select;

use lib ".";
use Worker;
use Dispatcher;
  # We say AF_UNIX because although *_LOCAL is the
  # POSIX 1003.1g form of the constant, many machines
  # still don't have it.

# my $worker = Worker->new(\&work);
# $worker->fork();
# $worker->start_work();
# $worker->start_work();
# $worker->dispose();

sub work {
	my $w = shift;
	sleep(1);
	print "hello from heavy work\n";
	$w->yield(1, 2 , 3);
	return 0;
}

sub on_init {
	my $self = shift;
	$self->start_work();
	print "init\n";
	return 0;
}

sub on_work_yield {
	print "yield @_\n";
	return 0;
}

sub on_work_success {
	print "success work\n";
	return 0;
}

sub on_work_error {
	print "error work\n";
	return 0;
}

my $dispatcher = Dispatcher->new(1, \&work, 
	\&on_init, 
	\&on_work_yield, 
	\&on_work_success, 
	\&on_work_error
);
$dispatcher->loop();

#   sub test {
# 	my @test = [1, 2, 3];
# 	return @test;
#   }

#   print test();

#   exit 0;

#   socketpair(my $child, my $parent, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
#       or  die "socketpair: $!";
  
#   $child->autoflush(1);
#   $parent->autoflush(1);
  
#   if (my $pid = fork) {
#       close $parent;
#       print $child "Parent Pid $$ is sending this\n";
# 	  sleep 1;
	  
# 	  my $select = IO::Select->new();
# 	  $select->add($child);
# 	  if($select->can_read(0)) {
# 		print "there is data to read\n";
# 	  }

#       close $child;
#       waitpid($pid,0);
#   } else {
#       die "cannot fork: $!" unless defined $pid;
#       close $child;
#       chomp(my $line = <$parent>);
#       print "Child Pid $$ just read this: `$line'\n";
#       print $parent "Child Pid $$ is sending this\n";
#       close $parent;
#       exit;
#   }