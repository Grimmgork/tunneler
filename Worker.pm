package Worker;

use strict;
use Time::HiRes qw(usleep);

sub new {
	my $class = shift;
	my $self = bless {
		id	   => shift,
		reader  => shift,
		writer  => shift,
		timeout => shift || 5
	}, $class;
}

sub run {
	my $self = shift;
	my $reader = $self->{reader};

	my $id = $self->{id};
	print "worker $id started!\n";
	respond($self, "i"); # respond with "initialized"

	while(<$reader>) {
		chomp($_);
		next if $_ eq "";

		# end command
		# e
		last if $_ =~ /e$/;

		# start a request command
		# s[host] [port] [path]
		if(my($hostname, $port, $path) = $_ =~ /s([^\t]+)\t(\d+)\t(.*)$/) {
			my $code;
			eval {
				$code = request($self, $hostname, $port, $path);
			};
			if($@) {
				$code = 5;
			}
			respond($self, "e", $code);
		}
	}
}

sub request {
	my ($self, $hostname, $port, $path) = @_;
	# print "requesting $hostname $port $path\n";
	# make request
	my $socket = new IO::Socket::INET (
    		PeerHost => $hostname,
    		PeerPort => $port,
    		Proto => 'tcp',
		Timeout => $self->{timeout}
	);

	return 1 unless defined $socket;

	$socket->send("$path\n");
	
	my $selector = new IO::Select();
	$selector->add($socket);
	unless(defined $selector->can_read(5)){
		close($socket);
		return 2;
	}

	my @refs;
	my @paths;

	# iterate rows
	foreach(<$socket>) {
		last if $_ eq "."; # end of gopher page

		my ($rowtype, $rowpath, $rowhost, $rowport) = $_ =~ /^([^i3\s])[^\t]*\t([^\t]*)\t([^\t]*)\t(\d+)/;
		next unless defined $rowtype;

		if(my ($url) = $rowpath =~ m/UR[LI]:(.+)/gi)
		{ # extract a full url reference like: URL:http://example.com
			my($protocol, $host) = $url =~ m/^([a-z0-9]*):\/\/([^\/:]*)/gi;
			if(defined $protocol){
				# print $writer $id . "rURL:$protocol://$host\n";
				respond($self, "r", "URL:$protocol://$host");
			}
			next;
		}
		$rowpath = clean_path($rowpath);

		$rowhost = trim(lc $rowhost); # lowercase and trim the domain name
		# exclude invalid host names including ftp.* and *.onion names
		next if $rowhost =~ /[^a-z0-9-\.]|ftp\.|\.onion/i;

		if($rowhost eq ""){
			$rowhost = $hostname;
			if($rowport eq ""){
				$rowport = $port;
			}
		}

		if(($rowhost eq $hostname) && ($rowport eq $port)) { # endpoint of current host
			# print $writer $id . "p$rowtype$rowpath\n";
			respond($self, "p", "$rowtype$rowpath");
		}
		else { # reference to foreign host
			# print $writer $id . "r$rowhost:$rowport\n";
			respond($self, "r", "$rowhost:$rowport")
		}
	}

	# close tcp socket
	close($socket);
	return 0;
}

sub respond {
	my($self, $type, $payload) = @_;
	my $writer = $self->{writer};
	print $writer $self->{id} . "$type$payload\n";
}

sub clean_path {
	my ($path) = @_;
	$path =~ s/\\/\//g; #replace \ with /
	$path =~ s/^[\s\/]+|[\/\s]+$//g; #trim right / and left + right withespaces
	if($path eq ""){
		return "";
	}
	return "/$path";
}

sub trim {
	my($str) = @_;
	$str =~ s/^\s+|\s+$//g;
	return $str;
}

1;