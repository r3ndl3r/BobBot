package Command::Alert;

use Moo;
use strictures 2;
use Component::DBI;
use LWP::UserAgent;
use namespace::clean;
use Data::Dumper;
use POSIX qw(strftime);

use Exporter qw(import);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro',    default => 'Alert' );
has access              => ( is => 'ro',    default => 0 );
has timer_seconds       => ( is => 'ro',    default => 30 );
has description         => ( is => 'ro',    default => 'Twitch notification system.' );
has pattern             => ( is => 'ro',    default => '^alert ?' );
has function            => ( is => 'ro', default => sub { \&cmd_alert } );
has timer_sub           => ( is => 'ro',    default => sub 
    { 
        my $self = shift;
        Mojo::IOLoop->recurring($self->timer_seconds => sub {$self->alert; }
        ) 
    }
);

has usage               => ( is => 'ro', default => <<EOF
Usage: 
    Adding and removing streams:
    !alert add [stream]
    !alert del [stream]

    List all streams that have been added:
    !alert streams

    Add yourself to getting tagged in notification messages:
    !alert notify [stream]

    List where you have tagging enabled:
    !alert list
EOF
);

my $channel = 957220899373871124;
my $configf = "$ENV{HOME}/.twitch";
my $start = 1;
my %online;


sub cmd_alert { 
    my ($self, $msg) = @_;
    my $discord = $self->discord;
    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = lc $msg->{'content'}; # Lowercase everything for arg parsing.
    my $replyto = '<@' . $author->{'id'} . '>';

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;
    my @args = split /\s+/, $args;

    my $db = Component::DBI->new();

    if ($args[0] eq 'add' && $args[1]) {

        unless ($args[1] =~ /^\w+$/i) {
            $discord->send_message($channel, "$args[1] is not valid channel.");
            return;            
        }

        my @streams = @{ $db->get('streams') };

        # Check to see if stream already exists.
        for (@streams) {
            if ($args[1] eq $_) {
                $discord->send_message($channel, "$args[1] is already in Twitch alerts list.");
                return;
            }
        }

        unless (getC($args[1])) {
            $discord->send_message($channel, "$args[1] is not valid channel.");
            return;
        }

        # Create the online storage {} for streamer to enable/disable tagging of messages.
        my %online = %{ $db->get('online') };
        $online{$args[1]} = [];
        $db->set('online', \%online);

        # Add stream and update.
        push @streams, $args[1];
        $db->set('streams', \@streams);
    
        $discord->send_message($channel, "Added $args[1] to Twitch alerts list.");

    } elsif (($args[0] eq 'del' or $args[0] eq 'delete') and $args[1]) {
        
        unless ($args[1] =~ /^\w+$/i) {
            $discord->send_message($channel, "$args[1] is not valid channel.");
            return;            
        }

        my @streams = @{ $db->get('streams') };

        # Mapping to hash for easier handling.
        my %streams = map { $_ => 1 } @streams;
        unless (exists $streams{$args[1]}) {
            $discord->send_message($channel, "$args[1] is not in Twitch alerts list.");
            return;
        }

        delete $streams{$args[1]};
        # Mapping back into an array for storage.
        @streams = keys %streams;

        $db->set('streams', \@streams);
    
        $discord->send_message($channel, "Deleted $args[1] from Twitch alerts list.");
    

    } elsif ($args[0] eq 'streams') {
        my @streams  = @{ $db->get('streams') };

        if (!@streams) {
            $discord->send_message($channel, "No streams in Twitch alerts list.");
            return;
        }

        # Join all the streamers we have tagging enabled for.
        $discord->send_message($channel, "Twitch alerts enabled for: " . join ', ', sort @streams);

    # Toggle enable/disable for tagging.
    } elsif ($args[0] eq 'notify' && $args[1]) {
        
        unless ($args[1] =~ /^\w+$/i) {
            $discord->send_message($channel, "$args[1] is not valid channel.");
            return;            
        }        
        
        # Map all the streams into hash for easier handling.
        my %streams = map { $_ => 1 } @{ $db->get('streams') };

        # List all streamers where tagging is enabled by checking id in array*.
        if ($args[1] eq 'list') {
            my @list;
            my %online = %{ $db->get('online') };
            for (keys %online) {
                # Get all user ids where tagging is enabled from online array.
                # Map user ids into a hash for easier handling.
                my %users = map { $_ => 1 } @{ $online{$_} };
                push @list, $_ if exists $users{$author->{'id'}};
            }

            $discord->send_message($channel, "$replyto you have tagging enabled for: " . join (', ', sort @list));
            return;
        }

        # How can we add tagging if stream doesn't exist?
        unless (exists $streams{$args[1]}) {
            $discord->send_message($channel, "$args[1] is not in Twitch alerts list.");
            return;
        }

        # Check if stream exists in online storage table first. Not really needed since it should
        # have been created when streamer was added.    
        my %online = %{ $db->get('online') };

        if (exists $online{$args[1]}) {

            # Map users list array into a hash for easier handling.
            my @users = @{ $online{$args[1]} };
            my %users = map { $_ => 1 } @users;

            # If userid already exists in table delete (disable).
            if (exists $users{$author->{'id'}}) {

                delete $users{$author->{'id'}};
                $discord->send_message($channel, "$replyto twitch tagging disabled for $args[1]");

            } else {
                # Set to 1 to bring key into existance -> array entry.
                $users{$author->{'id'}} = 1;
                $discord->send_message($channel, "$replyto twitch tagging enabled for $args[1]");
            }

            # Map back into an array for storage.
            @{ $online{$args[1]} } = keys %users;
        
        }

        $db->set('online', \%online);
    }
}


sub alert {
    my $self = shift;
    my $discord = $self->discord;

    my $db = Component::DBI->new();
    my @streams = @{ $db->get('streams') };
    
    for my $stream (@streams) {
            if (getS($stream)) {
            
                # Check global package variable for onlineless.
                if (!$online{$stream}) {
                    # Set stream as online in persistant hash.
                    $online{$stream} = 1;
                    print strftime("%a %b %d %H:%M:%S %Y", localtime) . " Twitch => $stream is online.\n";

                    # Records of when streamer was last on.
                    my %laston = %{ $db->get('laston') };

                    # Only excute after first loop of check has been completed (after startup).
                    if (!$start) {

                        # If last online record exists and it's less than 5 mins ago then probably stream crashed.
                        if (exists $laston{$stream} && (time() - $laston{$stream}) < 500) {
                            $discord->send_message($channel, "$stream is back online (from probable stream crash).");
                        } else {

                            # Get users for tagging in notifications.
                            my %online = %{ $db->get('online') };
                            # User ids from streamer online storage, turn it back into an array.
                            my @users = @{ $online{$stream} };
                        
                            # If we have tagging enabled for any users:
                            if (@users) {
                                # Convert userids into tags for messages.
                                my @tags = map { '<@' . $_ . '>' } @users;
                                $discord->send_message($channel, join (' ', @tags) . " $stream is online. https://www.twitch.tv/$stream");
                            } else {
                                # No tagging enabled.
                                $discord->send_message($channel, "$stream is online. https://www.twitch.tv/$stream");
                            }
                        }      
                    }

                    # Update latest stream online timestamp.
                    $laston{$stream} = time();
                    $db->set('laston', \%laston);
                }
            } else {
                # Stream offline so remove it from online hash.
                delete $online{$stream};
            }
    }

    # First loop end checkmark.
    $start = 0;
}


sub getC {
    my $channel = shift;
    my %config = config();
    my $url = "https://api.twitch.tv/helix/search/channels?query=$channel";
    my $res = LWP::UserAgent->new->get($url,
        'client-id' => $config{cid},
        'Authorization' => "Bearer $config{oauth}",
        );

    if ($res->content =~ /Invalid OAuth/) {
        # Go to https://dev.twitch.tv/console/apps for cid.
        # Then https://twitchapps.com/tokengen/ for oauth (only enter cid).
        print $res->content;
        print "Invalid OAuth token.\n";
        return;
    }
    
    return $res->decoded_content =~ /^\{"data":\[\],"pagination":\{\}\}/ ? 0 : 1;
}


sub getS {
    my $channel = shift;
    my %config = config();
    my $url = "https://api.twitch.tv/helix/streams?user_login=$channel";
    my $res = LWP::UserAgent->new->get($url,
        'client-id' => $config{cid},
        'Authorization' => "Bearer $config{oauth}",
        );

    if ($res->content =~ /Invalid OAuth/) {
        # Go to https://dev.twitch.tv/console/apps for cid.
        # Then https://twitchapps.com/tokengen/ for oauth (only enter cid).
        print $res->content;
        print "Invalid OAuth token.\n";
        return;
    }
    return $res->content =~ /^\{"data":\[\]/ ? 0 : 1;
}


sub config {
    my %config;

    open CONFIG, $configf or die $!;
    while (<CONFIG>) {
        chomp;
        my ($k, $v) = split / = /, $_;
        $config{$k} = $v;
    }

    return %config;
}

1;
