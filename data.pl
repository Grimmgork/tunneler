use DBI;

my %HOST_IDS;
my $DBH;
my $DB_PREP_ADD_ENDPOINT;
my $DB_PREP_SET_ENDPOINT_STATUS;

sub data_connect{
	my($path) = @_;
	if($path =~ m/[' ""]/i){
		die "invalid database path!"
	}
	my $db = DBI->connect("dbi:SQLite:dbname=$path","","", {PrintError => 1, foreign_keys => 1}) or die('database error: ' . DBI->errstr());

	# enforce database schema
	$db->do("create table if not exists hosts(id INTEGER PRIMARY KEY, host TEXT not null unique, status INT not null);");
	$db->do("create table if not exists endpoints(id INTEGER PRIMARY KEY, hostid INT, type CHAR(1), path TEXT, status INT not null, FOREIGN KEY(hostid) REFERENCES hosts(id));");
	$db->do("create table if not exists refs(pair TEXT PRIMARY KEY, count INT not null);");

	# indexing hosts
	my $sth = $db->prepare("select * from hosts");
	$sth->execute();
	while(($id, $host, undef) = $sth->fetchrow()){
   		$HOST_IDS{$host} = $id;
	}
	
	$DBH = $db;
	$DB_PREP_ADD_ENDPOINT = $DBH->prepare("insert into endpoints (hostid, type, path, status) VALUES(?, ?, ?, ?)");
}

sub data_disconnect{
	$DBH->disconnect;
}

sub data_get_host_id{
	my($host, $port) = @_;
	return $HOST_IDS{"$host:$port"};
}

# ### HOSTS:

sub data_register_new_host{
	my($host, $port) = @_;
	my $sth = $DBH->prepare("insert into hosts (host, status) values (?, ?);");
	$sth->execute("$host:$port", 0);
	my $id = $DBH->sqlite_last_insert_rowid;
   	$HOST_IDS{"$host:$port"} = $id;
	return $id;
}

sub data_is_host_registered{
	my($host, $port) = @_;
	return 1 if defined data_get_host_id($host, $port);
	return 0;
}

sub data_get_first_host_unvisited{
	my $sth = $DBH->prepare("select id, host from hosts where status=0 LIMIT 1");
	$sth->execute;
	return $sth->fetchrow_array;
}

sub data_set_host_status{
	my($id, $status) = @_;
	my $sth = $DBH->prepare("update hosts set status=? where id=?");
	$sth->execute($status, $id);
}


# ### ENDPOINTS:

sub data_add_endpoint{
	my($hostid, $type, $path, $status) = @_;
	#my $sth = $DBH->prepare("insert into endpoints (hostid, type, path, status) VALUES(?, ?, ?, ?)");
	$DB_PREP_ADD_ENDPOINT->execute($hostid, $type, $path, $status);
	return $DBH->last_insert_id();
}

sub data_set_endpoint_status{
	my($id, $status) = @_;
	my $sth = $DBH->prepare("update endpoints set status=? where id=?");
	$sth->execute($status, $id);
}

sub data_get_endpoints_where_status{
	my($host, $port, $status) = @_;
	my $sth = $DBH->prepare("select * from endpoints where hostid=? and status=?");
	$sth->execute(data_get_host_id("$host:$port"), $status);
	return $sth->fetchall_arrayref();
}

sub data_get_endpoints_from_host{
	my($hostid) = @_;
	my $sth = $DBH->prepare("select * from endpoints where hostid=?");
	#prompt($hostid);
	$sth->execute($hostid);
	return $sth->fetchall_arrayref();
}

# ### REFERENCES:

sub data_refs_get_count{
	my($from_host, $from_port, $to_host, $to_port) = @_;
	my $sth = $DBH->prepare("select * from refs where pair=? LIMIT 1");
	$sth->execute("$from_host:$from_port=>$to_host:$to_port");
	my(undef, $count) = $sth->fetchrow_array;
	unless(defined $count){
		return 0;
	}
	return $count;
}

sub data_increment_reference{
	my($from_host, $from_port, $to_host, $to_port) = @_;
	my $count = data_refs_get_count($from_host, $from_port, $to_host, $to_port);
	unless($count){
		$DBH->do("insert into refs (pair, count) values (?, ?)", undef, "$from_host:$from_port=>$to_host:$to_port", 1); # insert new row
		return;
	}
	$DBH->do("update refs set count=? where pair=?", undef, $count+1, "$from_host:$from_port=>$to_host:$to_port");
}

1;