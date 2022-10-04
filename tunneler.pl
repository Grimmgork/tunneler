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

#data_register_new_host($DBH, "gopher.floodgap.com", 70);
#data_add_endpoint($DBH, "gopher.floodgap.com", 70, "I", "/kek/lel", 0);
#print data_is_endpoint_registered($DBH, "gopher.floodgap.com", 70, "/kek/les");

# data_load_endpoint_cache_for_host($DBH, "sdf.org", 70);
# print data_try_add_endpoint($DBH, "sdf.org", 70, "I" , "/ma", 1);

# exit();

unless(data_get_first_host_unvisited($DBH)){
	print "Host?:\n";
	my $inpt = defined $ARGV[0] ? $ARGV[0] : <STDIN>;
	my ($host, $port) = host_split($inpt);
	data_register_new_host($DBH, $host, $port);
}

# main loop
while(my ($id, $host) = data_get_first_host_unvisited($DBH)) {
	my ($hostname, $port) = host_split($host);
	print "### START HOST: $hostname:$port ###\n";
	traverse_host($hostname, $port);
}



sub host_split{
	my $str = shift @_;
	return ($str =~ m/(^[a-zA-Z0-9-\.]+):(\d+)/);
}

sub register_host{
	my ($hostname, $port) = @_;

	return 0 if($hostname eq "");
	return 0 if($port eq "");
	return 0 if($hostname =~ /(^ftp\.|\.onion$)/gi); #exclude *.onion and ftp.* domains
	return 0 if(data_is_host_registered($hostname, $port));

	data_register_new_host($DBH, $hostname, $port);
	return 1;
}

sub increment_hash{
	my ($hash, $key) = @_;
	unless($hash->{$key}){
		$hash->{$key} = 1;
	}
	else{
		$hash->{$key} += 1;
	}
}

sub traverse_host{
	my ($hostname, $port) = @_;

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);

	data_load_endpoint_cache_for_host($DBH, $host, $port);
	traverse_gopher_page_recursively($host, "", 3); # recursively traverse all gopher pages of server, starting with the index page "/".
	data_set_host_status($DBH, $hostname, $port, 1);
	data_load_endpoint_cache_for_host();
	return $host;
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

	if($depth < 0 || $path =~ /(\/commit\/|archive|git)/gi){ # dont wander into deep, dark caverns ... 0~0
		#${$host->endpoints}{"1#SKIP#$path"} = 1;
		# data_add_endpoint($DBH, $host->name, $host->port, 1, $path, 2);
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
		print " X ERROR: $@ \n"; # quit if an error occured
		data_set_endpoint_status($DBH, $endpoint_id, 3);
		return 2; # external error
	}

	data_set_endpoint_status($DBH, $endpoint_id, 1);
	printf " -> MAP: %s:%s 1%s\n", $host->name, $host->port, $path;

	# iterate all endpoints
	foreach my $row (@rows) {
		my ($rowtype, $rowinfo, $rowpath, $rowhost, $rowport) = $row =~ m/^(.)([^\t]*)?\t?([^\t]*)?\t?([^\t]*)?\t?([^\t]\d*)?/;

		if($rowtype =~ /^[i3]$/){ # rowtype i and 3 are ignored
			next;
		}

		if($rowhost =~ m/[^\da-z-.ßàÁâãóôþüúðæåïçèõöÿýòäœêëìíøùîûñé]/i){ # check for invalid characters in hostname
			next;
		}

		$rowpath = clean_path($rowpath);
		$rowhost = trim(lc $rowhost); #lowercase and trim the domain name

		if(($rowhost eq "") or not defined $rowhost ){
			next;
		}

		if(($rowport eq "") or not defined $rowport){
			next;
		}

		if(($rowhost eq $host->name) && ($rowport eq $host->port)){ # link is on the current host
			# register endpoint
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
		else # link to another host
		{
			unless($rowtype =~ /^[8T+2]$/){
				if(register_host($rowhost, $rowport)){
					print " * DICOVERED: $rowhost:$rowport\n";
				}
				data_increment_reference($DBH, $host->name, $host->port, $rowhost, $rowport);
				print " ~ REF: $rowhost:$rowport\n";
			}
		}
	}

	# data_commit($DBH);
	return 1;
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