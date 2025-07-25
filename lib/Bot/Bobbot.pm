package Bot::Bobbot;
use feature 'say';

use Moo;
use strictures 2;

use utf8;
use Data::Dumper;
use Mojo::Discord;
use Mojo::IOLoop;
use Time::Duration;
use namespace::clean;

my $debug = 0;
sub debug { my $msg = shift; say $msg if $debug }


has permissions => ( is => 'ro', default => sub {
        {
            'CREATE_INSTANT_INVITE' => 0x00000001,
            'KICK_MEMBERS'          => 0x00000002,
            'BAN_MEMBERS'           => 0x00000004,
            'ADMINISTRATOR'         => 0x00000008,
            'MANAGE_CHANNELS'       => 0x00000010,
            'MANAGE_GUILD'          => 0x00000020,
            'ADD_REACTIONS'         => 0x00000040,
            'READ_MESSAGES'         => 0x00000400,
            'SEND_MESSAGES'         => 0x00000800,
            'SEND_TTS_MESSAGES'     => 0x00001000,
            'MANAGE_MESSAGES'       => 0x00002000,
            'EMBED_LINKS'           => 0x00004000,
            'ATTACH_FILES'          => 0x00008000,
            'READ_MESSAGE_HISTORY'  => 0x00010000,
            'MENTION_EVERYONE'      => 0x00020000,
            'USE_EXTERNAL_EMOJIS'   => 0x00040000,
            'CONNECT'               => 0x00100000,
            'SPEAK'                 => 0x00200000,
            'MUTE_MEMBERS'          => 0x00400000,
            'DEAFEN_MEMBERS'        => 0x00800000,
            'MOVE_MEMBERS'          => 0x01000000,
            'USE_VAD'               => 0x02000000,
            'CHANGE_NICKNAME'       => 0x04000000,
            'MANAGE_NICKNAMES'      => 0x08000000,
            'MANAGE_ROLES'          => 0x10000000,
            'MANAGE_WEBHOOKS'       => 0x20000000,
            'MANAGE_EMOJIS'         => 0x40000000,
        }
    }
);

has config              => ( is => 'ro' );
has db                  => ( is => 'ro' );
has commands            => ( is => 'rw' );
has patterns            => ( is => 'rw' );
has session             => ( is => 'rw', default => sub { {} } );
has status_timer        => ( is => 'rw' );

has user_id             => ( is => 'rwp' );
has owner_id            => ( is => 'lazy', builder => sub { shift->config->{'discord'}{'owner_id'} } );
has trigger             => ( is => 'lazy', builder => sub { shift->config->{'discord'}{'trigger'} } );
has client_id           => ( is => 'lazy', builder => sub { shift->config->{'discord'}{'client_id'} } );
has webhook_name        => ( is => 'lazy', builder => sub { shift->config->{'discord'}{'webhook_name'} } );
has webhook_avatar      => ( is => 'lazy', builder => sub { shift->config->{'discord'}{'webhook_avatar'} } );

has discord             => ( is => 'lazy', builder => sub {
                            my $self = shift;
                            Mojo::Discord->new(
                                'token'     => $self->config->{'discord'}{'token'},
                                'name'      => $self->config->{'discord'}{'name'},
                                'url'       => $self->config->{'discord'}{'redirect_url'},
                                'version'   => '1.0',
                                'reconnect' => $self->config->{'discord'}{'auto_reconnect'},
                                'loglevel'  => $self->config->{'discord'}{'log_level'},
                                'logdir'    => $self->config->{'discord'}{'log_dir'},
                            )});

# Logging
has loglevel            => ( is => 'lazy', builder => sub { shift->config->{'discord'}{'log_level'} } );
has logdir              => ( is => 'lazy', builder => sub { shift->config->{'discord'}{'log_dir'} } );
has logfile             => ( is => 'ro', default => 'bobbot-bot.log' );
has log                 => ( is => 'lazy', builder => sub { 
                                my $self = shift; 
                                Mojo::Log->new( 
                                    'path' => $self->logdir . '/' . $self->logfile, 
                                    'level' => $self->loglevel
                                );
                            });

# Connect to discord and start running.
sub start
{
    my $self = shift;

    # This is a bit of a hack - I'm not exactly proud of it
    # Something to revisit in the future, I'm sure.
    # The idea is, in order for the event handler to have access to THIS module's $self,
    # it needs to be enclosed by a sub that has access to $self already.
    # If I don't want to define all of the handler subs in full inside of start(),
    # one alternative is to just call all of the encapsulating subs one by one here to set them up.
    $self->discord_on_ready();
    $self->discord_on_guild_create();
    $self->discord_on_guild_update();
    $self->discord_on_guild_delete();
    $self->discord_on_channel_create();
    $self->discord_on_channel_update();
    $self->discord_on_channel_delete();
    $self->discord_on_typing_start();
    $self->discord_on_message_create();
    $self->discord_on_message_update();
    $self->discord_on_presence_update();
    $self->discord_on_webhooks_update();
    #$self->discord_on_message_reaction_add();
    #$self->discord_on_message_reaction_remove();

    $self->log->info('[Bobbot.pm] [BUILD] New session beginning ' .  localtime(time));
    $self->discord->init();
    
    # Start the IOLoop unless it is already running. 
    Mojo::IOLoop->start unless Mojo::IOLoop->is_running; 
}

sub discord_on_ready
{
    my $self = shift;

    $self->discord->gw->on('READY' => sub 
    {
        my ($gw, $hash) = @_;

        $self->_add_me($hash->{'user'});
        $self->_reset_session();

        say localtime(time) . " Connected to Discord.";

        $self->status_timer( Mojo::IOLoop->recurring(120 => sub { $self->_set_status() }) ) unless defined $self->status_timer;
    });
}

# Any stats which should be cleared when the bot reconnects (Eg, the number of guilds joined, the "last-connected" timestamp, etc) should be done here.
sub _reset_session
{
    my $self = shift;

    $self->session->{'num_guilds'} = 0;
    $self->session->{'last_connected'} = time;    
}

sub uptime
{
    my $self = shift;

    return duration(time - $self->session->{'last_connected'});
}

sub _set_status
{
    my $self = shift;
   
    #'name' => $self->session->{'num_guilds'} . ' servers',
    my $status = {

       'name' => 'someone eating fried chicken.',
       'type' => 3 # "Watching"
    };
    my $discord = $self->discord->status_update($status);
}

sub discord_on_guild_create
{
    my ($self) = @_;


    $self->discord->gw->on('GUILD_CREATE' => sub {
        $self->session->{'num_guilds'}++;
    });
}

sub discord_on_guild_delete
{
    my $self = shift;

    $self->discord->gw->on('GUILD_DELETE' => sub {
        $self->session->{'num_guilds'}--;
    });
}

# Might do something with these?
# The tracking of information is done by the Mojo::Discord library now,
# so we only need these if we're going to have the bot actually do something when they happen.
sub discord_on_guild_update{}
sub discord_on_channel_create{}
sub discord_on_channel_update{}
sub discord_on_channel_delete{}
sub discord_on_webhooks_update{}
sub discord_on_typing_start{}

sub discord_on_message_create
{
    my $self = shift;

    $self->discord->gw->on('MESSAGE_CREATE' => sub 
    {
        my ($gw, $hash) = @_;

        my $author = $hash->{'author'};
        my $msg = $hash->{'content'};
        my $channel_id = $hash->{'channel_id'};
        my $guild_id = $hash->{'guild_id'};
        my $guild = $self->discord->get_guild($guild_id);
        my $guild_owner_id = $guild->{'owner_id'};
        my @mentions = @{$hash->{'mentions'}};
        my $trigger = $self->trigger;
        my $discord_name = $self->discord->name;
        my $discord_id = $self->user_id;
        my $message_id = $hash->{'id'};

        # Look for messages starting with a mention or a trigger, but not coming from a bot.
        if ( !(exists $author->{'bot'} and $author->{'bot'}) and $msg =~ /^(\<\@\!?$discord_id\>|\Q$trigger\E)/i )
        {
            $msg =~ s/^((\<\@\!?$discord_id\>.? ?)|(\Q$trigger\E))//i;   # Remove the username. Can I do this as part of the if statement?

            if ( defined $msg )
            {
                # Get all command patterns and iterate through them.
                # If you find a match, call the command fuction.
                foreach my $pattern (keys %{$self->patterns})
                {
                    if ( $msg =~ /$pattern/si )
                    {
                        my $command = $self->get_command_by_pattern($pattern);
                        my $access = $command->{'access'};
                        my $owner = $self->owner_id;

                        $access = 0 unless defined $access;
                        if ( $access == 0 # Public commands
                                or ( $access == 1 and defined $owner and $owner == $author->{'id'} )  # Owner of the bot
                                or ( $access == 2 and defined $guild_owner_id and $guild_owner_id == $author->{'id'} ) ) # Owner of the server
                        {
                            my $object = $command->{'object'};
                            my $function = $command->{'function'};

                            # Track command usage in the DB
                            # Need to re-think this. I want to have insight into bot usage for troubleshooting but this doesn't really accomplish it.
                            #$self->stats->add_command(
                            #    'command'       => lc $command->{'name'},
                            #    'channel_id'    => $channel_id,
                            #    'user_id'       => $author->{'id'},
                            #    'timestamp'     => time
                            #);

                            $hash->{'content'} = $msg;  # We've made some changes to the message content, let's make sure those get passed on to the command.
                            if ($function) {
                                $object->$function($hash);
                            }
                        }
                    }
                }
            }
        }
    });
}

sub discord_on_message_update
{
    my $self = shift;

    # Might be worth checking how old the message is, and if it's recent enough re-process it for commands?
    # Would let people fix typos without having to send a new message to trigger the bot.
    # Have to track replied message IDs in that case so we don't reply twice.
    $self->discord->gw->on('MESSAGE_UPDATE' => sub
    {
        my ($gw, $hash) = @_;

        $self->log->debug("MESSAGE_UPDATE");
        $self->log->debug(Data::Dumper->Dump([$hash], ['hash']));
    });
}

sub discord_on_presence_update
{
    my $self = shift;
}

sub _add_me
{
    my ($self, $user) = @_;
    $self->log->info('[Bobbot.pm] [_add_me] My Discord ID: ' . $user->{'id'});
    $self->_set_user_id($user->{'id'});
}

# Return a list of all commands
sub get_commands
{
    my $self = shift;

    my $cmds = {};
    
    foreach my $key (keys %{$self->commands})
    {
        $cmds->{$key} = $self->commands->{$key}{'description'};
    }

    return $cmds;
}

sub get_command_by_name
{
    my ($self, $name) = @_;

    return $self->commands->{$name};
}

sub get_command_by_pattern
{
    my ($self, $pattern) = @_;

    return $self->get_command_by_name($self->{'patterns'}{$pattern});
}

sub add_command
{
    my ($self, $command) = @_;

    unless ($command->can('debug')) {
        $command->meta->add_method('debug' => sub {
            # 1. Capture the command object (e.g., Command::Help) that this method was called on.
            # This object is ALWAYS the first argument passed to a method.
            my $cmd_self = shift;
            my $message  = shift;

            # 3. Use the main bot object to get the database handle.
            my $debug_flags = $self->db->get('debug_flags') || {};

            # 4. Use the command object to get its own name for the check.
            if ( $debug_flags->{ $cmd_self->name } ) {
                # 5. Use the bot's logger for consistent output.
                say sprintf "[DEBUG %s] %s", uc($cmd_self->name), $message;
            }
        });
    }

    my $name = $command->name;
    $self->{'commands'}->{$name}{'name'} = ucfirst $name;
    $self->{'commands'}->{$name}{'access'} = $command->access;
    $self->{'commands'}->{$name}{'usage'} = $command->usage;
    $self->{'commands'}->{$name}{'description'} = $command->description;
    $self->{'commands'}->{$name}{'pattern'} = $command->pattern;
    $self->{'commands'}->{$name}{'function'} = $command->function;
    $self->{'commands'}->{$name}{'object'} = $command;

    $self->{'patterns'}->{$command->pattern} = $name;

    # Use the bot's own logger here for consistency
    $self->log->debug('[Bobbot.pm] [add_command] Registered new command: "' . $name . '"');
}

# This sub calls any of the registered commands and passes along the args
# Returns 1 on success or 0 on failure (if command does not exist)
sub command
{
    my ($self, $command, $args) = @_;

    $command = lc $command;

    if ( exists $self->{'commands'}{$command} )
    {
        $self->{'commands'}{$command}{'function'}->($args);
        return 1;
    }
    return 0;
}

# Check if a webhook already exists - return it if so.
# If not, create one and add it to the webhooks hashref.
# Is non-blocking if callback is defined.
sub create_webhook
{
    my ($self, $channel, $callback) = @_;

    return $_ if ( $self->has_webhook($channel) );

    # If we don't have one cached we should check to see if we have Manage Webhooks


    # Create a new webhook
    my $discord = $self->discord;

    my $params = {
        'name' => $self->webhook_name, 
        'avatar' => $self->webhook_avatar 
    };

    if ( defined $callback )
    {
        $discord->create_webhook($channel, $params, sub
        {
            my $json = shift;

            if ( defined $json->{'name'} ) # Success
            {
                $callback->($json);
            }
            elsif ( $json->{'code'} == 50013 ) # No permission
            {
                say localtime(time) . ": Unable to create webhook in $channel - Need Manage Webhooks permission";
                $callback->(undef);
            }
            else
            {
                say localtime(time) . ": Unable to create webhook in $channel - Unknown reason";
                $callback->(undef);
            }
        });
    }
    else
    {
        my $json = $discord->create_webhook($channel); # Blocking

        return defined $json->{'name'} ? $json : undef;
    }
}

sub add_webhook
{
    my ($self, $channel, $json) = @_;

    $self->{'webhooks'}{$channel} = $json;
    return $self->{'webhooks'}{$channel};
}

# Get the list of webhooks from $discord
# and look for one matching our channel id and webhook_name.
sub has_webhook
{
    my ($self, $channel) = @_;

    my $hooks = $self->discord->get_cached_webhooks($channel);
    if ( $hooks )
    {
        foreach my $hook (@$hooks)
        {
            return $hook if ( $hook->{'name'} eq $self->webhook_name )
        }
    }
    return undef;
}


sub react_robot {
    my ($self, $channel_id, $message_id) = @_;
    $self->discord->create_reaction($channel_id, $message_id, "🤖");
}


sub react_error {
    my ($self, $channel_id, $message_id) = @_;
    $self->discord->create_reaction($channel_id, $message_id, "🛑");
}


# File: lib/Bot/Bobbot.pm

# Add a new subroutine to handle sending messages longer than Discord's limit
sub send_long_message {
    my ($self, $channel_id, $payload) = @_;
    debug("[Bot::Bobbot.pm] [send_long_message] Attempting to send message to channel: $channel_id");

    my $discord = $self->discord;
    my $max_text_length = 1900; # Max Discord message content is 2000, keep it under for safety and markdown.

    my $promise = Mojo::Promise->new; # This promise will be returned and resolved/rejected

    # If the payload is a plain string
    if (ref $payload eq '') { # It's a scalar (string)
        debug("[Bot::Bobbot.pm] [send_long_message] Payload is a plain string. Length: " . length($payload));
        if (length($payload) <= $max_text_length) {
            # For short messages, send directly and resolve immediately
            $discord->send_message($channel_id, $payload, sub {
                my $response = shift;
                if (ref $response eq 'HASH' && $response->{id}) {
                    debug("[Bot::Bobbot.pm] [send_long_message] Short message sent directly (success).");
                    $promise->resolve(1);
                } else {
                    $self->log->error("[Bot::Bobbot.pm] [send_long_message] Failed to send short message: " . Dumper($response));
                    $promise->reject("Failed to send short message: " . Dumper($response));
                }
            });
            return $promise;
        } else {
            # Split the string message into chunks using the robust 4-argument substr
            my @chunks;
            my $remaining_text = $payload;
            # This loop extracts a chunk and removes it from $remaining_text simultaneously.
            # It will terminate correctly when $remaining_text becomes empty.
            while (my $chunk = substr($remaining_text, 0, $max_text_length, '')) {
                push @chunks, $chunk;
            }

            my $index = 0;
            my $send_next_chunk; # Declare a recursive coderef for lexical scope

            $send_next_chunk = sub {
                if ($index < scalar @chunks) {
                    my $formatted_chunk = $chunks[$index];
                    my $chunk_num_info = ($#chunks > 0) ? " (Part " . ($index + 1) . "/" . ($#chunks + 1) . ")" : "";
                    debug("[Bot::Bobbot.pm] [send_long_message] Sending chunk " . ($index + 1) . " of " . (scalar @chunks) . $chunk_num_info . ".");

                    $discord->send_message($channel_id, $formatted_chunk, sub {
                        my $response = shift; # This is the response from Discord for this specific message.
                        if (ref $response eq 'HASH' && $response->{id}) {
                            debug("[Bot::Bobbot.pm] [send_long_message] Successfully sent chunk " . ($index + 1) . ".");
                            $index++;
                            # Schedule the next chunk send with a small delay
                            Mojo::IOLoop->timer(0.5 => $send_next_chunk); # 0.5 second delay between chunks
                        } else {
                            # If a chunk fails to send, reject the main promise
                            $self->log->error("[Bot::Bobbot.pm] [send_long_message] Failed to send chunk " . ($index + 1) . ": " . Dumper($response));
                            $promise->reject("Failed to send message chunk: " . Dumper($response));
                        }
                    });
                } else {
                    debug("[Bot::Bobbot.pm] [send_long_message] All message chunks sent successfully.");
                    $promise->resolve(1); # All chunks sent successfully
                }
            };

            # Start the chunk sending process
            $send_next_chunk->();

            return $promise; # Return the promise for the caller to chain.
        }
    } elsif (ref $payload eq 'HASH') { # It's likely an embed or other structured payload
        debug("[Bot::Bobbot.pm] [send_long_message] Payload is a HASH (embed/structured). Sending directly.");
        # Assuming the embed generation/validation in the respective command already handles its internal lengths.
        # Discord API handles embed max lengths internally. We just pass it through.
        $discord->send_message($channel_id, $payload, sub {
            my $response = shift;
            if (ref $response eq 'HASH' && $response->{id}) {
                debug("[Bot::Bobbot.pm] [send_long_message] Structured payload sent directly (success).");
                $promise->resolve(1);
            } else {
                $self->log->error("[Bot::Bobbot.pm] [send_long_message] Failed to send structured payload: " . Dumper($response));
                $promise->reject("Failed to send structured payload: " . Dumper($response));
            }
        });
        return $promise;
    } else {
        $self->log->warn("[Bot::Bobbot.pm] [send_long_message] Received unknown payload type: " . ref($payload));
        $promise->reject("Received unsupported message format to send.");
        return $promise;
    }
}


__PACKAGE__->meta->make_immutable;

1;
