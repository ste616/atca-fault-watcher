#!/usr/bin/perl

# Query MoniCA for ATCA status and post to Twitter when something goes wrong.

use Net::Twitter;
use Config::Tiny;
use File::HomeDir;
use ATNF::MoniCA;
use POSIX qw/strftime/;
use Data::Dumper;

use strict;
use sigtrap qw/handler signal_handler normal-signals/;

# The cache of known point descriptions.
my %point_descriptions;
# Some magic definitions.
my %defines = (
    "ALARM_ON" => 1,
    "ALARM_OFF" => -1,
    "ALARM_ACK" => 2,
    "ALARM_UNACK" => -2,
    "ALARM_SHELVED" => 3,
    "ALARM_UNSHELVED" => -3,
    "CODE_WRONG" => -999
    );

# The list of checking subroutines that we call.
my @chkrtns = ( \&chkrtn_cabb_blocks );

# Get the secret keys.
my $config_file = File::HomeDir->my_home."/.twitter";
die "$config_file is missing\n" if not -e $config_file;
my $config = Config::Tiny->read($config_file, 'utf8');

# Make the Twitter connection.
my $nt = Net::Twitter->new(
    ssl => 1,
    traits => [qw/API::RESTv1_1/],
    consumer_key => $config->{poster}{api_key},
    consumer_secret => $config->{poster}{api_secret},
    access_token => $config->{poster}{access_token},
    access_token_secret => $config->{poster}{access_token_secret}
    );

# We keep track of how many monitors we have (sort of a versioning).
my $n_monitors = 0;

# Start by grabbing all the possible alarms from the MoniCA server.
# We store them because we tweet on transition.
my $mon = monconnect("monhost-nar");
die "Unable to connect to MoniCA!\n" if !defined $mon;

my @all_alarms = &get_all_alarms($mon);
my %alarm_states;
for (my $i = 0; $i <= $#all_alarms; $i++) {
    $alarm_states{$all_alarms[$i]->point} = $all_alarms[$i];
    $n_monitors++;
}

# Now go through each check subroutine and get all the points they
# want, storing their initial states.
my %checkpoint_states;
for (my $i = 0; $i <= $#chkrtns; $i++) {
    my @pnts = $chkrtns[$i]->("start");
    for (my $j = 0; $j <= $#pnts; $j++) {
	# Add this point to the hash.
	$checkpoint_states{$pnts[$j]} = "check";
    }
}

# Now we get all the points we require, and their descriptions.
my @allpoints = keys %checkpoint_states;
$n_monitors += ($#allpoints + 1);
my @allpoint_values = monpoll2($mon, @allpoints);
my @allpoint_descriptions = mondetails($mon, @allpoints);
for (my $i = 0; $i <= $#allpoint_values; $i++) {
    $checkpoint_states{$allpoint_values[$i]->point} = $allpoint_values[$i];
}
for (my $i = 0; $i <= $#allpoint_descriptions; $i++) {
    $point_descriptions{$allpoint_descriptions[$i]->point} = $allpoint_descriptions[$i];
}

# Tweet that we've started.
&tweeter($nt, "Monitor started - monitoring $n_monitors points", [ "tmstatus" ]);

# Disconnect MoniCA.
monclose($mon);

# Start our loop.
while(1) {
    # Check for alarms every 1 minute.
    sleep(60);


    # Print the time of check to the console.
    my $dstring = gmtime();
    print "\n=====================================\n";
    print "Check at UTC ".$dstring."\n";
    print "=====================================\n";

    # Connect to MoniCA.
    my $mon = monconnect("monhost-nar");
    if (!defined $mon) {
	print "**** MoniCA connection failed, skipping this check...\n";
	next;
    }
    
    # Check the alarms.
    my @chk_alarms = &get_all_alarms($mon);
    for (my $i = 0; $i <= $#chk_alarms; $i++) {
	# Check that we know about this alarm (we should, but let's be careful).
	if (defined $alarm_states{$chk_alarms[$i]->point}) {
	    # Has the state changed from last time?
	    my $alarm_changed = &check_alarm_change($alarm_states{$chk_alarms[$i]->point},
						    $chk_alarms[$i]);
	    if ($alarm_changed == 1) {
		# State has changed! Make a suitable message.
		my $almsg = &alarm_state_changed($alarm_states{$chk_alarms[$i]->point},
						 $chk_alarms[$i], $mon);
		if ($almsg->{"message"} ne "") {
		    &tweeter($nt, $almsg->{"message"}, [ "alarm" ], $almsg->{"change"});
		} elsif ($almsg->{"change"} == $defines{"CODE_WRONG"}) {
		    # This means our code is wrong.
		    print "  Tweet could not be constructed due to code error.\n";
		}

		# Replace the old status with the new.
		$alarm_states{$chk_alarms[$i]->point} = $chk_alarms[$i];
	    } elsif ($alarm_changed == -1) {
		# This means our code is wrong.
		print "  Something is wrong with alarm check code.\n";
	    }
	}
    }

    # Check all the points we need.
    my @allpoint_values = monpoll2($mon, @allpoints);
    my %new_checkpoint_states;
    for (my $i = 0; $i <= $#allpoint_values; $i++) {
	$new_checkpoint_states{$allpoint_values[$i]->point} = $allpoint_values[$i];
    }
    # And call our checking routines.
    for (my $i = 0; $i <= $#chkrtns; $i++) {
	my @chk_messages = $chkrtns[$i]->("check", \%checkpoint_states, \%new_checkpoint_states);
	# And now make any required tweets.
	for (my $j = 0; $j <= $#chk_messages; $j++) {
	    if ($chk_messages[$j]->{"message"} ne "") {
		&tweeter($nt, $chk_messages[$j]->{"message"}, $chk_messages[$j]->{"tags"});
	    }
	}
    }
    # And update our pointers.
    for (my $i = 0; $i <= $#allpoint_values; $i++) {
	$checkpoint_states{$allpoint_values[$i]->point} = $allpoint_values[$i];
    }
    
    # Disconnect MoniCA.
    monclose($mon);
}

END {
    print "\n+++++++++++++++++\n";
    print "Stopping monitor!\n";
    &tweeter($nt, "Monitor has stopped", [ "tmstatus" ]);
}

sub chkrtn_cabb_blocks {
    my $mode = shift;
    my $valref_old = shift;
    my $valref_new = shift;
    
    # Check for CABB blocks going off-line or coming on-line.

    # Implement mode=start.
    my @all_points;
    for (my $i = 1; $i <= 16; $i++) {
	my $bl1 = sprintf "caccc.cabb.correlator.Block%02d", $i;
	my $bl2 = sprintf "caccc.cabb.correlator.Block%02d", $i + 20;
	push @all_points, $bl1;
	push @all_points, $bl2;
    }
    if ($mode eq "start") {
	# Here we supply a list of points so the server can store their original values.
	return @all_points;
    }

    # All the tweets we want to send.
    my @tweets;
    
    if ($mode eq "check") {
	# We do our checks now.
#	print Dumper $valref_old;
#	print Dumper $valref_new;
	for (my $i = 0; $i <= $#all_points; $i++) {
	    # Check for block changing state.
	    if ($valref_old->{$all_points[$i]}->val ne
		$valref_new->{$all_points[$i]}->val) {
		# Figure out the block.
		my $blk = $all_points[$i];
		$blk =~ s/^.*Block(.*)$/$1/;
		# Did it come on-line off off-line?
		if ($valref_new->{$all_points[$i]}->val eq "OFFLINE") {
		    # It went off-line.
		    # Make the message.
		    push @tweets, { "message" => "block $blk has gone off-line.",
				    "tags" => [ "CABB", "BLOCKOFFLINE" ] };
		} elsif ($valref_new->{$all_points[$i]}->val eq "ONLINE") {
		    # It has come back on-line.
		    # Make the message.
		    push @tweets, { "message" => "block $blk has come back on-line.",
				    "tags" => [ "CABB", "BLOCKONLINE" ] };
		}
	    }
	}

	return @tweets;
    }
}

sub check_alarm_change {
    my $old_alarm = shift;
    my $new_alarm = shift;

    # Check if two alarm states are different.

    # Sanity check - these are the same point right?
    if ($old_alarm->point ne $new_alarm->point) {
	# Silly code, we were sent two non-related alarm points.
	return -1;
    }

    if (($old_alarm->alarm ne $new_alarm->alarm) ||
	($old_alarm->acknowledged ne $new_alarm->acknowledged) ||
	($old_alarm->shelved ne $new_alarm->shelved)) {
	# Something has changed.
	return 1;
    }

    # Nothing has changed.
    return 0;
}

sub alarm_state_changed {
    my $old_alarm = shift;
    my $new_alarm = shift;
    my $mon = shift;

    # We are responsible for crafting the tweet based on the changed
    # alarm state.
    my $msg = "";
    my $alarm_changed = 0;

    # The alarm priorities.
    my @priorities = ( "#INFO", "#MINOR", "#MAJOR", "#SEVERE" );
    
    # Sanity check - these are the same point right?
    if ($old_alarm->point ne $new_alarm->point) {
	# Silly code, we were sent two non-related alarm points.
	return { "change" => $defines{"CODE_WRONG"}, "message" => "" };
    }
    
    # Check if the alarm has started or stopped alarming (of course, we only
    # care if the alarm hasn't been shelved).
    if ($old_alarm->alarm ne $new_alarm->alarm && 
	$new_alarm->shelved eq "false") {
	if ($new_alarm->alarm eq "true") {
	    # This point is now alarming.
	    $alarm_changed = $defines{"ALARM_ON"};
	    # Add the priority.
	    $msg = $priorities[$new_alarm->priority]." ";

#	    $msg .= &point_description_message($new_alarm->point, $mon)." ";

	    # Now the guidance text.
	    $msg .= $new_alarm->guidance." ";

	} elsif ($new_alarm->alarm eq "false") {
	    # This point has finished alarming.
	    $alarm_changed = $defines{"ALARM_OFF"};
	    $msg = &point_description_message($new_alarm->point, $mon)." ";

	    $msg .= "is no longer alarming. ";
	}
    }
    # Has it instead been acknowledged (again, only important if not shelved).
    elsif ($old_alarm->acknowledged ne $new_alarm->acknowledged &&
	   $new_alarm->shelved eq "false") {
	if ($new_alarm->acknowledged eq "true") {
	    # This point has just been acknowledged.
	    $alarm_changed = $defines{"ALARM_ACK"};

	    $msg = &point_description_message($new_alarm->point, $mon)." ";

	    $msg .= "acknowledged by ".$new_alarm->acknowledgedby." ";
	} elsif ($new_alarm->acknowledged eq "false") {
	    # This point no longer acknowledged.
	    $alarm_changed = $defines{"ALARM_UNACK"};

	    $msg = &point_description_message($new_alarm->point, $mon)." ";

	    $msg .= "no longer acknowledged. ";
	}
    }
    # Has it instead been shelved.
    elsif ($old_alarm->shelved ne $new_alarm->shelved) {
	if ($new_alarm->shelved eq "true") {
	    # This point has just been shelved.
	    $alarm_changed = $defines{"ALARM_SHELVED"};

	    $msg = &point_description_message($new_alarm->point, $mon)." ";

	    $msg .= "shelved by ".$new_alarm->shelvedby." ";
	} elsif ($new_alarm->shelved eq "false") {
	    # This point no longer shelved.
	    $alarm_changed = $defines{"ALARM_UNSHELVED"};

	    $msg = &point_description_message($new_alarm->point, $mon)." ";

	    $msg .= "no longer shelved. ";

	    # Check if the point is OK or not.
	    if ($new_alarm->alarm eq "true") {
		$msg .= "Point is still alarming! ";
	    } elsif ($new_alarm->alarm eq "false") {
		$msg .= "Point is OK. ";
	    }
	}
    }

    return { "change" => $alarm_changed, "message" => $msg };
}

sub point_description_message {
    my $point = shift;
    my $mon = shift;

    # Turn a point name into a message-compatible description.
    my $msg = "";

    # Get the description for the point.
    my $pd = &get_point_description($mon, $point);
    if (defined $pd) {
	# We have a description, so we add it.
	$msg .= $pd->description." ";
	# If this is an antenna based point, add which antenna.
	if ($point =~ /^(ca0.).*/) {
	    $msg .= uc($1)." ";
	}
    } else {
	# Just put the point name.
	$msg .= $point." ";
    }

    return $msg;
}

sub signal_handler {
    die "Signal caught $!";
}

sub get_all_alarms {
    my $mon = shift;

    return monallalarms($mon);
}

sub get_point_description {
    my $mon = shift;
    my $point = shift;

    # Get the description for the specified point.
    # First, check our cache.
    if (defined $point_descriptions{$point}) {
	return $point_descriptions{$point};
    }

    # Get it from the server.
    my @points = ( $point );
    my @descriptions = mondetails($mon, @points);

    # Check we get what we expect.
    if ($descriptions[0]->point eq $point) {
	$point_descriptions{$point} = $descriptions[0];
	return $point_descriptions{$point};
    } else {
	return undef;
    }
}

sub tweeter {
    my $nt = shift;
    my $msg = shift;
    my $type = shift;
    my @everything_else = @_;

    # Do we add things to our type list?
    if ($type->[0] eq "alarm") {
	if ($everything_else[0] == $defines{"ALARM_ACK"} ||
	    $everything_else[0] == $defines{"ALARM_UNACK"}) {
	    $type->[0] eq "alarm_ack";
	} elsif ($everything_else[0] == $defines{"ALARM_SHELVED"}) {
	    push @{$type}, "shelved";
	} elsif ($everything_else[0] == $defines{"ALARM_UNSHELVED"}) { 
	    push @{$type}, "unshelved";
	}
    }
    
    # Make a tweet.
    my $tweet = &format_tweet($msg, $type);

    # Output the tweet to the screen, along with its length.
    printf "**** Tweeting %d char message: \"%s\"\n", length($tweet), $tweet;
    
    # And make the update.
    $nt->update($tweet);
}

sub format_tweet {
    my $msg = shift;
    my $type = shift;

    # Turn some known names into hashtags.
    my @hashtags = ( "CABB" );

    # Make the message lower case (easier for string replacement later).
    $msg = lc($msg);
    
    # Add the types as hashtags.
    my $pfx = "";
    for (my $i = 0; $i <= $#{$type}; $i++) {
	# We add to the beginning of the message, because these will
	# be the triggers for actions by the users.
	$pfx .= "#".uc($type->[$i])." ";
    }
    $msg = $pfx.$msg;

    # Strip leading and trailing whitespace.
    $msg =~ s/^\s+//;
    $msg =~ s/\s+$//;

    # Turn multiple consecutive whitespace to single.
    $msg =~ s/\h+/ /g;
    
    # Put the time at the start.
    my $tstring = strftime "%y-%m-%d %R", gmtime;
    $msg = $tstring." ".$msg;
    
    # Check first to see if the message is too long.
    if (length($msg) > 140) {
	# We have to cut something out.
	$msg = &shortener($msg);
    }

    # Add the hashtags.
    for (my $i = 0; $i <= $#hashtags; $i++) {
	if (index($msg, $hashtags[$i]) != -1) {
	    # Check it isn't already a hashtag.
	    my $chk = "#".$hashtags[$i];
	    if (index($msg, $chk) == -1) {
		# We only need one hashtag with this type, so
		# just replace the first occurrence.
		my $f = $hashtags[$i];
		my $r = $chk;
		$msg =~ s/$f/$r/;
	    }
	}
    }

    # Check again if the message is too long.
    if (length($msg) > 140) {
	$msg = &shortener($msg);
    }

    # And now check if we've failed to shorten it enough.
    if (length($msg) > 140) {
	# Now we simply truncate.
	$msg = substr($msg, 0, 140);
    }

    # Now we turn things back into uppercase.
    $msg = &uppercasener($msg);
    
    return $msg;
}

sub uppercasener {
    my $msg = shift;

    # Capitalise all hashtags.
    $msg =~ s/\#(\w+)/\#\U$1/g;

    # Capitalise all CA0...
    $msg =~ s/ca0(\d)/CA0$1/g;

    # Capitalise list of words.
    $msg =~ s/\scabb\s/ CABB /g;
    $msg =~ s/\srf\s/ RF /g;

    # Capitalise first lower-case letter on the line.
    $msg =~ s/([a-z])/\u$1/;
    
    # Capitalise first letter after full stops.
    $msg =~ s/\.\s+(\w)/. \u$1/g;

    return $msg;
}

sub shortener {
    my $msg = shift;

    # Some words we can shorten and their shortened forms.
    my @shrts = ( 
	[ "temperature", "temp" ], [ "cryogenics", "cryo" ],
	[ "synthesiser", "synth" ], [ "millimetre", "mm" ],
	[ "frequency", "freq" ], [ "observations", "obs" ],
	[ "check", "chk" ], [ "block", "blk" ],
	[ "correlator", "CABB" ], [ "antenna", "ant" ],
	[ "high", "hi"], [ "low", "lo" ]
	);

    for (my $i = 0; $i <= $#shrts; $i++) {
	if (index($msg, $shrts[$i]->[0]) != -1) {
	    # This string is here.
	    my $f = $shrts[$i]->[0];
	    my $r = $shrts[$i]->[1];
	    $msg =~ s/$f/$r/g;

	    # Have we shortened it enough?
	    if (length($msg) <= 140) {
		# Yes we have.
		last;
	    }
	}
    }

    return $msg;
}
