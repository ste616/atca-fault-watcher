#!/usr/bin/perl

use IO::Uncompress::Gunzip;
use IO::Compress::Gzip;
use List::Util qw/shuffle/;
use strict;

# Display random plots from the drive monitor and classify them
# so we can do some machine learning on them.

# Get the list of files in the plots directory.
my @aplots = glob "plots/*.png";
my @plots = shuffle @aplots;
for (my $i = 0; $i <= $#plots; $i++) {
    print $i." ".$plots[$i]."\n";
    my $plotname = $plots[$i];
    my $logname = "";
    if ($plotname =~ /^plots\/(.*)\.png$/) {
	$logname = "logs/".$1.".txt.gz";
    }
    if ($logname ne "" && -e $logname) {
	# Read in the log file.
	my @loglines = ();
	my $zin = new IO::Uncompress::Gunzip $logname;
	my $alldone = 0;
	while (<$zin>) {
	    chomp;
	    push @loglines, $_;
	    if ($_ =~ /^classification/) {
		# We've already classified this file.
		$alldone = 1;
	    }
	}
	close $zin;
	if ($alldone == 1) {
	    next;
	}
	# We have to classify this dataset.
	# Fork and run a display of this plot.
	my $pid = fork();
	if ($pid == 0) {
	    # We're the child, we turn into a display.
	    my $cmd = "display ".$plotname;
	    exec($cmd);
	}
	# We're the parent, we get some input from the terminal.
	print "\n\n\n\n";
	print "Please classify azimuth tracking and elevation tracking.\n";
	print "(Azimuth is red, elevation is green)\n";
	print "For each, specify one of the following options:\n";
	print "(g) Good tracking, (o) Offset tracking, (s) Sinusoidal tracking,\n";
	print "(b) Bad tracking, (c) Confused plot\n";
	my $gotanswer = 0;
	my @ansels;
	while ($gotanswer == 0) {
	    print "Specify both at once, azimuth first, separated by a space: ";
	    chomp(my $ans = <STDIN>);
	    $ans =~ s/^\s+//g;
	    $ans =~ s/\s+$//g;
	    @ansels = split(/\s+/, $ans);
	    if ($#ansels == 1) {
		if (($ansels[0] eq "g" || $ansels[0] eq "o" || $ansels[0] eq "s" ||
		     $ansels[0] eq "b" || $ansels[1] eq "c") &&
		    ($ansels[1] eq "g" || $ansels[1] eq "o" || $ansels[0] eq "s" ||
		     $ansels[1] eq "b" || $ansels[1] eq "c")) {
		    $gotanswer = 1;
		}
	    }
	    if ($gotanswer == 0) {
		print "   I didn't undestand that response, please try again.\n";
	    }
	}
	push @loglines, "classification: ".join(",", @ansels)."\n";
	# Kill the child.
	kill 15, $pid;
	# Wait for it to die.
	my $wpid = wait;
	# And then save out the file again.
	my $zout = new IO::Compress::Gzip $logname;
	print $zout join("\n", @loglines);
	close $zout;
    }
}
