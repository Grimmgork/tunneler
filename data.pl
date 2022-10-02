use DBI;

sub data_connect{
	my($path) = @_;
	if($path =~ m/[' ""]/i){
		die "invalid database path!"
	}
	my $db = DBI->connect("dbi:SQLite:dbname=$path","","") or die('database error: ' . DBI->errstr());

	# enforce database schema
	$db->do("create table if not exists hosts(host TEXT PRIMARY KEY, status INT not null);");
	$db->do("create table if not exists endpoints(id INTEGER PRIMARY KEY, host TEXT, type CHAR(1), path TEXT, status INT not null);");
	return $db;
}

sub data_disconnect{
	my($db) = @_;
	$db->disconnect;
}

sub data_register_host{
	my($db, $host, $port) = @_;
	my $query = "insert into hosts (host, status) values (?, ?)";
	$db->do($query, undef, "$host:$port", 0);
}

sub data_is_host_registered{
	my($db, $host, $port) = @_;
	my $query = "select * from hosts where host=? LIMIT 1";
	my $sth = $db->prepare($query);
	$sth->execute("$host:$port");
	if($sth->fetchrow_array){
		return 1;
	}
	return 0;
}

sub data_get_first_host_unvisited{
	my($db) = @_;
	my $sth = $db->prepare("select * from hosts where status=0 LIMIT 1");
	$sth->execute;
	return $sth->fetchrow_array;
}

sub data_set_host_status{
	my($db, $host, $port, $status) = @_;
	my $sth = $db->prepare("update hosts set status=? where host=?");
	$sth->execute($status, "$host:$port");
}

sub data_add_endpoint{
	my($db, $host, $port, $type, $path) = @_;
	my $sth = $db->prepare("insert into endpoints (host, type, path, status) VALUES(?, ?, ?, ?)");
	$sth->execute("$host:$port", $type, $path, 0);
}

sub data_set_endpoint_status{
	my($db, $id, $status) = @_;
	my $sth = $db->prepare("update endpoints set status=? where id=?");
	$sth->execute($status, $id);
}

sub data_get_endpoints_where_status{
	my($db, $host, $port, $status) = @_;
	my $sth = $db->prepare("select * from endpoints where host=? and status=?");
	$sth->execute("$host:$port", $status);
	return $sth->fetchrow_array;
}

1;