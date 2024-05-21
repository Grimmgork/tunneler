#!/usr/bin/perl -w
  # pipe6 - bidirectional communication using socketpair
  #   "the best ones always go both ways"
  
use strict;
use lib ".";
use Worker;
use Dispatcher;

sub work {
	my $worker = shift;
	sleep(1);
	print "hello from heavy work\n";
	$worker->yield(1, 2 , 3);
	return 0;
}

sub on_init {
	my $dispatcher = shift;
	$dispatcher->start_work();
	print "init\n";
	return 0;
}

sub on_work_yield {
	print "yield @_\n";
	return 0;
}

sub on_work_success {
	my $dispatcher = shift;
	print "success work\n";
	$dispatcher->start_work();
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