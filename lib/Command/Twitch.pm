package Command::Twitch;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use JSON;
use Date::Parse;
use Component::DBI;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_twitch);


has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro',    default => 'Twitch' );
has access              => ( is => 'ro',    default => 0 );
has timer_seconds       => ( is => 'ro',    default => 300 );
has description         => ( is => 'ro',    default => 'Twitch notification system.' );
has pattern             => ( is => 'ro',    default => '^t(witch)? ?' );
has function            => ( is => 'ro',    default => sub { \&cmd_twitch } );
has usage               => ( is => 'ro',    default => 'https://bob.rendler.org/en/commands/twitch');
has timer_sub           => ( is => 'ro',    default => sub 
    { 
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->twitch }
        ) 
    }
);


my $debug = 0;

sub debug { my $msg = shift; say "[TWITCH DEBUG] $msg" if $debug }


sub twitchGet {
    my $db      = Component::DBI->new();
    my $twitch  = $db->get('twitch') || {};

    return $twitch;
}


sub twitchSet {
    my $twitch = shift;
    my $db     = Component::DBI->new();
    
    return $db->set('twitch', $twitch);
}


sub cmd_twitch { 
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = lc $msg->{'content'}; # Lowercase everything for arg parsing.
       $args    =~ s/$pattern//i;
    my @args    = split /\s+/, $args;

    my $config  = $self->{'bot'}{'config'}{'twitch'};
    
    my ($arg, $streamer) = @args;
    my @cmd = ($self, $discord, $channel, $msg, $streamer, $config);

    if ($arg =~ /^a(dd)?$/ && $streamer)           { add_streamer(@cmd);  return }
    if ($arg =~ /^d(el(ete)?)?$/ && $streamer)     { del_streamer(@cmd);  return }
    if ($arg =~ /^l(ist)?$/)                       { list_streamers(@cmd); return }
    if ($arg =~ /^t(ag)?$/ && $streamer)           { tag(@cmd);  return }
    if ($args =~ /^h(elp)?$/)                      { help(@cmd);  return }
    if ($args =~ /^r(efresh)?$/)                   { $discord->delete_message($msg->{'channel_id'}, $msg->{'id'}); twitch(@_) }
}


sub twitch {
    my $self    = shift;
    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'twitch'};

    my $twitch  = twitchGet();
    my @streams = ref $twitch eq 'HASH' ? keys %$twitch : ();

    for my $streamer (@streams) {
        my $topic = getStream($streamer, $config);
        debug "ONLINE: $streamer - $topic" if $topic;

        if ($topic) {
            stream_online($self, $discord, $config, $streamer, $topic, $twitch);
        } else {
            stream_offline($discord, $config, $streamer, $twitch);
        }
    }
}


sub stream_online {
    my ($self, $discord, $config, $streamer, $topic, $twitch) = @_;

    if ($twitch->{$streamer}{'msgID'} && $twitch->{$streamer}{'topic'} ne $topic) {
        debug "TOPIC CHANGED: $streamer - $topic";
    
        $discord->get_message($config->{'channel'}, $twitch->{$streamer}{'msgID'}, sub {
            my $msg = shift;

            $msg->{'embeds'}[0]{'fields'}[0]{'value'} = $topic;
            $msg->{'embeds'}[0]{'fields'}[2]{'value'} = localtime;

            $discord->edit_message($config->{'channel'}, $twitch->{$streamer}{'msgID'}, $msg);
        });

    } elsif (!$twitch->{$streamer}{'msgID'}) { # Streamer does not already have a message. Send alert.

        send_streamer_message($self, $discord, $config, $streamer, $topic, $twitch);
    }

    $twitch->{$streamer}{'topic'} = $topic;
    twitchSet($twitch);
}


sub stream_offline {
    my ($discord, $config, $streamer, $twitch) = @_;

    if ($twitch->{$streamer}{'msgID'}) {
        $discord->delete_message($config->{'channel'}, $twitch->{$streamer}{'msgID'});
        delete $twitch->{$streamer}{'msgID'};
        delete $twitch->{$streamer}{'topic'};
        twitchSet($twitch);
    }
}


sub send_streamer_message {
    my ($self,$discord, $config, $streamer, $topic, $twitch) = @_;

    # If last online record exists and it's less than 10 mins ago then probably stream crashed.
    my $msg;
    if ($twitch->{$streamer}{'lastOn'} && $twitch->{$streamer}{'lastOn'} > 0 && (time() - $twitch->{$streamer}{'lastOn'}) < 600) {
        $msg = "Streamer `$streamer` is back online (from probable stream crash).";
    } else {
        $msg = "Streamer `$streamer` is online.";
    }
    
    # Streamer is online but no message exists. Create a new message.
    my $time = localtime;
    my $embed = {   
        'embeds' => [ 
            {   
                'author' => {
                    'name'     => $streamer,
                    'url'      => "https://www.twitch.tv/$streamer",
                    'icon_url' => 'https://pbs.twimg.com/profile_images/1450901581876973568/0bHBmqXe_400x400.png',
                },
                'thumbnail' => {
                    'url'   => getProfile($self, $streamer),
                },
                'title'       => 'Twitch Alert',
                'description' => "$msg\n",
                'color'       => 48491,
                'url'         => "https://www.twitch.tv/$streamer",

                'fields' => [
                    {
                        'name'  => 'Title:',
                        'value' => $topic,
                    },
                    {
                        'name'  => 'Online since:',
                        'value' => $time,
                    },
                                                            {
                        'name'  => 'Last update:',
                        'value' => $time,
                    },
                ],
            } 
        ]
    };

    
    my @tags = exists $twitch->{$streamer}{'tags'} ? keys %{ $twitch->{$streamer}{'tags'} } : ();
    if (@tags) {
        my @tagsMsg = map { '<@' . $_ . '>' } @tags;
        push @{ $embed->{'embeds'}[0]{'fields'} }, { 'name'  => 'Alerting:', 'value' => join ' ', @tagsMsg };

        for (@tags) {
            s/\D//g;
            $discord->send_dm($_, $embed);
        }
    }
    
    $twitch->{$streamer}{'lastOn'} = time; 
    $discord->send_message($config->{'channel'}, $embed, sub { $twitch->{$streamer}{'msgID'} = shift->{'id'}; twitchSet($twitch) } );
}


sub add_streamer {
    my ($self, $discord, $channel, $msg, $streamer) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "The streamer `$streamer` is not valid.");
        return;            
    }

    my $twitch  = twitchGet();
    my @streams = ref $twitch eq 'HASH' ? keys %$twitch : ();

    # Check to see if stream already exists.
    for my $s (@streams) {
        if ($streamer eq $s) {
            $discord->send_message($channel, "Streamer `$streamer` is already in Twitch alerts list.");
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }
    }

    unless ( validChannel($self, $streamer) ) {
        $discord->send_message($channel, "Streamer `$streamer` is not a valid.");
        $self->bot->react_error($channel, $msg->{'id'});
        return;
    }

    $twitch->{$streamer} = {};
    twitchSet($twitch);

    $discord->send_message($channel, "Added `$streamer` to Twitch alerts list.");
    $self->bot->react_robot($channel, $msg->{'id'});
}


sub del_streamer {
    my ($self, $discord, $channel, $msg, $streamer, $config) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "Streamer `$streamer` is not valid.");
        $self->bot->react_error($channel, $msg->{'id'});
        return;
    }

    my $twitch  = twitchGet();
    my @streams = keys %$twitch;

    for my $s (@streams) {
        if ($streamer eq $s) {
            # Clean up the message associated with the streamer
            if ($twitch->{$streamer}{'msgID'}) {
                $discord->delete_message($config->{'channel'}, $twitch->{$streamer}{'msgID'});
            }

            # Delete the streamer from the list
            delete $twitch->{$streamer};
            twitchSet($twitch);
            $discord->send_message($channel, "Deleted `$streamer` from alerts list.");
            $self->bot->react_robot($channel, $msg->{'id'});

            return;
        }
    }

    $discord->send_message($channel, "Streamer `$streamer` is not in the alerts list.");
    $self->bot->react_error($channel, $msg->{'id'});
}


sub list_streamers {
    my ($self, $discord, $channel, $msg) = @_;
    my $twitch  = twitchGet();
    my @streams = ref $twitch eq 'HASH' ? keys %$twitch : ();

    if (!@streams) {
        $discord->send_message($channel, "No streams in Twitch alerts list.");
        return;
    }

    $discord->send_message($channel, "Twitch alerts enabled for: " . join(', ', map { "`$_`" } sort @streams));
    $self->bot->react_robot($channel, $msg->{'id'});
}


sub tag {
    my ($self, $discord, $channel, $msg, $streamer) = @_;       
    my $uID       = $msg->{'author'}->{'id'};
    my $twitch    = twitchGet();
    my @streams   = ref $twitch eq 'HASH' ? keys %$twitch : ();
    my %streamers = map { $_ => 1 } @streams;

    

    if ($streamer =~ /^l(ist)?$/) {
        my @tagged;
        for my $s (@streams) {
            if ($twitch->{$s}{'tags'}{$uID}) {
                push @tagged, $s;
            }
        }
        if (@tagged) {
            $discord->send_message($channel, "<\@$uID> you have tagging enabled for: " . join(', ', map { "`$_`" } sort @tagged));
        } else {
            $discord->send_message($channel, "<\@$uID> you don't have tagging enabled for anybody.");
        }
        
        $self->bot->react_robot($channel, $msg->{'id'});
        return;
    }

    if ($twitch->{$streamer}) {
        if ($twitch->{$streamer}{'tags'}{$uID}) {
            delete $twitch->{$streamer}{'tags'}{$uID};
            $discord->send_message($channel, "<\@$uID> Twitch tagging removed for `$streamer`.");
            twitchSet($twitch);
        } else {
            $twitch->{$streamer}{'tags'}{$uID} = 1;
            $discord->send_message($channel, "<\@$uID> Twitch tagging added for `$streamer`.");
            twitchSet($twitch);
        }
        $self->bot->react_robot($channel, $msg->{'id'});
    } else {
        $discord->send_message($channel, "<\@$uID> `$streamer` is not a valid streamer.");
        $self->bot->react_error($channel, $msg->{'id'});
    }
}


# Checks if a channel exists by using the official Twitch API.
sub validChannel {
    my ($self, $streamer) = @_;

    # Get the necessary config and authentication token.
    my $config = $self->bot->config->{twitch};
    my $oauth_token = get_or_generate_oauth_token($config);

    my $url = "https://api.twitch.tv/helix/users?login=$streamer";
    my $ua = LWP::UserAgent->new;

    # Make the API call with the required authentication headers.
    my $res = $ua->get($url,
        'client-id'     => $config->{client_id},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        # The 'data' array will contain a user object if the user is valid.
        # If the user does not exist, the array will be empty.
        if (ref $json->{data} eq 'ARRAY' && @{ $json->{data} }) {
            return 1; # User is valid
        }
    } else {
        # Pass the response to the existing error handler.
        handle_error($res, $config, $streamer);
    }
    
    return 0; # User is not valid or an error occurred
}


sub getStream {
    my ($stream, $config) = @_;

    my $oauth_token = get_or_generate_oauth_token($config);

    my $url = "https://api.twitch.tv/helix/streams?user_login=$stream";
    my $ua = LWP::UserAgent->new;

    my $res = $ua->get($url,
        'client-id'     => $config->{'client_id'},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        return $json->{'data'} ? $json->{'data'}[0]{'title'} : 0;
    } else {
        handle_error($res, $config, $stream);
        return 0;
    }
}


sub get_or_generate_oauth_token {
    my ($config) = @_;

    my $db = Component::DBI->new();
    my $token = ${ $db->get('twitch.oauth') } || undef;

    # Generate new token if missing or empty
    unless ($token) {
        debug "No valid OAuth token found, generating new one.";
        $token = generate_oauth_token($config);
        if ($token) {
            $db->set('twitch.oauth', \$token);
        } else {
            say "[TWITCH DEBUG] Failed to generate OAuth token: get_or_generate_oauth_token().";
        }
    }

    return $token;
}


sub generate_oauth_token {
    debug "Generating new OAuth token.";

    my ($config) = @_;

    my $ua = LWP::UserAgent->new;
    my $res = $ua->post(
        'https://id.twitch.tv/oauth2/token',
        Content => [
            'client_id'     => $config->{'client_id'},
            'client_secret' => $config->{'client_secret'},
            'grant_type'    => 'client_credentials'
        ]
    );

    if ($res->is_success) {
        my $content = $res->content;
        debug "OAuth token generated successfully.";
        return ($content =~ /"access_token":"([^"]+)"/)[0] if $content =~ /"access_token":"([^"]+)"/;
    }

    say "[TWITCH DEBUG] Failed to generate OAuth token: " . $res->status_line . " rate_oauth_token().";

    return undef;
}


sub handle_error {
    my ($res, $config, $stream) = @_;

    if ($res->code == 401) {
        say "Invalid OAuth token.";

        my $oauth_token = generate_oauth_token($config);
        if ($oauth_token) {
            $config->{'oauth'} = $oauth_token;
            # The get_or_generate_oauth_token function will handle saving the new token
            # on the next run, so this function only needs to retry the API call.
            return getStream($stream, $config);
        } else {
            say "[TWITCH DEBUG] Failed to get OAuth token: " . $res->status_line . " handle_error().";
        }
    } else {
        say "[TWITCH DEBUG] Failed to fetch stream data: " . $res->status_line . " handle_error().";
    }
}


sub getProfile {
    my ($self, $streamer) = @_;
    my $config = $self->bot->config->{twitch};

    my $oauth_token = get_or_generate_oauth_token($config);

    my $url = "https://api.twitch.tv/helix/users?login=$streamer";
    my $ua = LWP::UserAgent->new;

    my $res = $ua->get($url,
        'Client-ID'     => $config->{client_id},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        # Check if data array exists and is not empty
        if (ref $json->{data} eq 'ARRAY' && @{ $json->{data} }) {
            return $json->{data}[0]{profile_image_url};
        }
    } else {
        # Handle API errors, e.g., token invalid or network issue
        say "[TWITCH DEBUG] Failed to get profile for $streamer: " . $res->status_line . " " . $res->content . " getProild().";
        handle_error($res, $config, $streamer); # Reuse existing error handler
    }

    return 0; # Return 0 or undef on failure
}


sub help {
    my ($self, $discord, $channel, $msg) = @_;
    my $commands = <<EOF;
Commands:
!twitch add <streamer> - Add a streamer to Twitch alerts list.
!twitch delete <streamer> - Remove a streamer from Twitch alerts list.
!twitch list - List all streamers in Twitch alerts list.
!twitch tag <streamer> - Toggle tagging for a streamer.
EOF
    $discord->send_message($channel, $commands);
}


1;
