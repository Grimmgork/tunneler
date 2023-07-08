use IO::Handle;

pipe(PARENTREAD, PARENTWRITE);
pipe(CHILDREAD, CHILDWRITE);

PARENTWRITE->autoflush(1);
CHILDWRITE->autoflush(1);

if ($child = fork) { # Parent code
   close CHILDREAD; # We don't need these in the parent
   close PARENTWRITE;
   print CHILDWRITE "34+56;\n";
   chomp($result = <PARENTREAD>);
   print "Got a value of $result from child\n";
   close PARENTREAD;
   close CHILDWRITE;
   waitpid($child,0);
} else {
   close PARENTREAD; # We don't need these in the child
   close CHILDWRITE;
   chomp($calculation = <CHILDREAD>);
   print "Got $calculation\n";
   $result = eval "$calculation";
   print PARENTWRITE "$result\n";
   close CHILDREAD;
   close PARENTWRITE;
   exit;
}