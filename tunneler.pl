use strict;
use Class::Struct;
use IO::Socket::INET;

struct Host => {
	name => '$',
	port => '$',
	refs => '@',
	endpoints => '@'
};

while(1) {
	my $filename;
	$filename = &pick_unvisited_host;
	unless(defined $filename){
		last;
	}

	my ($hostname, $port) = filename_to_host($filename);
	print "# HOST: $hostname:$port\n";
	write_host(traverse_host($hostname, $port), $filename);
	print "HOST DONE!";
}

sub pick_unvisited_host{
	my $dirname = '.';
	opendir(DIR, $dirname) or die "Could not open $dirname\n";

	my $result;
	my $filename;
	while ($filename = readdir(DIR)) {
  		next unless -f $filename;
		if(&is_host_unvisited(filename_to_host($filename))){
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
	return "$host#$port.txt";
}

sub is_host_unvisited{
	my ($hostname, $port) = @_;
	return -z host_to_filename($hostname, $port);
}

sub is_host_registered{
	my ($hostname, $port) = @_;
	return -e host_to_filename($hostname, $port);
}

sub register_unvisited_host{
	my ($hostname, $port) = @_;
	{ open my $handle, '>', host_to_filename($hostname, $port) }
}

sub write_host{
	my ($host, $filename) = @_;

	open(my $fh, '>', $filename) or die "Could not open file '$filename' $!";
	printf $fh "%s\n", $host->name;
	printf $fh "%s\n", $host->port;
	print $fh "#REF\n";
	if(@{$host->refs} > 0){
		print $fh join("\n", @{$host->refs});
		print $fh "\n";
	}
	print $fh "#STRUCT";
	if(@{$host->endpoints} > 0){
		print $fh "\n";
		print $fh join("\n", @{$host->endpoints});
	}
	close $fh;
}

sub traverse_host{
	my ($hostname, $port) = @_;

	my $host=Host->new();
	$host->name($hostname);
	$host->port($port);

	traverse_gopher_page_recursively($host, "/"); # recursively traverse all gopher pages of server, starting with the index page (empty path).
	
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
	unless(defined $path){
		return "/";
	}
	$path = trim($path);
	if($path eq "" || $path eq "/"){
		return "/";
	}
	return rm_trailing_slash($path);
}

sub traverse_gopher_page_recursively{
	my($host, $path) = @_;

	$path = clean_path($path);

	push(@{$host->endpoints}, "1$path");
	print "+ GOPHER: 1$path\n";

	# request gopher page
	my @rows = request_gopher($host->name, $host->port, $path);
	
	# iterate all endpoints
	foreach my $row (@rows) {
		# register unknown hosts
		my ($rowtype, $rowinfo, $rowpath, $rowhost, $rowport) = $row =~ m/^(.)([^\t]*)?\t?([^\t]*)?\t?([^\t]*)?\t?([^\t]\d*)?/;
		$rowpath = clean_path($rowpath);
		$rowhost = trim($rowhost);
		$rowport = trim($rowport);

		if($rowtype eq "i" || $rowtype eq "3" || $rowtype eq ""){
			next;
		}

		unless((defined $rowhost) && (defined $rowport)){
			next;
		}

		if(($rowhost eq "") && ($rowport eq "")){
			next;
		}

		if(($rowhost eq $host->name) && ($rowport eq $host->port)){
			# link is on the current host
			# register endpoint
			my $pathref = "$rowtype$rowpath";
			unless( grep(/^\Q$pathref\E$/, @{$host->endpoints}) ) {
				if($rowtype eq "1"){
					traverse_gopher_page_recursively($host, $rowpath);
				}
				else{
					push(@{$host->endpoints}, $pathref);
					print "$pathref\n";
				}
			}
		}
		else
		{
			# link to another host
			# register host if unknown
			unless(is_host_registered($rowhost, $rowport)){
				register_unvisited_host($rowhost, $rowport);
				push(@{$host->refs}, "$rowhost:$rowport");
				print "* found new host: $rowhost:$rowport\n";
			}
		}
	}
}

sub request_gopher{
	my($host, $port, $path) = @_;

	my $socket = new IO::Socket::INET (
    		PeerHost => $host,
    		PeerPort => $port,
    		Proto => 'tcp'
	);

	$socket->send("$path\n");
	return <$socket>;
}