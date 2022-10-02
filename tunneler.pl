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
# my $DBH = data_connect("gopherspace.db");

exit();

while(1) {
	my $filename;
	$filename = &pick_unvisited_host;
	unless(defined $filename){
		last;
	}

	my ($hostname, $port) = filename_to_host($filename);
	print "### START HOST: $hostname:$port ###\n";
	my $host = traverse_host($hostname, $port);
	write_host($host, $filename);
}


sub pick_unvisited_host{
	my $dirname = '.';
	opendir(DIR, $dirname) or die "Could not open $dirname\n";

	my $result;
	my $filename;
	while ($filename = readdir(DIR)) {
  		next unless -f $filename;
		unless(&is_host_visited(filename_to_host($filename))){
			$result = $filename;
			last;
		}
	}

	closedir(DIR);
	return $result;
}

sub filename_to_host{
	my $filename = shift @_;
	return ($filename =~ m/(^[a-zA-Z0-9-\.]+)#(\d+)/);
}

sub host_to_filename{
	my ($host, $port) = @_;
	$host =~ s/[^a-z\d\-.]//gi;
	$port =~ m/\d+/;
	return "$host#$port.txt";
}

sub is_host_visited{
	my ($hostname, $port) = @_;
	return ! -z host_to_filename($hostname, $port);
}

sub is_host_registered{
	my ($hostname, $port) = @_;
	return -e host_to_filename($hostname, $port);
}

sub register_host{
	my ($hostname, $port) = @_;

	return 0 if($hostname =~ /(^ftp\.|\.onion$)/gi); #exclude *.onion and ftp.* domains
	return 0 if(is_host_registered($hostname, $port));

	{ open my $handle, '>', host_to_filename($hostname, $port) }
	return 1;
}

sub write_host{
	my ($host, $filename) = @_;

	open(my $fh, '>', $filename) or die "Could not open file '$filename' $!";
	printf $fh "%s\n", $host->name;
	printf $fh "%s\n", $host->port;
	print $fh "#REF\n";
	my @references = keys %{$host->refs};
	if(@references > 0){
		while ( (my $k, my $v) = each %{$host->refs} ) {
    			print $fh "$k $v\n";
		}
	}
	print $fh "#STRUCT";
	my @endpts = keys %{$host->endpoints};
	if(@endpts > 0){
		print $fh "\n";
		print $fh join("\n", @endpts);
	}
	close $fh;
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

	traverse_gopher_page_recursively($host, "", 3); # recursively traverse all gopher pages of server, starting with the index page "/".
	
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
		${$host->endpoints}{"1#SKIP#$path"} = 1;
		printf " -> SKIP: %s:%s 1%s\n", $host->name, $host->port, $path;
		return 1; # self restriction error
	}

	$path = clean_path($path);

	# try request gopher page
	my @rows;
	eval{
		@rows = request_gopher($host->name, $host->port, $path);
	};
	if ($@) {
		print " X ERROR: $@ \n"; # quit if an error occured
		return 2; # external error
	}

	${$host->endpoints}{"1$path"} = 1;
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

		if(not defined $rowhost){
			$rowhost = $host->name;
		}

		if(not defined $rowport){
			$rowport = $host->port;
		}

		$rowpath = clean_path($rowpath);
		$rowhost = trim(lc $rowhost); #lowercase the domain name

		if(($rowhost eq $host->name) && ($rowport eq $host->port)){ # link is on the current host
			# register endpoint
			my $pathref = "$rowtype$rowpath";
			unless(${$host->endpoints}{$pathref}) {
				${$host->endpoints}{"$pathref"} = 1;
				print "$pathref\n";

				if($rowtype eq "1"){
					traverse_gopher_page_recursively($host, $rowpath, $depth-1)
				}
			}
		}
		else # link to another host
		{
			unless($rowtype =~ /^[8T+2]$/){
				# try register host
				increment_hash(\%{$host->refs}, "$rowhost:$rowport");
				print " ~ REF: $rowhost:$rowport\n";

				if(register_host($rowhost, $rowport)){
					print " * DICOVERED: $rowhost:$rowport\n";
				}
			}
		}
	}

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