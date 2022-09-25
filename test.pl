use strict;

print(host_to_filename("gopher.floodgap.com", 70), "\n");
my ($host, $port) = filename_to_host("gopher.floodgap.com#70.txt");
print $port, "\n";
print $host, "\n";


sub filename_to_host{
	my $filename = shift @_;
	return ($filename =~ m/(^[a-zA-Z0-9-\.]+)#(\d+)/);
}

sub host_to_filename{
	my ($host, $port) = @_;
	return "$host#$port.txt";
}