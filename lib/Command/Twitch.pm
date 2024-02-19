package Command::Twitch;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use JSON;
use Data::Dumper;
use Date::Parse;

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
        Mojo::IOLoop->recurring( $self->timer_seconds => sub {$self->twitch; }
        ) 
    }
);


my $debug = 0;
my $agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3';


sub debug { my $msg = shift; say $msg if $debug == 1 }

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
    

    my ($arg, $streamer) = @args;
    my @cmd = ($discord, $channel, $msg, $streamer, $config);

    if ($arg =~ /^a(dd)?$/ && $streamer)           { addT(@cmd);  return }
    if ($arg =~ /^d(el(ete)?)?$/ and $streamer)    { delT(@cmd);  return }
    if ($arg =~ /^l(ist)?$/)                       { listT(@cmd); return }
    if ($arg =~ /^t(ag)?$/ && $streamer)           { tagT(@cmd);  return }
    if ($args =~ /^h(elp)?$/)                      { help(@cmd);  return}
    if ($args =~ /^r(efresh)?$/) {
        $discord->delete_message($msg->{'channel_id'}, $msg->{'id'});
        twitch(@_) 
    }
}


sub twitch {
    my $self    = shift;
    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'twitch'};

    $self->discord->get_channel_messages($config->{'channel'},
        sub {
            my $channelMessages = shift;
            my $messages = format_messages($channelMessages);

            my @streams = getStreams();
            for my $streamer (@streams) {
                my $topic = getStream($streamer, $config);
                debug "ONLINE: $streamer - $topic" if $topic;

                if ($topic) {
                    update_or_send_message($discord, $config, $messages, $streamer, $topic);
                } else {
                    handle_offline_streamer($discord, $config, $messages, $streamer);
                }
            }
        }
    );
}


sub format_messages {
    my ($channelMessages) = @_;
    my %formatted_messages;
    
    foreach my $msg (@{$channelMessages}) {
        my $embeds = $msg->{'embeds'};
        next unless $embeds && ref($embeds) eq 'ARRAY';

        foreach my $embed (@$embeds) {
            my $author_name = $embed->{'author'}{'name'};
            $formatted_messages{$author_name} =
            {
                'id'          => $msg->{'id'},
                'old_topic'   => $embed->{'fields'}[0]{'value'},
                'last_update' => $embed->{'fields'}[2]{'value'},
            };
        }
    }

    return \%formatted_messages;
}


sub update_or_send_message {
    my ($discord, $config, $messages, $streamer, $topic) = @_;

    if ($messages->{$streamer}{'id'}) {
        $discord->get_message($config->{'channel'}, $messages->{$streamer}{'id'},
            sub {
                my $oldmsg = shift;

                if ($messages->{$streamer}{'old_topic'} && $topic ne $messages->{$streamer}{'old_topic'}) {
                    debug "TOPIC CHANGED: $streamer - $topic";
                    $oldmsg->{'embeds'}[0]{'fields'}[0]{'value'} = $topic;
                    $discord->edit_message($config->{'channel'}, $messages->{$streamer}{'id'}, $oldmsg);
                }

                $oldmsg->{'embeds'}[0]{'fields'}[2]{'value'} = localtime;
                $discord->edit_message($config->{'channel'}, $messages->{$streamer}{'id'}, $oldmsg);
            }
        );
    } else {
        sendMessage($discord, $config, $streamer, $topic);
    }
}


sub handle_offline_streamer {
    my ($discord, $config, $messages, $streamer) = @_;

    if ($messages->{$streamer}{'id'}) {
        my $message = $discord->get_message($config->{'channel'}, getMessageID($streamer),
            sub {
                my $message = shift;
                my $last_update = str2time($message->{'embeds'}[0]{'fields'}[2]{'value'});
                if (defined $last_update && $last_update > 0 && (time() - $last_update) > 180) {
                    $discord->delete_message($config->{'channel'}, $messages->{$streamer}{'id'});
                    setMessage($streamer, 0);
                }
            }
        );
    }
}


sub sendMessage {
    my ($discord, $config, $streamer, $topic) = @_;

    # If last online record exists and it's less than 10 mins ago then probably stream crashed.
    my $msg;
    my $laston = getLaston($streamer);

    if (defined $laston && $laston > 0 && (time() - $laston) < 600) {
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

    
    my $tag = getTag($streamer);
    my @tags;
    if ($tag) {
        @tags = split ',', $tag;
        @tags = map { '<@' . $_ . '>' } @tags;
        push @{ $embed->{'embeds'}[0]{'fields'} }, { 'name'  => 'Alerting:', 'value' => join ' ', @tags };

        for (@tags) {
            s/\D//g;
            $discord->send_dm($_, $embed);
        }
    }

    $discord->send_message($config->{'channel'}, $embed,
        sub {
            my $id = shift->{'id'};
            my $db = Component::DBI->new();

            $db->dbh->do("UPDATE twitch SET message = ? WHERE streamer = ?", undef, $id, $streamer);
        }
    );

    setLaston($streamer);    
}


sub addT {
    my ($discord, $channel, $msg, $streamer) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "$streamer is not valid channel.");
        return;            
    }

    # Check to see if stream already exists.
    my @streams = getStreams();

    for my $s (@streams) {
        if ($streamer eq $s) {
            $discord->send_message($channel, "$streamer is already in Twitch alerts list.");
            return;
        }
    }

    # Make sure the streamer is valid.
    unless ( validChannel($streamer) ) {
        $discord->send_message($channel, "$streamer is not valid channel.");
        return;
    }

    addStreamer($streamer);

    # Confirm is has been added successfully.
    @streams = getStreams();
    for my $s (@streams) {
        if ($streamer eq $s) {
        $discord->send_message($channel, "Added $streamer to Twitch alerts list.");
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
        
        return;
        }
    }

    $discord->send_message($channel, "Couldn't add $streamer.");
}


sub delT {
    my ($discord, $channel, $msg, $streamer, $config) = @_;

    unless ($streamer =~ /^\w+$/i) {
        $discord->send_message($channel, "$streamer is not a valid channel.");
        return;
    }

    my @streams = getStreams();

    for my $s (@streams) {
        if ($streamer eq $s) {
            # Clean up the message associated with the streamer
            cleanUpMessage($discord, $config, $streamer);

            # Delete the streamer from the list
            delStreamer($streamer);
            $discord->send_message($channel, "Deleted $streamer from Twitch alerts list.");
            return;
        }
    }

    $discord->send_message($channel, "$streamer is not in the Twitch alerts list.");
}


sub cleanUpMessage {
    my ($discord, $config, $streamer) = @_;

    # Get the message ID associated with the streamer
    my $message_id = getMessageID($streamer);

    if ($message_id) {
        # Delete the message from the Discord channel
        $discord->delete_message($config->{'channel'}, $message_id);
        
        # Update the database to remove the message ID
        setMessage($streamer, 0);

        return 1;  # Deleted successfully
    }

    return 0;  # No message found for the streamer
}


sub listT {
    my ($discord, $channel, $msg, $streamer) = @_;
    my @streams  = getStreams();

    if (!@streams) {
        $discord->send_message($channel, "No streams in Twitch alerts list.");
        return;
    }

    # Join all the streamers we have tagging enabled for.
    $discord->send_message($channel, "Twitch alerts enabled for: " . join ', ', sort @streams);
    $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
}


sub tagT {
    my ($discord, $channel, $msg, $streamer) = @_;       
    my $userid = $msg->{'author'}->{'id'}; 
    my @streams = getStreams();
    my %streamers = map { $_ => 1 } @streams;

    if (exists $streamers{$streamer}) {
        my $tag = getTag($streamer);
        my @tags;
        if ($tag) {
            @tags = split ',', $tag;
        }
        my %tags = map { $_ => 1 } @tags;

        if (exists $tags{$userid}) {
            delete $tags{$userid};
            setTag($streamer, join ',', map { $_ } keys %tags);
            $discord->send_message($channel, "<\@$userid> Twitch tagging removed for '**$streamer**'.");
        } else {
            push @tags, $userid;
            setTag($streamer, join ',', @tags);
    
            $discord->send_message($channel, "<\@$userid> Twitch tagging added for '**$streamer**'.");

        }

        return;
    } else {
        $discord->send_message($channel, "<\@$userid> '**$streamer**' is not a valid streamer.");
    }


    if ($streamer =~ /^l(ist)?$/) {
        $discord->send_message($channel, "$userid you have tagging enabled for: $streamer");
        $discord->send_message($channel, "$userid you don't have tagging enabled for anybody.");
    }
}


sub validChannel {
    my $streamer = shift;
    my $res = getTwitch($streamer);

    debug $res->status_line;

    if ($res->is_success && $res->decoded_content =~ /meta property="og:type" content="video.other"/) {
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

    my $oauth_token;

    if (-e 'twitch.oauth') {
        open my $fh, '<', 'twitch.oauth' or die "Could not open file 'twitch.oauth' $!";
        ($oauth_token = <$fh> // '');
        close $fh;
    } else {
        debug "No OAuth token found. Generating a new file.";
        open my $fh, '>', 'twitch.oauth' or die "Could not open file 'twitch.oauth' $!";
        close $fh;
    }

    unless ($oauth_token) {
        $oauth_token = generate_oauth_token($config);
        save_oauth_token($oauth_token);
    }

    return $oauth_token;
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

    say "Failed to generate OAuth token: " . $res->status_line;

    return undef;
}


sub save_oauth_token {
    my ($oauth_token) = @_;
    open my $fh, '>', 'twitch.oauth' or die "Could not open file 'twitch.oauth' $!";
    print $fh $oauth_token;
    close $fh;
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


sub addStreamer {
    my $streamer = shift;
    my $db = Component::DBI->new();
    $db->dbh->do("INSERT INTO twitch (streamer) VALUES (?)", undef, $streamer);
}


sub delStreamer {
    my $streamer = shift;
    my $db = Component::DBI->new();
    $db->dbh->do("DELETE FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub getStreams {
    my $db = Component::DBI->new();
    my $streamers = $db->dbh->selectcol_arrayref("SELECT streamer FROM twitch");

    return @{ $streamers };
}


sub getMessageID {
    my $streamer = shift;
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT message FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub setMessage {
    my ($streamer, $message) = shift;
    my $db = Component::DBI->new();
    $db->dbh->do("UPDATE twitch SET message = ? WHERE streamer = ?", undef, $message, $streamer);
}


sub getLaston {
    my $streamer = shift;
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT laston FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub setLaston {
    my $streamer = shift;
    my $db = Component::DBI->new();
    my $time = time;
    $db->dbh->do("UPDATE twitch SET laston = ? WHERE streamer = ?", undef, $time, $streamer);
}

sub getTag {
    my ($streamer) = @_;
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT tag FROM twitch WHERE streamer = ?", undef, $streamer);
}


sub setTag {
    my ($streamer, $tag) = @_;
    my $db = Component::DBI->new();
    $db->dbh->do("UPDATE twitch SET tag = ? WHERE streamer = ?", undef, $tag, $streamer);
    #setT((@_, 'tag'));
}


sub setT {
    my $db = Component::DBI->new();
    my @sql = reverse @_;
    $db->dbh->do("UPDATE twitch SET ? = ? WHERE streamer = ?", undef, @sql);   
}


sub getT {
    my $db = Component::DBI->new();
    return $db->dbh->selectrow_array("SELECT tag FROM twitch WHERE streamer = ?", undef, shift);
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

1;
