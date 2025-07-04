package Command::Twitch;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use JSON;
use Date::Parse;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_twitch);


has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy',  builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy',  builder => sub { shift->bot->log } );
has db                  => ( is => 'ro',    required => 1 );
has name                => ( is => 'ro',    default => 'Twitch' );
has access              => ( is => 'ro',    default => 0 );
has timer_seconds       => ( is => 'ro',    default => 300 );
has description         => ( is => 'ro',    default => 'Twitch notification system.' );
has pattern             => ( is => 'ro',    default => '^t(witch)? ?' );
has function            => ( is => 'ro',    default => sub { \&cmd_twitch } );
has usage               => ( is => 'ro',    default => <<~'EOF'
    **Twitch Alerts Command Help**

    This command allows you to manage Twitch streamer alerts.
    When a streamer goes live, the bot will post a notification in the configured channel.

    `!twitch add <streamer_username>`
    Adds a Twitch streamer to the alert list. The bot will monitor this streamer's status.
    *Example:* `!twitch add shroud`

    `!twitch remove <streamer_username>`
    Removes a Twitch streamer from the alert list.
    *Example:* `!twitch remove summit1g`

    `!twitch list`
    Displays all streamers currently being monitored for alerts.

    `!twitch tag <streamer_username>`
    Toggles personal Direct Message (DM) alerts for a specific streamer. If enabled, you will receive a DM when that streamer goes live.
    *Example:* `!twitch tag cdawg`

    `!twitch tag list`
    Displays all streamers for whom you have personal DM alerts enabled.

    `!twitch refresh`
    Manually triggers an immediate check for all monitored streamers. Useful if you want to force an update.

    `!twitch help`
    Displays this detailed help message.
    EOF
);

has timer_sub => ( is => 'ro',    default => sub
    {
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->twitch }
        )
    }
);


my $debug = 0;

sub debug { my $msg = shift; say "[TWITCH DEBUG] $msg" if $debug }


sub twitchGet {
    my $self = shift;
    my $twitch  = $self->db->get('twitch') || {};

    return $twitch;
}


sub twitchSet {
    my ($self, $twitch) = @_;
    return $self->db->set('twitch', $twitch);
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

    if (!@args) {
        $self->discord->send_message($msg->{channel_id}, $self->usage);
        return;
    }

    if ($arg =~ /^a(dd)?$/ && $streamer)           { $self->add_streamer($discord, $channel, $msg, $streamer, $config);  return }
    if ($arg =~ /^d(el(ete)?)?$/ && $streamer)     { $self->del_streamer($discord, $channel, $msg, $streamer, $config);  return }
    if ($arg =~ /^l(ist)?$/)                       { $self->list_streamers($discord, $channel, $msg); return }
    if ($arg =~ /^t(ag)?$/ && $streamer)           { $self->tag($discord, $channel, $msg, $streamer);  return }
    if ($args =~ /^r(efresh)?$/)                   { $discord->delete_message($msg->{'channel_id'}, $msg->{'id'}); $self->twitch(); return }

    $self->discord->send_message($msg->{channel_id}, $self->usage);
}


sub twitch {
    my $self    = shift;
    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'twitch'};

    my $twitch  = $self->twitchGet();
    my @streams = ref $twitch eq 'HASH' ? keys %$twitch : ();

    for my $streamer (@streams) {
        my $topic = $self->getStream($streamer, $config);
        debug "ONLINE: $streamer - $topic" if $topic;

        if ($topic) {
            $self->stream_online($discord, $config, $streamer, $topic, $twitch);
        } else {
            $self->stream_offline($discord, $config, $streamer, $twitch);
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

        $self->send_streamer_message($discord, $config, $streamer, $topic, $twitch);
    }

    $twitch->{$streamer}{'topic'} = $topic;
    $self->twitchSet($twitch);
}


sub stream_offline {
    my ($self, $discord, $config, $streamer, $twitch) = @_;

    if ($twitch->{$streamer}{'msgID'}) {
        $discord->delete_message($config->{'channel'}, $twitch->{$streamer}{'msgID'});
        delete $twitch->{$streamer}{'msgID'};
        delete $twitch->{$streamer}{'topic'};
        $self->twitchSet($twitch);
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
                    'url'   => $self->getProfile($streamer),
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
    $discord->send_message($config->{'channel'}, $embed, sub { $twitch->{$streamer}{'msgID'} = shift->{'id'}; $self->twitchSet($twitch) } );
}


sub add_streamer {
    my ($self, $discord, $channel, $msg, $streamer, $config) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "The streamer `$streamer` is not valid.");
        return;
    }

    my $twitch  = $self->twitchGet();
    my @streams = ref $twitch eq 'HASH' ? keys %$twitch : ();

    # Check to see if stream already exists.
    for my $s (@streams) {
        if ($streamer eq $s) {
            $discord->send_message($channel, "Streamer `$streamer` is already in Twitch alerts list.");
            $self->bot->react_error($channel, $msg->{'id'});
            return;
        }
    }

    unless ( $self->validChannel($streamer) ) {
        $discord->send_message($channel, "Streamer `$streamer` is not a valid.");
        $self->bot->react_error($channel, $msg->{'id'});
        return;
    }

    $twitch->{$streamer} = {};
    $self->twitchSet($twitch);

    $discord->send_message($channel, "Added `$streamer` to Twitch alerts list.");
    $self->bot->react_robot($channel, $msg->{'id'});
    $self->twitch();
}


sub del_streamer {
    my ($self, $discord, $channel, $msg, $streamer, $config) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "The streamer `$streamer` is not valid.");
        $self->bot->react_error($channel, $msg->{'id'});
        return;
    }

    my $twitch  = $self->twitchGet();
    my @streams = keys %$twitch;

    for my $s (@streams) {
        if ($streamer eq $s) {
            # Clean up the message associated with the streamer
            if ($twitch->{$streamer}{'msgID'}) {
                $discord->delete_message($config->{'channel'}, $twitch->{$streamer}{'msgID'});
            }

            # Delete the streamer from the list
            delete $twitch->{$streamer};
            $self->twitchSet($twitch);
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
    my $twitch  = $self->twitchGet();
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
    my $twitch    = $self->twitchGet();
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
            $self->twitchSet($twitch);
        } else {
            $twitch->{$streamer}{'tags'}{$uID} = 1;
            $discord->send_message($channel, "<\@$uID> Twitch tagging added for `$streamer`.");
            $self->twitchSet($twitch);
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
    my $oauth_token = $self->get_or_generate_oauth_token($config);

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
            return 1;
        }
    } else {
        $self->handle_error($res, $config, $streamer);
    }

    return 0;
}


sub getStream {
    my ($self, $stream, $config) = @_;

    my $oauth_token = $self->get_or_generate_oauth_token($config);

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
        $self->handle_error($res, $config, $stream);
        return 0;
    }
}


sub get_or_generate_oauth_token {
    my ($self, $config) = @_;

    my $token = ${ $self->db->get('twitch.oauth') } || undef;

    # Generate new token if missing or empty
    unless ($token) {
        debug "No valid OAuth token found, generating new one.";
        my $new_token = $self->generate_oauth_token($config);
        if ($new_token) {
            $self->db->set('twitch.oauth', \$new_token);
            $token = $new_token;
        } else {
            say "[TWITCH DEBUG] Failed to generate OAuth token: get_or_generate_oauth_token().";
        }
    }

    return $token;
}


sub generate_oauth_token {
    my ($self, $config) = @_;
    debug "Generating new OAuth token.";

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

    say "[TWITCH DEBUG] Failed to generate OAuth token: " . $res->status_line . " generate_oauth_token().";

    return undef;
}


sub handle_error {
    my ($self, $res, $config, $stream) = @_;

    if ($res->code == 401) {
        say "[TWITCH DEBUG] Invalid OAuth token.";

        my $oauth_token = $self->generate_oauth_token($config);
        if ($oauth_token) {
            return $self->getStream($stream, $config);
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

    my $oauth_token = $self->get_or_generate_oauth_token($config);

    my $url = "https://api.twitch.tv/helix/users?login=$streamer";
    my $ua = LWP::UserAgent->new;

    my $res = $ua->get($url,
        'Client-ID'     => $config->{client_id},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        if (ref $json->{data} eq 'ARRAY' && @{ $json->{data} }) {
            return $json->{data}[0]{profile_image_url};
        }
    } else {
        say "[TWITCH DEBUG] Failed to get profile for $streamer: " . $res->status_line . " " . $res->content . " getProfile().";
        $self->handle_error($res, $config, $streamer);
    }

    return 0;
}


1;