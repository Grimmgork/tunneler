sub spawn_threads {
	my ($main, $worker, $n) = @_;
	pipe(my $preader, my $cwriter) || die "pipe failed: $!";
	$cwriter->autoflush(1);

	my @pwriters;
	for(1..$n){
		pipe(my $creader, my $pwriter) || die "pipe failed: $!";
		$pwriter->autoflush(1);
		push @pwriters, $pwriter;

		my $pid = fork(); # - fork
		unless($pid) { # child
			close $pwriter;
			close $preader;
			$worker->($creader, $cwriter);
			close $creader;
			close $cwriter;
			print "worker shutdown!\n";
			exit(0); # - fork end
		}
	}

	close $creader;
	close $cwriter;
	print "main started!\n";
	$main->($preader, \@pwriters);
	close $preader;
	foreach(@pwriters){
		close $_;
	}
	print "main shutdown\n";
}

sub main {
	my ($reader, $writers) = @_;
	foreach(@$writers){
		print $_ "start\n";
		# close $_;
	}
	while(<$reader>){
		print $_;
	}
}

sub worker {
	my ($reader, $writer) = @_;
	while(<$reader>){
		if($_ eq "start\n"){
			for(1..10){
				print $writer "test\n";
			}
			close $writer;
		}
	}
}

spawn_threads(\&main, \&worker, 5);