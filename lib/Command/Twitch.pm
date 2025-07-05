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
has pattern             => ( is => 'ro',    default => '^tw(itch)? ?' );
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
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->twitch_loop }
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
    my $args_str = lc $msg->{'content'};
       $args_str =~ s/$pattern//i;
    
    # Replace all commas with spaces to handle both delimiters.
    $args_str =~ s/,/ /g;

    # Now split the normalized string into arguments.
    my @args = split /\s+/, $args_str;
    my $config = $self->{'bot'}{'config'}{'twitch'};
    
    my $arg = shift @args || '';

    if ($arg =~ /^(a|add)$/ && @args) {
        $self->add_streamer($discord, $channel, $msg, \@args, $config);
    } elsif ($arg =~ /^(d|del|delete|remove)$/ && @args) {
        $self->del_streamer($discord, $channel, $msg, \@args, $config);
    } elsif ($arg =~ /^(l|list)$/) {
        $self->list_streamers($discord, $channel, $msg);
    } elsif ($arg =~ /^(t|tag)$/ && @args) {
        $self->tag($discord, $channel, $msg, \@args);
    } elsif ($arg =~ /^(r|refresh)$/) {
        $self->bot->react_robot($channel, $msg->{'id'});
        $self->twitch_loop();
    } elsif ($arg =~ /^(h|help)$/ || !$arg) {
        $self->discord->send_message($msg->{channel_id}, $self->usage);
    } else {
        my $value = join ' ', @args;
        $self->discord->send_message($msg->{channel_id}, "Unknown command: `$arg$value`. " . $self->usage);
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

    # Fetch the status for all monitored streamers in a single API call.
    $self->get_live_streams(\@all_monitored_streamers, sub {
        my $live_streams_list = shift;

        # Create a hash of live streamers for easy lookup.
        # The key is the streamer's login name, and the value is their stream data.
        my %live_streams_hash = map { lc($_->{user_login}) => $_ } @$live_streams_list;

        for my $streamer_login (map { lc } @all_monitored_streamers) {
            
            # Check if the streamer is in the hash of live streams.
            if (my $stream_info = $live_streams_hash{$streamer_login}) {
                # If they are live, process them with stream_online.
                my $info = {
                    title => $stream_info->{title},
                    game  => $stream_info->{game_name},
                };
                $self->stream_online($self->discord, $config, $streamer_login, $info, $twitch);
            } else {
                # If they are not in the live hash, they are offline.
                $self->stream_offline($self->discord, $config, $streamer_login, $twitch);
            }
        }
    });
}


sub stream_online {
    my ($self, $discord, $config, $streamer, $stream_info, $twitch) = @_;
    
    # Provide default values to prevent errors with undef values
    my $topic = $stream_info->{title} || 'No title provided';
    my $game  = $stream_info->{game}  || 'N/A';

    # Compare safely using the null-coalescing operator //
    if ($twitch->{$streamer}{'msgID'} && 
        (($twitch->{$streamer}{'topic'} // '') ne $topic || ($twitch->{$streamer}{'game'} // '') ne $game)) {
        
        debug "INFO CHANGED: $streamer - $topic - $game";

        $discord->get_message($config->{'channel'}, $twitch->{$streamer}{'msgID'}, sub {
            my $msg = shift;

            if (ref $msg eq 'HASH' && ref $msg->{embeds}[0] eq 'HASH' && ref $msg->{embeds}[0]{fields} eq 'ARRAY') {
                $msg->{'embeds'}[0]{'fields'}[0]{'value'} = $topic;
                $msg->{'embeds'}[0]{'fields'}[1]{'value'} = $game;
                $msg->{'embeds'}[0]{'fields'}[3]{'value'} = localtime;
                
                $discord->edit_message($config->{'channel'}, $twitch->{$streamer}{'msgID'}, $msg);
            }
        });

    } elsif (!$twitch->{$streamer}{'msgID'}) {
        $self->send_streamer_message($discord, $config, $streamer, $stream_info, $twitch);
    }

    # Persist the latest info
    $twitch->{$streamer}{'topic'} = $topic;
    $twitch->{$streamer}{'game'}  = $game;
    $self->twitchSet($twitch);
}


sub stream_offline {
    my ($self, $discord, $config, $streamer, $twitch) = @_;

    if ($twitch->{$streamer}{'msgID'}) {
        $discord->delete_message($config->{'channel'}, $twitch->{$streamer}{'msgID'});
        delete $twitch->{$streamer}{'msgID'};
        delete $twitch->{$streamer}{'topic'};
        delete $twitch->{$streamer}{'game'}; # Also remove game
        delete $twitch->{$streamer}{'online_at'}; # Also remove online_at time
        $self->twitchSet($twitch);
    }
}


sub send_streamer_message {
    my ($self, $discord, $config, $streamer, $stream_info, $twitch) = @_;
    my $topic = $stream_info->{title};
    my $game  = $stream_info->{game} || 'N/A'; # Use 'N/A' if no game is being played

    my $msg;
    if ($twitch->{$streamer}{'last_seen_online'} && (time() - $twitch->{$streamer}{'last_seen_online'}) < 600) {
        $msg = "Streamer `$streamer` is back online (from a probable stream crash).";
    } else {
        $msg = "Streamer `$streamer` is online.";
    }
    
    # This is the first time we're creating a message for this stream session
    my $online_since_time = localtime;
    # Store this initial online time in the database
    $twitch->{$streamer}{'online_at'} = $online_since_time;

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
                        'name'  => 'Activity:',
                        'value' => $game,
                    },
                    {
                        'name'  => 'Online Since:',
                        'value' => $online_since_time, # The time the stream started
                    },
                    {
                        'name'  => 'Last Update:',
                        'value' => $online_since_time, # Initially the same as online since
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

    $twitch->{$streamer}{'last_seen_online'} = time;
    # Send message and upon success, save the message ID and updated twitch data to the database
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
        # Basic validation for streamer name format
        unless ($streamer =~ /^\w{4,25}$/i) {
            push @invalid, "`$streamer` (invalid format)";
            next;
        }

        # Check if the streamer is already in our list
        if (exists $twitch_data->{lc($streamer)}) {
            push @already_exist, "`$streamer`";
            next;
        }

        # Check if the streamer exists on Twitch
        if ($self->validChannel($streamer)) {
            $twitch_data->{lc($streamer)} = {};
            push @added, "`$streamer`";
        } else {
            push @invalid, "`$streamer` (not found on Twitch)";
        }
    }

    # Construct a comprehensive response message
    my $response = "";
    $response .= "✅ Added: " . join(', ', @added) . "\n" if @added;
    $response .= "👍 Already in list: " . join(', ', @already_exist) . "\n" if @already_exist;
    $response .= "❌ Failed to add: " . join(', ', @invalid) . "\n" if @invalid;
    
    unless ($response) {
        $response = "No streamers were provided to add.";
    }

    $discord->send_message($channel, $response);

    # If we successfully added new streamers, save to DB and trigger an update loop
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

        # Check if the streamer exists in our list
        if (exists $twitch_data->{$lc_streamer}) {
            # If a message ID exists for this streamer, delete the Discord message
            if ($twitch_data->{$lc_streamer}{'msgID'}) {
                $discord->delete_message($config->{'channel'}, $twitch_data->{$lc_streamer}{'msgID'});
            }

            # Delete the streamer's data from our records
            delete $twitch_data->{$lc_streamer};
            push @deleted, "`$streamer`";
        } else {
            push @not_found, "`$streamer`";
        }
    }

    # Construct a comprehensive response message
    my $response = "";
    $response .= "🗑️ Deleted: " . join(', ', @deleted) . "\n" if @deleted;
    $response .= "❓ Not found: " . join(', ', @not_found) . "\n" if @not_found;

    unless ($response) {
        $response = "No streamers were provided to delete.";
    }

    $discord->send_message($channel, $response);

    # If we successfully deleted streamers, save the updated data and react
    if (@deleted) {
        $self->twitchSet($twitch_data);
        $self->bot->react_robot($channel, $msg->{'id'});
    } else {
        # React with an error if no streamers were found to delete
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

    # Handle the special 'list' subcommand, which is not a streamer name
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

    # Loop through each streamer name provided
    for my $streamer (@streamer_names) {
        my $lc_streamer = lc($streamer);

        if (exists $twitch_data->{$lc_streamer}) {
            # Toggle the tag status for the user
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

    # Construct a comprehensive response message
    my $response = "Tag summary for <\@$uID>:\n";
    $response .= "🏷️ Tagged: " . join(', ', @tagged) . "\n" if @tagged;
    $response .= "❌ Untagged: " . join(', ', @untagged) . "\n" if @untagged;
    $response .= "❓ Streamer not found: " . join(', ', @not_found) . "\n" if @not_found;

    $discord->send_message($channel, $response);

    # If any tags were changed, save the data to the database
    if (@tagged || @untagged) {
        $self->twitchSet($twitch_data);
        $self->bot->react_robot($channel, $msg->{'id'});
    } else {
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


sub get_live_streams {
    my ($self, $streamers_ref, $callback) = @_;
    my $config = $self->bot->config->{twitch};

    # Build the query string by repeating the user_login parameter.
    my $query_string = join '&', map { "user_login=" . $_ } @$streamers_ref;
    my $url = "https://api.twitch.tv/helix/streams?$query_string";
    
    my $oauth_token = $self->get_or_generate_oauth_token($config);
    my $ua = LWP::UserAgent->new;

    my $res = $ua->get($url,
        'client-id'     => $config->{'client_id'},
        'Authorization' => "Bearer $oauth_token",
    );

    if ($res->is_success) {
        my $json = from_json($res->content);
        # The API returns a list under the 'data' key. This list only
        # contains streamers who are currently online.
        $callback->($json->{data} || []);
    } else {
        $self->handle_error($res, $config, 'batch request');
        $callback->([]); # Return an empty list on error
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