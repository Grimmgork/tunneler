use strict;

my $GRAV = 10;
my $MINDIST = 10;
my $CONSTR = 10;

struct Node => {
	xpos => '$',
	ypos => '$',
	mass => '$'
};

struct Connection => {
	from => '$',
	to => '$',
	strength => '$'
};

