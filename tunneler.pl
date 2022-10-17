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
#$root->gophertype('1');

#for((1..1000)){
#	my $path = join "/", "/test/kajdkjawkd/adkajwdkjawkdj", rand(0xffffffff);
#	print try_add_path_to_endpoints($root, $path), "\n";
#}

#try_add_path_to_endpoints($root, "/kek/lel/kok.");
#try_add_path_to_endpoints($root, "/kek/lel/k");

#print get_full_endpoint_path($leave, ());

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
	my ($root, $path, $type) = @_;
	my @segments = split(/\//, $path);
	shift @segments;
	my $current = $root;
	my $isnew = undef;
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
			$isnew = 1;
			$found = PathNode->new();
			$found->name($segment);
			$found->parent($current);
			$found->gophertype("0");
			push @{$current->childs}, $found;
		}

		$current = $found;
		# set $current to the found/new segment-node
	}

	if(defined $isnew){
		return $current;
	}

	return undef; #if it is already in the structure
}

sub get_next_unvisited_endpoint_depth_first{
	my ($root, $node) = @_;

	return;
}

sub get_full_endpoint_path{
	my ($node, @segments) = @_;
	unshift(@segments, $node->name);
	unless(defined $node->parent){
		return join("/", @segments);
	}
	return get_full_endpoint_path($node->parent, @segments);
}

sub traverse_host{
	my ($hostname, $port) = @_;

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);

	data_load_endpoint_cache_for_host($DBH, $host, $port); # prepare database for host

	my $err = traverse_gopher_page_recursively($host, "", 5); # recursively traverse gopher menus of host, starting with the index page "/".
	if(defined $err){
		data_set_host_status($DBH, $hostname, $port, 1); # traversed
	}else{
		data_set_host_status($DBH, $hostname, $port, $err+1); # error occured
	}
	
	data_load_endpoint_cache_for_host(); # unload endpoint-cache
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

sub traverse_gopher_page_recursively{
	my($host, $path, $depth) = @_;

	# dont wander into deep, dark caverns ... o~o
	if($depth < 0 || $path =~ /(\/commit\/|archive|.git)/gi){ 
		return 2; # self restriction error
	}

	$path = clean_path($path);

	# get the id of the endpoint
	my $endpoint_id = data_try_add_endpoint($DBH, $host->name, $host->port, 1, $path, 0);

	# try request gopher page
	my @rows;
	eval{
		@rows = request_gopher($host->name, $host->port, $path);
	};
	if ($@) {
		return 3; # external error
	}

	printf " -> ENTER: %s:%s 1%s\n", $host->name, $host->port, $path;

	# iterate rows
	foreach my $row (@rows) {
		last if($row eq "."); # end of gopher page

		my ($rowtype, $rowinfo, $rowpath, $rowhost, $rowport) = $row =~ m/^([^i3])([^\t]*)?\t?([^\t]*)?\t?([^\t]*)?\t?([^\t]\d*)?/;
		unless(defined $rowtype){ # rowtype i and 3 are ignored
			next;
		}

		if(my ($url) = $rowpath =~ m/^UR[LI]:(.*)/gi)
		{ # extract a full url reference like: URL:http://example.com
			my($protocol, $hostname) = $url =~ m/^([a-z0-9]*):\/\/([^\/:]*)/gi;
			unless(defined $protocol){
				next;
			}
			print " ~ REF: URL:$protocol://$hostname\n";
			data_increment_reference($DBH, $host->name, $host->port, "URL:$protocol", "//$hostname"); # a little trick, the query will convert it to "URL:$protocol://$hostname"
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
			unless(defined data_get_endpoint_id($rowpath)) {
				print "$rowtype$rowpath\n";
				if($rowtype eq "1"){
					# traverse gopher page and hendle the error
					my $err = traverse_gopher_page_recursively($host, $rowpath, $depth-1);
					if($err != 0)
					{ # error occured while traversal
						if($err == 2) { printf " -> SKIP: %s:%s 1%s\n", $host->name, $host->port, $path; }
						elsif ($err == 3) { print " X EXTERNAL ERROR: $@ \n"; }
						else { print " ? UNKNOWN ERROR\n"; }
					}
					else{
						# successful traversal
						printf " -> DONE: %s:%s 1%s\n", $host->name, $host->port, $path;
					}
					data_set_endpoint_status($DBH, $endpoint_id, 1 + $err);
				}
				else{
					data_try_add_endpoint($DBH, $rowhost, $rowport, $rowtype, $rowpath, 0);
				}
			}
		}
		else
		{
			# link to foreign host
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