use strict;

sub request_worker{
	my ($hostname, $port, $path) = @_;

	# make request
	my $socket = new IO::Socket::INET (
    		PeerHost => $hostname,
    		PeerPort => $port,
    		Proto => 'tcp',
		Timeout => 5
	);

	unless(defined $socket){
		return [1];
	}

	$socket->send("$path\n");
	
	my $selector = new IO::Select();
	$selector->add($socket);
	unless(defined $selector->can_read(5)){
		close($socket);
		return [2];
	}

	my @paths = ();
	my @refs = ();

	# iterate rows
	foreach(<$socket>) {
		# print "processing line ...!\n";
		# $_ holds the text of the current row
		last if($_ eq "."); # end of gopher page

		my ($rowtype, $rowpath, $rowhost, $rowport) = $_ =~ /^([^i3\s])[^\t]*\t([^\t]*)\t([^\t]*)\t(\d+)/;
		unless(defined $rowtype){
			next;
		}

		if(my ($url) = $rowpath =~ m/UR[LI]:(.+)/gi)
		{ # extract a full url reference like: URL:http://example.com
			my($protocol, $host) = $url =~ m/^([a-z0-9]*):\/\/([^\/:]*)/gi;
			if(defined $protocol){
				push(@refs, "URL:$protocol://$host");
			}
			next;
		}
		$rowpath = clean_path($rowpath);

		$rowhost = trim(lc $rowhost); # lowercase and trim the domain name
		# exclude invalid host names including ftp.* and *.onion names
		if($rowhost =~ /[^a-z0-9-\.]|ftp\.|\.onion/i){
			next;
		}

		if($rowhost eq ""){
			$rowhost = $hostname;
			if($rowport eq ""){
				$rowport = $port;
			}
		}

		if(($rowhost eq $hostname) && ($rowport eq $port))
		{ # endpoint of current host
			push(@paths, "$rowtype$rowpath");
		}
		else
		{ # reference to foreign host
			push(@refs, "$rowhost:$rowport");
		}
	}

	# close tcp socket
	close($socket);

	my @result = (0, \@paths, \@refs);
	return \@result;
}

1;