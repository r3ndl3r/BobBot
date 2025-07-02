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


my $debug = 1;
my $agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3';


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
    my @cmd = ($discord, $channel, $msg, $streamer, $config);

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
        #undef $topic;
        debug "ONLINE: $streamer - $topic" if $topic;

        if ($topic) {
            stream_online($discord, $config, $streamer, $topic, $twitch);
        } else {
            stream_offline($discord, $config, $streamer, $twitch);
        }
    }
}


sub stream_online {
    my ($discord, $config, $streamer, $topic, $twitch) = @_;

    if ($twitch->{$streamer}{'msgID'} && $twitch->{$streamer}{'topic'} ne $topic) {
        debug "TOPIC CHANGED: $streamer - $topic";
        $discord->get_message($config->{'channel'}, $twitch->{$streamer}{'msgID'}, sub {
            my $msg = shift;

            $msg->{'embeds'}[0]{'fields'}[0]{'value'} = $topic;
            $msg->{'embeds'}[0]{'fields'}[2]{'value'} = localtime;

            $discord->edit_message($config->{'channel'}, $twitch->{$streamer}{'msgID'}, $msg);
        });

    } elsif (!$twitch->{$streamer}{'msgID'}) { # Streamer does not already have a message. Send alert.

        send_message($discord, $config, $streamer, $topic, $twitch);
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


sub send_message {
    my ($discord, $config, $streamer, $topic, $twitch) = @_;

    # If last online record exists and it's less than 10 mins ago then probably stream crashed.
    my $msg;
    if ($twitch->{$streamer}{'lastOn'} && $twitch->{$streamer}{'lastOn'} > 0 && (time() - $twitch->{$streamer}{'lastOn'}) < 600) {
        $msg = "**$streamer** is back online (from probable stream crash).";
    } else {
        $msg = "**$streamer** is online.";
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
                    'url'   => getProfile($streamer),
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
    my ($discord, $channel, $msg, $streamer) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "'**$streamer**' is not valid channel.");
        return;            
    }

    my $twitch  = twitchGet();
    my @streams = ref $twitch eq 'HASH' ? keys %$twitch : ();

    # Check to see if stream already exists.
    for my $s (@streams) {
        if ($streamer eq $s) {
            $discord->send_message($channel, "Streamer '**$streamer**' is already in Twitch alerts list.");
            react_robot($discord, $msg);
            return;
        }
    }

    # Make sure the streamer is valid.
    unless ( validChannel($streamer) ) {
        $discord->send_message($channel, "Streamer '**$streamer**' is not valid.");
        react_robot($discord, $msg);
        return;
    }

    $twitch->{$streamer} = {};
    twitchSet($twitch);

    $discord->send_message($channel, "Added '**$streamer**' to Twitch alerts list.");
    react_robot($discord, $msg);
}


sub del_streamer {
    my ($discord, $channel, $msg, $streamer, $config) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "Streamer '**$streamer**' is not valid.");
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
            $discord->send_message($channel, "Deleted '**$streamer**' from Twitch alerts list.");
            react_robot($discord, $msg);

            return;
        }
    }

    $discord->send_message($channel, "Streamer '**$streamer**' is not in the Twitch alerts list.");
}


sub list_streamers {
    my ($discord, $channel, $msg) = @_;
    my $twitch  = twitchGet();
    my @streams = ref $twitch eq 'HASH' ? keys %$twitch : ();

    if (!@streams) {
        $discord->send_message($channel, "No streams in Twitch alerts list.");
        return;
    }

    # Join all the streamers we have tagging enabled for.
    $discord->send_message($channel, "Twitch alerts enabled for: " . join ', ', sort @streams);
    react_robot($discord, $msg);
}


sub tag {
    my ($discord, $channel, $msg, $streamer) = @_;       
    my $uID       = $msg->{'author'}->{'id'};
    my $twitch    = twitchGet();
    my @streams   = ref $twitch eq 'HASH' ? keys %$twitch : ();
    my %streamers = map { $_ => 1 } @streams;

    react_robot($discord, $msg);

    if ($streamer =~ /^l(ist)?$/) {
        my @tagged;
        for my $s (@streams) {
            if ($twitch->{$s}{'tags'}{$uID}) {
                push @tagged, $s;
            }
        }
        if (@tagged) {
            $discord->send_message($channel, "<\@$uID> you have tagging enabled for: " . join(', ', sort @tagged));
        } else {
            $discord->send_message($channel, "<\@$uID> you don't have tagging enabled for anybody.");
        }
        
        return;
    }

    if ($twitch->{$streamer}) {
        if ($twitch->{$streamer}{'tags'}{$uID}) {
            delete $twitch->{$streamer}{'tags'}{$uID};
            $discord->send_message($channel, "<\@$uID> Twitch tagging removed for '**$streamer**'.");
            twitchSet($twitch);
        } else {
            $twitch->{$streamer}{'tags'}{$uID} = 1;
            $discord->send_message($channel, "<\@$uID> Twitch tagging added for '**$streamer**'.");
            twitchSet($twitch);
        }
    } else {
        $discord->send_message($channel, "<\@$uID> '**$streamer**' is not a valid streamer.");
    }
}


sub validChannel {
    my $streamer = shift;
    my $res = getTwitch($streamer);

    debug $res->status_line;
    if ($res->is_success && $res->decoded_content =~ /(meta property="og:type" content="video.other"|content="video.other" property="og:type)/) {
        return 1;
    } else {
        return 0;
    }
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

    my $oauth_token = '';

    # Read existing token if available
    if (-e 'twitch.oauth') {
        if (open my $fh, '<', 'twitch.oauth') {
            chomp($oauth_token = <$fh>);
            close $fh;
        } else {
            warn "Could not open twitch.oauth for reading: $!";
        }
    }

    # Generate new token if missing or empty
    unless ($oauth_token) {
        debug "No valid OAuth token found, generating new one.";
        $oauth_token = generate_oauth_token($config);
        if ($oauth_token) {
            save_oauth_token($oauth_token);
        } else {
            warn "Failed to generate OAuth token.";
        }
    }

    return $oauth_token;
}


sub save_oauth_token {
    my ($oauth_token) = @_;
    if (open my $fh, '>', 'twitch.oauth') {
        print $fh $oauth_token;
        close $fh;
        debug "Saved OAuth token to twitch.oauth.";
    } else {
        warn "Could not open twitch.oauth for writing: $!";
    }
}


sub handle_error {
    my ($res, $config, $stream) = @_;

    if ($res->code == 401) {
        say "Invalid OAuth token.";

        my $oauth_token = generate_oauth_token($config);
        if ($oauth_token) {
            $config->{'oauth'} = $oauth_token;
            save_oauth_token($oauth_token);

            return getStream($stream, $config);
        } else {
            say "Failed to get OAuth token: " . $res->status_line;
        }
    } else {
        say "Failed to fetch stream data: " . $res->status_line;
    }
}


sub getProfile {
    my $streamer = shift;
    my $res = getTwitch($streamer);

    if ($res->is_success && $res->decoded_content =~ q!(https://\S+-profile_image-300x300.png)!) {
        return $1;
    }

    return 0
}


sub getTwitch {
    my $streamer = shift;
    my $url = "https://www.twitch.tv/$streamer";

    my $ua  = LWP::UserAgent->new(agent => $agent);
    my $res = $ua->get($url);

    return $res;
}


sub help {
    my ($discord, $channel, $msg) = @_;
    my $usage = "Usage: !twitch <add|delete|list|tag> <streamer>\n";
    my $info = "Commands:\n" .
               "!twitch add <streamer> - Add a streamer to Twitch alerts list.\n" .
               "!twitch delete <streamer> - Remove a streamer from Twitch alerts list.\n" .
               "!twitch list - List all streamers in Twitch alerts list.\n" .
               "!twitch tag <streamer> - Toggle tagging for a streamer.\n";
    my $help_message = $usage . $info;
    $discord->send_message($channel, $help_message);
}


sub react_robot { my ($discord, $msg) = @_; $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖") }


1;
