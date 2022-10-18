use strict;
use Class::Struct;
use IO::Socket::INET;
use IO::Select;
use Net::Ping;
use List::Util 'first';

require './data.pl';

struct Host => {
	name => '$',
	port => '$',
	refs => '%',
	endpoints => '%'
};

struct PathNode => {
	parent => '$',
	name => '$',
	gophertype => '$',
	childs => '@'
};

#my $root=PathNode->new();

#my @endpoints = try_add_path_to_endpoints($root, split(/\//, "/kek/lel/kok"));
#my $leaf = @endpoints[0];
#my $count = @endpoints;
#print "$count\n";
#print get_full_endpoint_path($leaf);
#exit();

my $PING = "8.8.8.8";
print "INDEXING ...\n";
my $DBH = data_connect("gopherspace.db");
print "DONE!\n";

# prompt user for a host if no unvisited host is in the database
unless(data_get_first_host_unvisited($DBH)){
	my $inpt = defined $ARGV[0] ? $ARGV[0] : prompt("host:port?");
	my ($host, $port) = split_host_port($inpt);
	data_register_new_host($DBH, $host, $port);
}

# main loop
while(my ($id, $host) = data_get_first_host_unvisited($DBH)) {
	my ($hostname, $port) = split_host_port($host);
	print "### START HOST: $hostname:$port ###\n";
	traverse_host($hostname, $port);
}

sub split_host_port{
	my $str = shift @_;
	my ($host, $port) = $str =~ m/(^[a-z0-9-\.]+):?(\d+)?/gi;
	return ($host, 70) unless(defined $port);
	return ($host, $port);
}

sub try_register_host{
	my ($hostname, $port) = @_;

	return undef if($hostname eq "");
	return undef if($port eq "");
	return undef if(data_is_host_registered($hostname, $port));
	
	return data_register_new_host($DBH, $hostname, $port);
}

sub try_add_path_to_endpoints{
	my ($root, @segments, $type) = @_;
	if($segments[0] eq ""){
		shift @segments;
	}
	my $current = $root;
	my @newendpoints = ();
	foreach my $segment ( @segments ) {
		# search children
		my $found = undef;
		foreach (@{$current->childs}){
			if($_->name eq $segment){
				$found = $_;
				last;
			}
		}
		unless(defined $found){
			# add new segment-node
			$found = PathNode->new();
			$found->name($segment);
			$found->parent($current);
			$found->gophertype("0");
			push @{$current->childs}, $found;
			push @{\@newendpoints}, $found;
		}

		$current = $found;
	}

	return @newendpoints;
}

sub get_full_endpoint_path{
	my ($node) = @_;
	bless $node, "PathNode";
	unless(defined $node->parent){
		return $node->name;
	}
	my $name = $node->name;
	my $path = get_full_endpoint_path($node->parent);
	return "$path/$name";
}

sub traverse_host{
	my ($hostname, $port) = @_;

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);

	my @unvisited = ();
	my $root=PathNode->new();
	push(@unvisited, $root);
	
	data_load_endpoint_cache_for_host($DBH, $host, $port); # prepare database for host

	while(my $node = pop @unvisited){
		my $count = @unvisited;
		print "LENGTH: $count\n";
		print "VISITING: ", get_full_endpoint_path($node), "\n";
		traverse_gopher_page($host, get_full_endpoint_path($node), $root, @unvisited);
	}

	data_load_endpoint_cache_for_host(); # unload endpoint-cache
	data_set_host_status($DBH, $host->name, $host->port, 1);
	return $host;
}

sub prompt{
	my($message) = @_;
	print "$message\n";
	my $res = <STDIN>;
	chomp $res;
	return $res;
}

sub trim{
	my($str) = @_;
	$str =~ s/^\s+|\s+$//g;
	return $str;
}

sub clean_path{
	my ($path) = @_;
	$path =~ s/\\/\//g; #replace \ with /
	$path =~ s/^[\s\/]+|[\/\s]+$//g; #trim right / and left + right withespaces
	if($path eq ""){
		return "";
	}
	$path = "/$path";
	return $path;
}

sub has_internet_connection{
	my $p = Net::Ping->new('tcp');
	$p->port_number(443);
	my $res = $p->ping($PING);
	$p->close();
	return $res;
}

sub wait_for_internet_connection{
	sleep(3);
	until(has_internet_connection()){
		sleep(3);
	}
}

sub traverse_gopher_page{
	my($host, $path, $root, @unvisited) = @_;

	printf " -> ENTER: %s:%s 1%s\n", $host->name, $host->port, $path;

	# try request gopher page
	my @rows;
	eval{
		@rows = request_gopher($host->name, $host->port, $path);
	};
	if ($@) {
		return 3; # external error
	}

	# iterate rows
	foreach my $row (@rows) {
		last if($row eq "."); # end of gopher page

		my ($rowtype, $rowinfo, $rowpath, $rowhost, $rowport) = $row =~ m/^([^i3])([^\t]*)?\t?([^\t]*)?\t?([^\t]*)?\t?([^\t]\d*)?/;
		unless(defined $rowtype){ # rowtype i and 3 and invalid rows are ignored
			next;
		}

		if(my ($url) = $rowpath =~ m/^UR[LI]:(.*)/gi)
		{ # extract a full url reference like: URL:http://example.com
			my($protocol, $hostname) = $url =~ m/^([a-z0-9]*):\/\/([^\/:]*)/gi;
			if(defined $protocol){
				print " ~ REF: URL:$protocol://$hostname\n";
				data_increment_reference($DBH, $host->name, $host->port, "URL:$protocol", "//$hostname"); # a little trick, the query will convert it to "URL:$protocol://$hostname"
			}
			next;
		}

		$rowpath = clean_path($rowpath);
		$rowhost = trim(lc $rowhost); # lowercase and trim the domain name

		# exclude invalid host names
		if($rowhost =~ /[^a-z0-9-\.]/i){
			next;
		}

		# exclude *.onion and ftp.* domains
		if($rowhost =~ /(^ftp\.|\.onion$)/gi){
			next;
		}

		if($rowhost eq ""){
			$rowhost = $host->name;
		}

		if($rowport eq ""){
			$rowport = $host->port;
		}

		if(($rowhost eq $host->name) && ($rowport eq $host->port))
		{ # endpoint of current host
			# make sure all endpoints of path are discovered
			my @new = try_add_path_to_endpoints($root, split(/\//, $rowpath), $rowtype);
			unless($rowtype eq "1"){
				pop @new;
			}
			foreach(@new){
				print "NEW Endpoint ", get_full_endpoint_path($_), "\n";
				push(@unvisited, $_);
				print "COUNT: ", scalar(@unvisited), "\n";
			}
		}
		else
		{ # link to foreign host
			# make sure host is registered
			if(defined try_register_host($rowhost, $rowport)){ 
				print " * DICOVERED: $rowhost:$rowport\n";
			}

			data_increment_reference($DBH, $host->name, $host->port, $rowhost, $rowport);
			print " ~ REF: $rowhost:$rowport\n";
		}
	}

	return 0;
}

sub request_gopher{
	my($hostname, $port, $path) = @_;

	my $socket = new IO::Socket::INET (
    		PeerHost => $hostname,
    		PeerPort => $port,
    		Proto => 'tcp',
		Timeout => 10
	);

	unless(defined $socket){
		die "CONNECTION";
	}

	$socket->send("$path\n");
	
	my $selector = new IO::Select();
	$selector->add($socket);

	unless(defined $selector->can_read(7)){
		close($socket);
		die "TIMEOUT!";
	}

	my @result = <$socket>;
	close($socket);
	return @result; # split /\r\n/, $response;
}