#!/usr/bin/perl

package ATNF::Twitter::Poster;

use strict;
use Net::Twitter;
use Config::Tiny;
use POSIX qw/strftime/;
require Exporter;
use base 'Exporter';

# Twitter poster Perl library.
# Jamie Stevens 2016

# Manage the posting of status updates to Twitter.

# Global variables.
# The connection variable.
my $twitter_connection;
# A list of words that can be shortened, along with their shortened form.
my %shortens_list;

# The routines we export.
our @EXPORT = qw(new);

sub new {
    # Make a new client for the Twitter poster.
    my $class = shift;
    my $options = shift || {};

    my $self = {};
    bless $self, $class;

    # Add some properties to the options.
    $options->{'ssl'} = 1;
    $options->{'traits'} = [ qw/API::RESTv1_1/ ];
    
    # Check for the minimum required options.
    if (defined $options->{'config_file'} &&
	-e $options->{'config_file'}) {
	# Read some options from a configuration file.
	my $config = Config::Tiny->read($options->{'config_file'}, 'utf8');
	my $p = $config->{'poster'};
	if (defined $p && defined $p->{'api_key'}) {
	    $options->{'consumer_key'} = $p->{'api_key'};
	}
	if (defined $p && defined $p->{'api_secret'}) {
	    $options->{'consumer_secret'} = $p->{'api_secret'};
	}
	if (defined $p && defined $p->{'access_token'}) {
	    $options->{'access_token'} = $p->{'access_token'};
	}
	if (defined $p && defined $p->{'access_token_secret'}) {
	    $options->{'access_token_secret'} = $p->{'access_token_secret'};
	}
    }

    if (!defined $options->{'consumer_key'}) {
	die "Unable to establish connection: no consumer_key specified.\n";
    }
    if (!defined $options->{'consumer_secret'}) {
	die "Unable to establish connection: no consumer_secret specified.\n";
    }
    if (!defined $options->{'access_token'}) {
	die "Unable to establish connection: no access_token specified.\n";
    }
    if (!defined $options->{'access_token_secret'}) {
	die "Unable to establish connection: no access_token_secret specified.\n";
    }

    # We're ready to establish the Twitter connection.
    $twitter_connection = Net::Twitter->new(%{$options});
    
    return $self;
}

sub addShort {
    # Add words that can be shortened.
    my $self = shift;
    my @words = @_;

    for (my $i = 0; $i <= $#words; $i++) {
	# Check for a length 2 array reference as this element.
	my @t = @{$words[$i]};
	if ($#t == 1) {
	    $shortens_list{$t[0]} = $t[1];
	}
    }

    return $self;
}

sub tweet {
    # Post to twitter.
    my $self = shift;
    my $message = shift;

    # Strip leading and trailing whitespace.
    $message =~ s/^\s+//;
    $message =~ s/\s+$//;

    # Convert any multiple consecutive whitespaces to single.
    $message =~ s/\h+/ /g;

    # Prefix the message with the UTC time.
    my $tstring = strftime "%y-%m-%d %R", gmtime;
    $message = $tstring." ".$message;

    # Do some shortening if the message is too long.
    if (length($message) > 140) {
	# Split the message.
	my @mels = split(/\s+/, $message);
	for (my $i = 0; $i <= $#mels; $i++) {
	    if (defined $shortens_list{$mels[$i]}) {
		$mels[$i] = $shortens_list{$mels[$i]};
	    }
	}
	# Reassemble the message.
	$message = join(" ", @mels);
    }

    # Check again to see if we need to be brutal.
    if (length($message) > 140) {
	# Now we simply truncate.
	$message = substr($message, 0, 140);
    }

    # And send the tweet. We do it with an eval since it
    # will kill the program otherwise if the message is a
    # duplicate of the previous one.
    eval { $twitter_connection->update($message); };
    warn $@ if $@;

    # Return the formatted string.
    return $message;
    
}
