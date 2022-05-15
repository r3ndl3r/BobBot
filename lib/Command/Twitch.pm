package Command::Twitch;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Component::DBI;
use LWP::UserAgent;
use JSON;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_twitch);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro',    default => 'Twitch' );
has access              => ( is => 'ro',    default => 0 );
has timer_seconds       => ( is => 'ro',    default => 30 );
has description         => ( is => 'ro',    default => 'Twitch notification system.' );
has pattern             => ( is => 'ro',    default => '^t(witch)? ?' );
has function            => ( is => 'ro',    default => sub { \&cmd_twitch } );
has timer_sub           => ( is => 'ro',    default => sub 
    { 
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub {$self->twitch; }
        ) 
    }
);

has usage               => ( is => 'ro', default => <<EOF
Usage: 
    Adding and removing streams:
    ![t|witch] [a|dd] [stream]
    ![t|witch] [d|el] [stream]

    List all streams that have been added:
    ![t|witch] [l|ist]

    Toggle tagging yourself in alert messages:
    ![t|witch] [t|ag] [stream]

    List where you have tagging enabled:
    ![t|witch] [t|ag] [l|ist]
EOF
);

my $start = 1;
my %online;

sub cmd_twitch { 
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = lc $msg->{'content'}; # Lowercase everything for arg parsing.
       $args    =~ s/$pattern//i;
    my @args    = split /\s+/, $args;
    my $replyto = '<@' . $author->{'id'} . '>';

    my $config  = $self->{'bot'}{'config'}{'twitch'};
    my $db      = Component::DBI->new();

    my ($arg, $stream) = @args;

    if ($arg =~ /^a(dd)?$/ && $stream) {

        unless ($stream =~ /^\w+$/i) {
            $discord->send_message($channel, "$stream is not valid channel.");
            return;            
        }

        my @streams = @{ $db->get('streams') };

        # Check to see if stream already exists.
        for my $s (@streams) {
            if ($stream eq $s) {
                $discord->send_message($channel, "$stream is already in Twitch alerts list.");
                return;
            }
        }

        unless ( validChannel($stream, $config) ) {
            $discord->send_message($channel, "$stream is not valid channel.");
            return;
        }

        # Add stream and update.
        push @streams, $stream;
        $db->set('streams', \@streams);
    
        $discord->send_message($channel, "Added $stream to Twitch alerts list.");
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");

        return;
    }
    

    if ($arg =~ /^d(el(ete))?$/ and $stream) {
        
        unless ($stream =~ /^\w+$/i) {
            $discord->send_message($channel, "$stream is not valid channel.");
            return;            
        }

        my @streams = @{ $db->get('streams') };

        # Mapping to hash for easier handling.
        my %streams = map { $_ => 1 } @streams;
        unless ( exists $streams{$stream} ) {
            $discord->send_message($channel, "$stream is not in Twitch alerts list.");
            return;
        }

        delete $streams{$stream};

        # Mapping back into an array for storage.
        @streams = keys %streams;

        $db->set('streams', \@streams);
    
        $discord->send_message($channel, "Deleted $stream from Twitch alerts list.");
    
        return;
    }


    if ($arg =~ /^l(ist)?$/) {
        my @streams  = @{ $db->get('streams') };

        if (!@streams) {
            $discord->send_message($channel, "No streams in Twitch alerts list.");
            return;
        }

        # Join all the streamers we have tagging enabled for.
        $discord->send_message($channel, "Twitch alerts enabled for: " . join ', ', sort @streams);
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
    
        return;
    }


   # Toggle enable/disable for tagging.
   if ($arg =~ /^t(ag)?$/ && $stream) {
        
        unless ($stream =~ /^\w+$/i) {
            $discord->send_message($channel, "$stream is not valid channel.");
            return;            
        }       

        unless ($db->get('streams-tagging')) {
            $db->set('streams-tagging', {});
        } 
        
        if ($stream =~ /^l(ist)?$/) {
            my %tagging = %{ $db->get('streams-tagging') };

            if ( exists $tagging{$author->{'id'}} ) {
                my $streams = join ', ', sort keys %{ $tagging{$author->{'id'}} };

                $discord->send_message($channel, "$replyto you have tagging enabled for: $streams");

            } else {
                $discord->send_message($channel, "$replyto you don't have tagging enabled for anybody.");
            }
            
            return;
        }

        my %tagging = %{ $db->get('streams-tagging') };

        if ( $tagging{$author->{'id'}} && $tagging{$author->{'id'}}{$stream} ) {
            $discord->send_message($channel, "$replyto Twitch tagging removed for '**$stream**'.");

            delete $tagging{$author->{'id'}}{$stream};
        } else {
            $discord->send_message($channel, "$replyto Twitch tagging added for '**$stream**'.");

            $tagging{$author->{'id'}}{$stream} = 1;

        }

        $db->set('streams-tagging', \%tagging);

        return;
    }
}


sub twitch {
    my $self = shift;
    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'twitch'};
    my $channel;

    my $db      = Component::DBI->new();
    my @streams = @{ $db->get('streams') };
    
    for my $stream (@streams) {

        my $title = getStream($stream, $config);
        
        if ($title) {
            
            # Check global package variable for onlineless.
            if (!$online{$stream}) {
                # Set stream as online in persistant hash.
                $online{$stream} = 1;
                print localtime . " Twitch => $stream is online. $title\n";

                # Records of when streamer was last on.
                my %laston = %{ $db->get('laston') };

                # Only excute after first loop of check has been completed (after startup).
                if (!$start) {

                    my %tagging = %{ $db->get('streams-tagging') };
                    my (@tags, $message);

                    for my $user (keys %tagging) {
                        if ($tagging{$user}{$stream}) {
                            push @tags, '<@' . $user . '>'
                        }

                    }                   

                    # If last online record exists and it's less than 20 mins ago then probably stream crashed.
                    if (exists $laston{$stream} && (time() - $laston{$stream}) < 1200) {
                        $message = "**$stream** is back online (from probable stream crash).";
                    
                    } else {
                        $message = "**$stream** is online.";

                    }    

                    if ( $message ) {
                        my $time = localtime;
                        my $embed = {   
                                        'embeds' => [ 
                                            {   
                                                'author' => {
                                                    'name'     => $stream,
                                                    'url'      => "https://www.twitch.tv/$stream",
                                                    'icon_url' => 'https://pbs.twimg.com/profile_images/1450901581876973568/0bHBmqXe_400x400.png',
                                                },
                                                'thumbnail' => {
                                                    'url'   => getProfile($stream, $config),
                                                },
                                                'title'       => 'Twitch Alert',
                                                'description' => "$message\n",
                                                'color'       => 48491,
                                                'url'         => "https://www.twitch.tv/$stream",

                                                'fields' => [
                                                    {
                                                        'name'  => 'Title:',
                                                        'value' => $title,
                                                    },
                                                    {
                                                        'name'  => 'Online since:',
                                                        'value' => $time,
                                                    },
                                                ],
                                            } 
                                        ]
                                    };

                        
                        if (@tags) {
                            for my $user (keys %tagging) {
                                if ($tagging{$user}{$stream}) {
                                    $discord->send_dm($user, $embed);
                                }
                            }

                            push @{ $embed->{'embeds'}[0]{'fields'} }, { 'name'  => 'Alerting:', 'value' => join ' ', @tags }; 
                        }

                        $discord->send_message($config->{'channel'}, $embed,
                            sub {

                                my $db  = Component::DBI->new();
                                my $id  = shift->{'id'};
                                my %tMi = %{ $db->get('twitch-message-id') };

                                if ($tMi{$stream}) {
                                    $discord->delete_message($config->{'channel'}, $tMi{$stream});
                                }

                                $tMi{$stream} = $id;

                                $db->set('twitch-message-id', \%tMi);
                            }
                        );   
                        
                    }
                }

                # Update latest stream online timestamp.
                $laston{$stream} = time();
                $db->set('laston', \%laston);

                # Update title.
                my %tMi = %{ $db->get('twitch-message-id') };
                if ($tMi{$stream}) {
                    $discord->get_message($config->{'channel'}, $tMi{$stream},
                        sub {
                                my $msg = shift;
                                $msg->{'embeds'}[0]{'fields'}[0]{'value'} = $title;
                                $discord->edit_message($config->{'channel'}, $tMi{$stream}, $msg);

                        }
                    );
                }
            }
        } else {
            # Stream offline so remove it from online hash.
            delete $online{$stream};

            my %tMi = %{ $db->get('twitch-message-id') };

            if ($tMi{$stream}) {
                $discord->delete_message($config->{'channel'}, $tMi{$stream});
                delete $tMi{$stream};
                $db->set('twitch-message-id', \%tMi);
            }
        }
    }

    # First loop end checkmark.
    $start = 0;
}


sub validChannel {
    my ($stream, $config) = @_;
    my $url = "https://api.twitch.tv/helix/search/channels?query=$stream";
    my $res = LWP::UserAgent->new->get($url,
        'client-id' => $config->{'cid'},
        'Authorization' => "Bearer $config->{'oauth'}",
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


sub getStream {
    my ($stream, $config) = @_;

    my $url = "https://api.twitch.tv/helix/streams?user_login=$stream";
    my $res = LWP::UserAgent->new->get($url,
        'client-id' => $config->{'cid'},
        'Authorization' => "Bearer $config->{'oauth'}",
        );

    if ($res->content =~ /Invalid OAuth/) {
        # Go to https://dev.twitch.tv/console/apps for cid.
        # Then https://twitchapps.com/tokengen/ for oauth (only enter cid).
        print $res->content;
        print "Invalid OAuth token.\n";
        return;
    }

    my $json = from_json($res->content);

    return $json->{'data'} ? $json->{'data'}[0]{'title'} : 0;
}


sub getProfile {
    my ($stream, $config) = @_;

    my $url = "https://api.twitch.tv/helix/users?login=$stream";
    my $res = LWP::UserAgent->new->get($url,
        'client-id' => $config->{'cid'},
        'Authorization' => "Bearer $config->{'oauth'}",
        );

    if ($res->content =~ /Invalid OAuth/) {
        # Go to https://dev.twitch.tv/console/apps for cid.
        # Then https://twitchapps.com/tokengen/ for oauth (only enter cid).
        print $res->content;
        print "Invalid OAuth token.\n";
        return;
    }

    my $json = from_json($res->content);

    return $json->{'data'} ? $json->{'data'}[0]{'profile_image_url'} : 0;
}
1;
