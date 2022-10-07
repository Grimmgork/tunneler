use strict;
use Class::Struct;
use IO::Socket::INET;
use IO::Select;
use Net::Ping;

require './data.pl';

struct Host => {
	name => '$',
	port => '$',
	refs => '%',
	endpoints => '%'
};

my $PING = "8.8.8.8";
print "INDEXING ...\n";
my $DBH = data_connect("gopherspace.db");
print "DONE!\n";

#test
#data_register_new_host($DBH, "gopher.floodgap.com", 70);
#data_add_endpoint($DBH, "gopher.floodgap.com", 70, "I", "/kek/lel", 0);
#print data_is_endpoint_registered($DBH, "gopher.floodgap.com", 70, "/kek/les");

# data_load_endpoint_cache_for_host($DBH, "sdf.org", 70);
# print data_try_add_endpoint($DBH, "sdf.org", 70, "I" , "/ma", 1);

# print prompt("input?"), "\n";

#my($host, $port) = split_host_port(prompt("host:port?"));
#print "$host\n$port\n";
#my $rowpath = "uri:http://google.com";
#if(my ($url) = $rowpath =~ m/^UR[LI]:(.*)/gi){
#	print $url, "\n";
#}

#exit();

# prompt user for a host if no unvisited host is known
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

sub traverse_host{
	my ($hostname, $port) = @_;

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);

	data_load_endpoint_cache_for_host($DBH, $host, $port); # prepare database for host

	my $err = traverse_gopher_page_recursively($host, "", 3); # recursively traverse gopher menus of host, starting with the index page "/".
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

sub rm_trailing_slash{
	my($str) = @_;
	$str =~ s{/$}{};
	return $str;
}

sub clean_path{
	my ($path) = @_;
	$path = trim($path);
	if($path eq "" || $path eq "/"){
		return "/";
	}
	unless(defined $path){
		return "/";
	}
	unless($path =~ /^\//){
		$path = "/$path";
	}
	$path =~ s/\\/\//g;
	return rm_trailing_slash($path);
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
		printf " -> SKIP: %s:%s 1%s\n", $host->name, $host->port, $path;
		return 1; # self restriction error
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
		print " X ERROR: $@ \n";
		data_set_endpoint_status($DBH, $endpoint_id, 3);
		return 2; # external error
	}

	data_set_endpoint_status($DBH, $endpoint_id, 1);
	printf " -> MAP: %s:%s 1%s\n", $host->name, $host->port, $path;

	# iterate all endpoints
	foreach my $row (@rows) {
		last if($row eq "."); # end of gopher page

		my ($rowtype, $rowinfo, $rowpath, $rowhost, $rowport) = $row =~ m/^(.)([^\t]*)?\t?([^\t]*)?\t?([^\t]*)?\t?([^\t]\d*)?/;

		if($rowtype =~ /^[i3]$/){ # rowtype i and 3 are ignored
			next;
		}

		if(my ($url) = $rowpath =~ m/^UR[LI]:(.*)/gi){ # extract a full url reference like: URL:http://example.com
			$rowpath = $url;
			$rowtype = "U";
		}else{
			$rowpath = clean_path($rowpath);
		}

		$rowhost = trim(lc $rowhost); # lowercase and trim the domain name

		if(($rowhost eq "") or not defined $rowhost){
			next;
		}

		if(($rowport eq "") or not defined $rowport){
			next;
		}

		# link to foreign host
		unless(($rowhost eq $host->name) && ($rowport eq $host->port)){ 
		{
			unless($rowtype =~ /^[8T+2]$/){
				# exclude *.onion and ftp.* domains
				if($rowhost =~ /(^ftp\.|\.onion$)/gi){
					next;
				}

				# make sure host is registered
				if(defined try_register_host($rowhost, $rowport)){ 
					print " * DICOVERED: $rowhost:$rowport\n";
				}
				data_increment_reference($DBH, $host->name, $host->port, $rowhost, $rowport);
				print " ~ REF: $rowhost:$rowport\n";
			}
			next;
		}

		# register local host endpoint
		my $pathref = "$rowtype$rowpath";
		unless(data_get_endpoint_id($rowpath)) {
			print "$pathref\n";
			if($rowtype eq "1"){
				traverse_gopher_page_recursively($host, $rowpath, $depth-1)
			}else{
				data_try_add_endpoint($DBH, $rowhost, $rowport, $rowtype, $rowpath, 0);
			}
		}
	}
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