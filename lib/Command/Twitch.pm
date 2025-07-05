package Command::Twitch;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use JSON;
use Date::Parse;
use Time::Seconds;
use POSIX qw(strftime);
use Encode;

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
has pattern             => ( is => 'ro',    default => '^tw(itch)? ?' );
has function            => ( is => 'ro',    default => sub { \&cmd_twitch } );
has usage               => ( is => 'ro',    default => <<~'EOF'
    **Twitch Alerts Command Help**

    This command allows you to manage Twitch streamer alerts.
    When a streamer goes live, the bot will post a notification in the configured channel.
    Command shortcut: !tw

    `!twitch (a)dd <streamer(s)>`
    Adds a Twitch streamer to the alert list.

    `!twitch (d)el)ete <streamer(s)>`
    Removes a Twitch streamer from the alert list.

    `!twitch (l)ist`
    Displays all streamers currently being monitored.

    `!twitch (t)ag <streamer(s)>`
    Toggles personal DM alerts for a specific streamer.

    `!twitch (p)laying <game_name>`
    Shows which monitored streamers are currently playing a specific game.

    `!twitch (i)nfo <streamer>`
    Displays information about a Twitch channel.

    `!twitch (c)lips <streamer> [--period=<day|week|month|all>]`
    Fetches the top clip for a streamer.

    `!twitch (s)tats`
    Displays detailed statistics for all monitored channels.

    `!twitch (r)efresh`
    Manually triggers an immediate check for all monitored streamers.

    `!twitch (h)elp`
    Displays this detailed help message.
    EOF
);


has timer_sub => ( is => 'ro', default => sub
    {
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->twitch_loop } )
    }
);


my $debug = 0;
sub debug { my $msg = shift; say "[TWITCH DEBUG] $msg" if $debug }

sub BUILD { shift->twitch_loop }

sub cmd_twitch {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args_str = lc $msg->{'content'};
       $args_str =~ s/$pattern//i;
    
    # Replace commas with spaces to allow for comma-separated lists
    $args_str =~ s/,/ /g;

    my @args = split /\s+/, $args_str;
    my $config = $self->{'bot'}{'config'}{'twitch'};
    
    my $arg = shift @args || '';
    my $value = join ' ', @args; # The rest of the command is the value

    if ($arg =~ /^(a|add)$/ && @args) {
        $self->add_streamer($discord, $channel, $msg, \@args, $config);
    } elsif ($arg =~ /^(d|del|delete)$/ && @args) {
        $self->del_streamer($discord, $channel, $msg, \@args, $config);
    } elsif ($arg =~ /^(l|list)$/) {
        $self->list_streamers($discord, $channel, $msg);
    } elsif ($arg =~ /^(t|tag)$/ && @args) {
        $self->tag($discord, $channel, $msg, \@args);
    } elsif ($arg =~ /^(i|info)$/ && $value) {
        $self->channel_info($discord, $channel, $msg, $value);
    } elsif ($arg =~ /^(c|clips)$/ && @args) {
        $self->top_clips($discord, $channel, $msg, \@args);
    } elsif ($arg =~ /^(p|playing)$/ && $value) {
        $self->whos_playing($discord, $channel, $msg, $value);
    } elsif ($arg =~ /^(s|stats)$/) {
        $self->twitch_stats($discord, $channel, $msg);
    } elsif ($arg =~ /^(r|refresh)$/) {
        $self->bot->react_robot($channel, $msg->{'id'});
        $self->twitch_loop();
    } elsif ($arg =~ /^(h|help)$/ || !$arg) {
        $self->discord->send_message($msg->{channel_id}, $self->usage);
    } else {
        $self->discord->send_message($msg->{channel_id}, "Unknown command: `$arg $value`. " . $self->usage);
        $self->bot->react_error($channel, $msg->{'id'});
    }
}


sub twitch_loop {
    my $self   = shift;
    my $config = $self->{'bot'}{'config'}{'twitch'};
    my $twitch = $self->twitchGet();
    
    # Get the list of all streamers we are monitoring.
    my @all_monitored_streamers = keys %$twitch;
    return unless @all_monitored_streamers;
    debug("Starting Twitch loop for: " . join(', ', @all_monitored_streamers));

    # Fetch the status for all monitored streamers in a single API call.
    $self->get_live_streams(\@all_monitored_streamers, sub {
        my $live_streams_list = shift;

        # Create a hash of live streamers for easy lookup (lowercase for case-insensitivity).
        my %live_streams_hash = map { lc($_->{user_login}) => $_ } @$live_streams_list;

        for my $streamer_login (map { lc } @all_monitored_streamers) {
            
            # Check if the streamer is in the hash of live streams.
            if (my $stream_info = $live_streams_hash{$streamer_login}) {
                # If they are live, process them with stream_online.
                $self->stream_online($self->discord, $config, $streamer_login, $stream_info, $twitch);
            } else {
                # If they are not in the live hash, they are offline.
                $self->stream_offline($self->discord, $config, $streamer_login, $twitch);
            }
        }
    });
}

sub stream_online {
    my ($self, $discord, $config, $streamer, $stream_info, $twitch) = @_;
    
    my $topic = $stream_info->{title} || 'No title provided';
    my $game  = $stream_info->{game_name}  || 'N/A';

    # Crucial: Explicitly decode the topic as UTF-8.
    # This ensures the string is properly flagged as a Perl Unicode string
    # before it's used in the embed structure for Discord.
    $topic = Encode::decode_utf8($topic, Encode::FB_CROAK);


    # Check if a message for this stream already exists in our database.
    if (my $msgID = $twitch->{$streamer}{'msgID'}) {
        # The streamer is already marked as online. Check if game or title has changed.
        if (($twitch->{$streamer}{'topic'} // '') ne $topic || ($twitch->{$streamer}{'game'} // '') ne $game) {
            
            debug "INFO CHANGED: $streamer - $topic - $game";

            $discord->get_message($config->{'channel'}, $msgID, sub {
                my $msg = shift;

                if (ref $msg eq 'HASH' && ref $msg->{embeds}[0] eq 'HASH' && ref $msg->{embeds}[0]{fields} eq 'ARRAY') {
                    $msg->{'embeds'}[0]{'fields'}[0]{'value'} = $topic;
                    $msg->{'embeds'}[0]{'fields'}[1]{'value'} = $game;
                    $msg->{'embeds'}[0]{'fields'}[3]{'value'} = strftime "%-I:%M:%S %p", localtime;
                    
                    $discord->edit_message($config->{'channel'}, $msgID, $msg);
                }
            });
        }
    } else {
        # The streamer does not have an active message, so they just came online.
        # First, determine if this is a genuinely new session or a recovery from a crash.
        my $is_new_session = 1; # Assume it's a new session by default.
        if (my $last_offline = $twitch->{$streamer}{'last_seen_offline'}) {
            # If seen offline less than 10 minutes (600 seconds) ago, it's a crash recovery.
            if ((time - $last_offline) < 600) {
                $is_new_session = 0;
                debug("Streamer $streamer recovered from a likely crash.");
            }
        }

        if ($is_new_session) {
            # This is a new session, so the previous one has definitively ended.
            # We can now calculate and store the duration of that last session.
            if (my $start_epoch = $twitch->{$streamer}{'online_at_epoch'}) {
                if (my $end_epoch = $twitch->{$streamer}{'last_seen_offline'}) {
                    my $duration_seconds = $end_epoch - $start_epoch;
                    $twitch->{$streamer}{'last_stream_duration'} = $duration_seconds > 0 ? $duration_seconds : 0;
                    debug("Calculated last stream duration for $streamer: $duration_seconds seconds.");
                }
            }
            # Since it's a new session, we must clear the old start time before setting a new one.
            delete $twitch->{$streamer}{'online_at_epoch'}; 
        }

        # Set the session start time only if one doesn't already exist.
        # This is key to preserving the original start time across crash recoveries.
        unless (exists $twitch->{$streamer}{'online_at_epoch'}) {
            debug("Setting new session start time for $streamer.");
            $twitch->{$streamer}{'online_at_epoch'} = str2time($stream_info->{started_at});
        }
        
        # Now, send the live notification message to Discord.
        $self->send_streamer_message($discord, $config, $streamer, $stream_info, $twitch);
    }
    
    # Always update the latest info and timestamp.
    $twitch->{$streamer}{'topic'} = $topic;
    $twitch->{$streamer}{'game'}  = $game;
    $twitch->{$streamer}{'last_seen_online'} = time; 
    $self->twitchSet($twitch);
}


sub stream_offline {
    my ($self, $discord, $config, $streamer, $twitch) = @_;

    # Check if we have a message ID, which indicates the bot thought the streamer was online.
    if ($twitch->{$streamer}{'msgID'}) {
        debug("Streamer $streamer appears to be offline.");
        
        # Record the exact time the streamer went offline. This will be used
        # to detect crash-restarts and as the end-time for the session duration.
        $twitch->{$streamer}{'last_seen_offline'} = time;

        # Delete the live notification message from the Discord channel.
        $discord->delete_message($config->{'channel'}, $twitch->{$streamer}{'msgID'});
        
        # Clear the transient data for the stream. We keep 'online_at_epoch' 
        # to calculate final duration later, and 'last_seen_offline' to detect crashes.
        delete $twitch->{$streamer}{'msgID'};
        delete $twitch->{$streamer}{'topic'};
        delete $twitch->{$streamer}{'game'};
        
        # Save the updated state to the database.
        $self->twitchSet($twitch);
    }
}


# In lib/Command/Twitch.pm

sub send_streamer_message {
    my ($self, $discord, $config, $streamer, $stream_info, $twitch) = @_;
    my $topic = $stream_info->{title};
    my $game  = $stream_info->{game_name} || 'N/A'; # Corrected from 'game' to 'game_name'
    $topic = Encode::decode_utf8($topic, Encode::FB_CROAK);

    my $msg;
    # Check if the streamer was last seen offline very recently to customize the message.
    if ($twitch->{$streamer}{'last_seen_offline'} && (time() - $twitch->{$streamer}{'last_seen_offline'}) < 600) {
        $msg = "Streamer `$streamer` is back online (from a probable stream crash).";
    } else {
        $msg = "Streamer `$streamer` is online.";
    }
    
    # Get the human-readable start time from the API response, formatted to AM/PM.
    my $online_since_time = strftime "%-I:%M %p", localtime(str2time($stream_info->{started_at}));

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
                    { 'name' => 'Title:', 'value' => $topic },
                    { 'name' => 'Activity:', 'value' => $game },
                    { 'name' => 'Online Since:', 'value' => $online_since_time },
                    { 'name' => 'Last Update:', 'value' => strftime("%-I:%M %p", localtime) },
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

    # Send the message and in the callback, save the new message ID to the database.
    $discord->send_message($config->{'channel'}, $embed, sub { 
        $twitch->{$streamer}{'msgID'} = shift->{'id'}; 
        $self->twitchSet($twitch);
    });
}


sub add_streamer {
    my ($self, $discord, $channel, $msg, $streamers_ref, $config) = @_;

    my @streamers_to_add = @{$streamers_ref};
    my $twitch_data      = $self->twitchGet();
    
    my @added;
    my @already_exist;
    my @invalid;

    for my $streamer (@streamers_to_add) {
        # Twitch usernames are 4-25 alphanumeric characters.
        unless ($streamer =~ /^\w{4,25}$/i) {
            push @invalid, "`$streamer` (invalid format)";
            next;
        }

        # Check if the streamer is already in our list (case-insensitive).
        if (exists $twitch_data->{lc($streamer)}) {
            push @already_exist, "`$streamer`";
            next;
        }

        # Check if the streamer exists on Twitch via API.
        if ($self->validChannel($streamer)) {
            $twitch_data->{lc($streamer)} = {};
            push @added, "`$streamer`";
        } else {
            push @invalid, "`$streamer` (not found on Twitch)";
        }
    }

    # Construct a comprehensive response message for the user.
    my $response = "";
    $response .= "✅ Added: " . join(', ', @added) . "\n" if @added;
    $response .= "👍 Already in list: " . join(', ', @already_exist) . "\n" if @already_exist;
    $response .= "❌ Failed to add: " . join(', ', @invalid) . "\n" if @invalid;
    
    unless ($response) {
        $response = "No streamers were provided to add.";
    }

    $discord->send_message($channel, $response);

    # If we successfully added new streamers, save to DB and trigger an update loop.
    if (@added) {
        $self->twitchSet($twitch_data);
        $self->bot->react_robot($channel, $msg->{'id'});
        $self->twitch_loop();
    } else {
        # If nothing was added, it's likely an error or all existed already.
        $self->bot->react_error($channel, $msg->{'id'});
    }
}


sub del_streamer {
    my ($self, $discord, $channel, $msg, $streamers_ref, $config) = @_;

    my @streamers_to_del = @{$streamers_ref};
    my $twitch_data      = $self->twitchGet();

    my @deleted;
    my @not_found;

    for my $streamer (@streamers_to_del) {
        my $lc_streamer = lc($streamer);

        if (exists $twitch_data->{$lc_streamer}) {
            # If a message ID exists for this streamer, delete the Discord message.
            if ($twitch_data->{$lc_streamer}{'msgID'}) {
                $discord->delete_message($config->{'channel'}, $twitch_data->{$lc_streamer}{'msgID'});
            }

            delete $twitch_data->{$lc_streamer};
            push @deleted, "`$streamer`";
        } else {
            push @not_found, "`$streamer`";
        }
    }

    my $response = "";
    $response .= "🗑️ Deleted: " . join(', ', @deleted) . "\n" if @deleted;
    $response .= "❓ Not found: " . join(', ', @not_found) . "\n" if @not_found;

    unless ($response) {
        $response = "No streamers were provided to delete.";
    }

    $discord->send_message($channel, $response);

    if (@deleted) {
        $self->twitchSet($twitch_data);
        $self->bot->react_robot($channel, $msg->{'id'});
    } else {
        $self->bot->react_error($channel, $msg->{'id'});
    }
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
    my ($self, $discord, $channel, $msg, $streamers_ref) = @_;
    my @streamer_names = @{$streamers_ref};
    my $uID            = $msg->{'author'}->{'id'};
    my $twitch_data    = $self->twitchGet();

    # Handle the special 'list' subcommand.
    if (@streamer_names == 1 && $streamer_names[0] =~ /^l(ist)?$/) {
        my @tagged_for_user;
        for my $streamer (keys %$twitch_data) {
            if ($twitch_data->{$streamer}{'tags'}{$uID}) {
                push @tagged_for_user, "`$streamer`";
            }
        }
        
        my $response = @tagged_for_user
            ? "<\@$uID> you have tagging enabled for: " . join(', ', sort @tagged_for_user)
            : "<\@$uID> you don't have tagging enabled for any streamers.";
        
        $discord->send_message($channel, $response);
        $self->bot->react_robot($channel, $msg->{'id'});
        return;
    }

    my @tagged;
    my @untagged;
    my @not_found;

    for my $streamer (@streamer_names) {
        my $lc_streamer = lc($streamer);

        if (exists $twitch_data->{$lc_streamer}) {
            # Toggle the tag status for the user.
            if (exists $twitch_data->{$lc_streamer}{'tags'}{$uID}) {
                delete $twitch_data->{$lc_streamer}{'tags'}{$uID};
                push @untagged, "`$streamer`";
            } else {
                $twitch_data->{$lc_streamer}{'tags'}{$uID} = 1;
                push @tagged, "`$streamer`";
            }
        } else {
            push @not_found, "`$streamer`";
        }
    }

    my $response = "Tag summary for <\@$uID>:\n";
    $response .= "🏷️ Tagged: " . join(', ', @tagged) . "\n" if @tagged;
    $response .= "❌ Untagged: " . join(', ', @untagged) . "\n" if @untagged;
    $response .= "❓ Streamer not found: " . join(', ', @not_found) . "\n" if @not_found;

    $discord->send_message($channel, $response);

    if (@tagged || @untagged) {
        $self->twitchSet($twitch_data);
        $self->bot->react_robot($channel, $msg->{'id'});
    } else {
        $self->bot->react_error($channel, $msg->{'id'});
    }
}


sub validChannel {
    my ($self, $streamer) = @_;

    my $config = $self->bot->config->{twitch};
    my $oauth_token = $self->get_or_generate_oauth_token($config);
    return unless $oauth_token; # Stop if no token

    my $url = "https://api.twitch.tv/helix/users?login=$streamer";
    my $ua = LWP::UserAgent->new;

    my $res = $ua->get($url,
        'client-id'     => $config->{client_id},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        if (ref $json->{data} eq 'ARRAY' && @{ $json->{data} }) {
            return 1;
        }
    } else {
        $self->handle_error($res, $config, $streamer);
    }

    return 0;
}


sub get_live_streams {
    my ($self, $streamers_ref, $callback) = @_;
    my $config = $self->bot->config->{twitch};

    my $query_string = join '&', map { "user_login=" . $_ } @$streamers_ref;
    my $url = "https://api.twitch.tv/helix/streams?$query_string";
    
    my $oauth_token = $self->get_or_generate_oauth_token($config);
    return unless $oauth_token; # Stop if no token

    my $ua = LWP::UserAgent->new;

    my $res = $ua->get($url,
        'client-id'     => $config->{'client_id'},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        $callback->($json->{data} || []);
    } else {
        $self->handle_error($res, $config, 'batch request');
        $callback->([]); # Return an empty list on error
    }
}


sub get_or_generate_oauth_token {
    my ($self, $config) = @_;

    my $token = ${ $self->db->get('twitch.oauth') } || undef;

    # If token is invalid (e.g., after a 401 error), we should force a regeneration.
    # This simple implementation just checks for existence.
    unless ($token) {
        debug "No valid OAuth token found, generating new one.";
        my $new_token = $self->generate_oauth_token($config);
        if ($new_token) {
            $self->db->set('twitch.oauth', \$new_token);
            $token = $new_token;
        } else {
            say "[TWITCH FATAL] Failed to generate OAuth token. Module will be non-functional.";
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

    say "[TWITCH ERROR] Failed to generate OAuth token: " . $res->status_line;
    return undef;
}


sub handle_error {
    my ($self, $res, $config, $stream) = @_;

    if ($res->code == 401) {
        say "[TWITCH ERROR] Invalid OAuth token (401). Forcing regeneration.";
        # Clear the bad token from the database to force regeneration on the next call.
        $self->db->del('twitch.oauth');
    } else {
        say "[TWITCH ERROR] Failed to fetch Twitch data for '$stream': " . $res->status_line;
    }
}


sub getProfile {
    my ($self, $streamer) = @_;
    my $config = $self->bot->config->{twitch};

    my $oauth_token = $self->get_or_generate_oauth_token($config);
    return unless $oauth_token;

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
        $self->handle_error($res, $config, $streamer);
    }

    # Return a default placeholder image on failure
    return 'https://static-cdn.jtvnw.net/emoticons/v2/emoticon-301703878/default/dark/3.0';
}


sub channel_info {
    my ($self, $discord, $channel, $msg, $streamer_name) = @_;
    debug("Fetching channel info for '$streamer_name'");

    my $user_info = $self->get_user_info($streamer_name);
    unless ($user_info) {
        return $discord->send_message($channel, "Could not find a Twitch channel named `$streamer_name`.");
    }
    
    my $follower_count = $self->get_follower_count($user_info->{id}) || 'N/A';
    # Format creation date to be more readable
    my $created_date = strftime("%d %b %Y", localtime(str2time($user_info->{created_at})));

    my $embed = {
        'embeds' => [
            {
                'author' => {
                    'name'     => "Channel Info for $user_info->{display_name}",
                    'url'      => "https://www.twitch.tv/$user_info->{login}",
                    'icon_url' => $user_info->{profile_image_url},
                },
                'thumbnail' => {
                    'url' => $user_info->{profile_image_url},
                },
                'description' => $user_info->{description} || 'No bio provided.',
                'color'       => 48491,
                'fields'      => [
                    { 'name' => 'Followers', 'value' => $follower_count, 'inline' => \1 },
                    { 'name' => 'User ID', 'value' => $user_info->{id}, 'inline' => \1 },
                    { 'name' => 'Account Created', 'value' => $created_date, 'inline' => \1 },
                ],
            }
        ]
    };

    $discord->send_message($channel, $embed);
    $self->bot->react_robot($channel, $msg->{'id'});
}


sub top_clips {
    my ($self, $discord, $channel, $msg, $args_ref) = @_;
    my $streamer_name = shift @$args_ref;
    
    my $period = 'week'; 
    if (grep {/--period=/} @$args_ref) {
        my ($p) = grep {/--period=/} @$args_ref;
        ($period) = $p =~ /--period=(\w+)/;
    }

    debug("Fetching top clips for '$streamer_name' for period '$period'");
    
    my $user_info = $self->get_user_info($streamer_name);
    unless ($user_info) {
        return $discord->send_message($channel, "Could not find a Twitch channel named `$streamer_name`.");
    }

    my $clip = $self->get_top_clip($user_info->{id}, $period);
    unless ($clip) {
        return $discord->send_message($channel, "Could not find any clips for `$streamer_name` in the last '$period'.");
    }

    $discord->send_message($channel, "Top clip for `$streamer_name` from the last '$period':\n$clip->{url}");
    $self->bot->react_robot($channel, $msg->{'id'});
}


sub get_user_info {
    my ($self, $streamer_name) = @_;
    my $config = $self->bot->config->{twitch};
    my $oauth_token = $self->get_or_generate_oauth_token($config);
    return unless $oauth_token;

    my $url = "https://api.twitch.tv/helix/users?login=$streamer_name";
    
    my $ua = LWP::UserAgent->new;
    my $res = $ua->get($url,
        'client-id'     => $config->{client_id},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        return $json->{data}[0] if ($json->{data} && @{$json->{data}});
    }
    return;
}


sub get_follower_count {
    my ($self, $user_id) = @_;
    my $config = $self->bot->config->{twitch};
    my $oauth_token = $self->get_or_generate_oauth_token($config);
    return unless $oauth_token;

    my $url = "https://api.twitch.tv/helix/channels/followers?broadcaster_id=$user_id";
    
    my $ua = LWP::UserAgent->new;
    my $res = $ua->get($url,
        'client-id'     => $config->{client_id},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        return $json->{total} if exists $json->{total};
    }
    return;
}


sub get_top_clip {
    my ($self, $broadcaster_id, $period) = @_;
    my $config = $self->bot->config->{twitch};
    my $oauth_token = $self->get_or_generate_oauth_token($config);
    return unless $oauth_token;

    my ($start_time, $end_time);
    $end_time = time;
    if ($period eq 'day') {
        $start_time = $end_time - ONE_DAY;
    } elsif ($period eq 'week') {
        $start_time = $end_time - ONE_WEEK;
    } elsif ($period eq 'month') {
        $start_time = $end_time - ONE_MONTH;
    }

    my $url = "https://api.twitch.tv/helix/clips?broadcaster_id=$broadcaster_id";
    $url .= "&started_at=" . strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($start_time)) if $start_time;

    my $ua = LWP::UserAgent->new;
    my $res = $ua->get($url,
        'client-id'     => $config->{client_id},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        if ($json->{data} && @{$json->{data}}) {
            # API can return clips sorted by trending, not necessarily view count. We sort manually.
            my @sorted_clips = sort { $b->{view_count} <=> $a->{view_count} } @{$json->{data}};
            return $sorted_clips[0];
        }
    }
    return;
}


# In lib/Command/Twitch.pm

sub twitch_stats {
    my ($self, $discord, $channel, $msg) = @_;
    my $twitch_data = $self->twitchGet();
    my @monitored_streamers = keys %$twitch_data;

    unless (@monitored_streamers) {
        return $discord->send_message($channel, "Not monitoring any streamers yet.");
    }
    
    $self->get_live_streams(\@monitored_streamers, sub {
        my $live_streams_list = shift;
        my %live_streams_hash = map { lc($_->{user_login}) => $_ } @$live_streams_list;

        my $total_monitored = scalar @monitored_streamers;
        my $total_live = scalar @$live_streams_list;

        my @online_lines;
        my @offline_lines;

        # Categorize and format lines for all streamers, sorted alphabetically
        for my $streamer (sort { lc($a) cmp lc($b) } keys %$twitch_data) {
            if (my $stream_info = $live_streams_hash{lc($streamer)}) {
                # --- Format Online Streamer Line ---
                my $start_time = $twitch_data->{$streamer}{'online_at_epoch'} || str2time($stream_info->{started_at});
                my $duration_string = time_ago($start_time);
                my $line = "🟢 `$streamer`: **$stream_info->{game_name}** for **$duration_string**";
                push @online_lines, $line;
            } else {
                # --- Format Offline Streamer Line ---
                my $offline_status;
                if (my $last_seen = $twitch_data->{$streamer}{'last_seen_offline'}) {
                    $offline_status = "Offline for **" . time_ago($last_seen) . "**.";
                } else {
                    $offline_status = "Currently offline.";
                }
                
                my $duration_info = " No completed streams recorded."; # Default message
                
                # --- Corrected Duration Logic ---
                # Prioritize the pre-calculated duration.
                my $duration_secs = $twitch_data->{$streamer}{'last_stream_duration'};

                # If not set, calculate it on-the-fly for the most recent session.
                unless (defined $duration_secs) {
                    if (my $start_epoch = $twitch_data->{$streamer}{'online_at_epoch'}) {
                        if (my $end_epoch = $twitch_data->{$streamer}{'last_seen_offline'}) {
                            $duration_secs = $end_epoch - $start_epoch;
                        }
                    }
                }
                # --- End Correction ---

                if (defined $duration_secs && $duration_secs > 0) {
                    my $duration_str = Time::Seconds->new($duration_secs)->pretty;
                    $duration_str =~ s/, \d+ seconds//;
                    $duration_info = " Last stream was for **$duration_str**";
                }

                my $line = "🔴 `$streamer`: $offline_status$duration_info";
                push @offline_lines, $line;
            }
        }

        # --- Build the final embed description ---
        my $description = "**$total_live** of **$total_monitored** monitored channels are currently live.";
        
        if (@online_lines) {
            $description .= "\n\n" . join("\n", @online_lines);
        }
        if (@offline_lines) {
            $description .= "\n\n" . join("\n", @offline_lines);
        }

        # --- Build the Monitored & Tags List for the field section ---
        my @tags_list;
        for my $streamer (sort keys %$twitch_data) {
            my $tag_info = "`$streamer`";
            if (exists $twitch_data->{$streamer}{'tags'} && keys %{$twitch_data->{$streamer}{'tags'}}) {
                my @tagged_users = map { "<\@$_>" } keys %{$twitch_data->{$streamer}{'tags'}};
                $tag_info .= ": " . join(', ', @tagged_users);
            }
            push @tags_list, $tag_info;
        }
        my $tags_string = join(", ", @tags_list);
        
        my $embed = {
            'embeds' => [{
                'title'       => 'Twitch Module Statistics',
                'description' => $description,
                'color'       => 48491,
                'fields'      => [
                    { name => '────────── MONITORED CHANNELS & TAGS ──────────', value => $tags_string }
                ],
            }]
        };

        $discord->send_message($channel, $embed);
        $self->bot->react_robot($channel, $msg->{'id'});
    });
}


sub time_ago {
    my ($timestamp) = @_;
    my $seconds = time - $timestamp;

    # Return 'just now' for very recent events to avoid '0 seconds'
    return 'just now' if $seconds < 1;

    my $time = Time::Seconds->new($seconds);
    my $string = $time->pretty;
    
    # Clean up the pretty string for a more concise look
    $string =~ s/, \d+ seconds//;
    return $string;
}


sub twitchGet {
    my $self = shift;
    my $twitch  = $self->db->get('twitch') || {};

    return $twitch;
}


sub twitchSet {
    my ($self, $twitch) = @_;
    return $self->db->set('twitch', $twitch);
}


1;