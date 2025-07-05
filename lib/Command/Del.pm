package Command::Del;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;
use Date::Parse; 

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_del);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro',    required => 1 );
has name                => ( is => 'ro', default => 'Delete' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Delete messages.' );
has pattern             => ( is => 'ro', default => '^del ?' );
has function            => ( is => 'ro', default => sub { \&cmd_del } );
has usage               => ( is => 'ro', default => <<~'EOF'
    **Message Deletion Command Help**

    This command allows you to delete messages from Discord channels.
    **Note**: Due to Discord API limitations, messages older than 14 days cannot be bulk-deleted.

    `!del <message_ID>`
    Deletes a single message by its unique ID.
    *Example:* `!del 123456789012345678`

    `!del all [channel_id]`
    Deletes all messages in the current channel (or a specified channel), one by one. This process is slower, especially for older messages, as it does not use the bulk delete API.
    *Example:* `!del all` (deletes all messages in the channel where the command was sent)
    *Example:* `!del all 987654321098765432` (deletes all messages in the specified channel ID)

    `!del all stop`
    Stops any ongoing `!del all` process that is deleting messages one by one.

    `!del bulk [channel_id]`
    Quickly deletes all messages less than 14 days old in the current channel (or a specified channel) by using Discord's bulk delete API. Messages are deleted in batches of up to 100. Messages older than 14 days will be ignored.
    *Example:* `!del bulk` (deletes recent messages in the current channel)
    *Example:* `!del bulk 987654321098765432` (deletes recent messages in the specified channel ID)
    EOF
);


has timer_sub => ( is => 'ro', default =>
    sub { 
        my $self = shift;
        # This timer processes one message every 3 seconds.
        Mojo::IOLoop->recurring( 3 =>
            sub {
                my $deletion_queue = $self->db->get('del.all') || {};

                return unless %$deletion_queue;
                
                # Find a channel that has messages queued in an array.
                my ($channel) = grep { ref $deletion_queue->{$_} eq 'ARRAY' and @{ $deletion_queue->{$_} } } keys %$deletion_queue;
                return unless $channel;
                
                # Get the newest message ID (the first element) from the queue.
                my $message_id = shift @{ $deletion_queue->{$channel} };
                return unless $message_id;
                
                # Delete the message.
                $self->discord->delete_message($channel, $message_id);
                
                # If the queue for that channel is now empty, fetch the next batch.
                if ( !@{ $deletion_queue->{$channel} } ) {
                    $self->get_chan_msg($channel, $deletion_queue);
                }
                
                # Save the updated queue (with the one message removed) back to the database.
                $self->db->set('del.all', $deletion_queue);
            }
        ) 
    }
);

my $debug = 0;
sub debug { my $msg = shift; say "[DEL DEBUG] $msg" if $debug }

sub cmd_del {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i; # Clean the command trigger (e.g., "!del ") from the arguments.

    # The channel where the command was originally sent.
    my $command_channel_id = $msg->{'channel_id'};
    # This will hold the channel ID for bulk delete operations.
    my $target_channel_id;

    # !del all stop
    if ($args eq 'all stop') {
        # To stop the process, we clear the deletion queue in the database.
        # The timer will find an empty queue on its next tick and do nothing.
        $self->db->set('del.all', {});
        $discord->send_message($command_channel_id, "The bulk deletion queue has been cleared.");
    
    # !del all <channel_id>
    } elsif ($args =~ /^all\s+(\d+)$/) {
        # The user wants to bulk delete a specific channel. Capture the ID.
        $target_channel_id = $1;
    
    # !del all (in the current channel)
    } elsif ($args eq 'all') {
        # The user wants to bulk delete the channel the command was sent in.
        $target_channel_id = $command_channel_id;

    } elsif ($args =~ /^bulk(?:\s+(\d+))?$/) { # Regex to match "bulk" optionally followed by a channel ID
        my $bulk_target_channel_id = $1 ? $1 : $command_channel_id; # Use provided ID or current channel ID

        # Permission check for bulk delete (existing logic, applied to the determined channel ID)
        my $target_guild_id;
        my $guilds = $self->discord->gw->guilds;
        BULK_GUILD_LOOP: foreach my $gid (keys %$guilds) {
            if (exists $guilds->{$gid}{channels}{$bulk_target_channel_id}) {
                $target_guild_id = $gid;
                last BULK_GUILD_LOOP;
            }
        }
        unless ($target_guild_id) {
            $discord->send_message($command_channel_id, "Error: Invalid or unknown channel ID for bulk delete: `$bulk_target_channel_id`.");
            $discord->delete_message($command_channel_id, $msg->{'id'});
            return;
        }

        my $has_permission = 0;
        my $bot_user_id = $self->bot->user_id;
        my $bot_member = $guilds->{$target_guild_id}{members}{$bot_user_id};
        if (($guilds->{$target_guild_id}{owner_id} eq $bot_user_id) or !$bot_member) {
            $has_permission = 1;
        } else {
            my $manage_messages_perm = $self->bot->permissions->{MANAGE_MESSAGES};
            my $administrator_perm = $self->bot->permissions->{ADMINISTRATOR};
            my @bot_role_ids = (@{ $bot_member->{roles} }, $target_guild_id);
            for my $role_id (@bot_role_ids) {
                my $role_perms = $guilds->{$target_guild_id}{roles}{$role_id}{permissions};
                if (($role_perms & $administrator_perm) || ($role_perms & $manage_messages_perm)) {
                    $has_permission = 1;
                    last;
                }
            }
        }
        unless ($has_permission) {
            $discord->send_message($command_channel_id, "Error: I do not appear to have the 'Manage Messages' permission in that channel's server for bulk delete.");
            $discord->delete_message($command_channel_id, $msg->{'id'});
            return;
        }

        # Inform the user that the process is starting.
        $discord->send_message($command_channel_id, "Initiating bulk deletion for recent messages in <#$bulk_target_channel_id>...");

        # Delete the user's original command message FIRST. It will be part of the first bulk delete batch.
        $discord->delete_message($command_channel_id, $msg->{'id'}); 
        
        # Start the recursive bulk deletion process.
        # Pass the command message ID as the starting 'before' point to ensure it's included,
        # and start the total_deleted_so_far count at 0.
        $self->_process_bulk_delete_batch($bulk_target_channel_id, $msg->{'id'}, 0, $command_channel_id, $msg->{'id'});

    # !del <message_id>
    } elsif ($args =~ /^\d+$/) {
        # This is a single message deletion. Handle it immediately and exit the sub early.
        $discord->delete_message($command_channel_id, $args);
        $discord->delete_message($command_channel_id, $msg->{'id'});
        return;
    } elsif ($args =~ /^(h|help)$/ || !$args) {
        $self->discord->send_message($msg->{channel_id}, $self->usage);
    }

    #================================#
    # 2. VALIDATE & CHECK PERMISSIONS
    # This block only runs for bulk delete commands.
    #================================#
    if ($target_channel_id) {
        my $target_guild_id;
        my $guilds = $self->discord->gw->guilds;

        # To check permissions, we first need to know which guild the channel belongs to.
        # Iterate through all guilds the bot is in and check their channel lists.
        GUILD_LOOP: foreach my $gid (keys %$guilds) {
            if (exists $guilds->{$gid}{channels}{$target_channel_id}) {
                $target_guild_id = $gid;
                last GUILD_LOOP;
            }
        }

        # If we couldn't find a guild for the channel, the ID is invalid.
        unless ($target_guild_id) {
            $discord->send_message($command_channel_id, "Error: Invalid or unknown channel ID: `$target_channel_id`.");
            $discord->delete_message($command_channel_id, $msg->{'id'});
            return;
        }

        # Now, check if the bot has the 'Manage Messages' permission in that guild.
        my $has_permission = 0;
        my $bot_user_id = $self->bot->user_id;
        my $bot_member = $guilds->{$target_guild_id}{members}{$bot_user_id};

        # The bot always has permission if it's the server owner.
        # If we can't find the bot's member object, we assume it has permission and let the API call fail later if not.
        if (($guilds->{$target_guild_id}{owner_id} eq $bot_user_id) or !$bot_member) {
            $has_permission = 1;
        } else {
            # Check the permissions from all of the bot's roles.
            my $manage_messages_perm = $self->bot->permissions->{MANAGE_MESSAGES};
            my $administrator_perm = $self->bot->permissions->{ADMINISTRATOR};
            # Include the @everyone role ID (which is the same as the guild ID) in the check.
            my @bot_role_ids = (@{ $bot_member->{roles} }, $target_guild_id);

            for my $role_id (@bot_role_ids) {
                my $role_perms = $guilds->{$target_guild_id}{roles}{$role_id}{permissions};
                # Use a bitwise AND to see if the permission bit is set.
                if (($role_perms & $administrator_perm) || ($role_perms & $manage_messages_perm)) {
                    $has_permission = 1;
                    last; # Found a role with the required permission, no need to check further.
                }
            }
        }
        
        # Note: This is a simplified check. It confirms guild-level permissions but does not
        # account for channel-specific overwrites that could deny the permission.

        unless ($has_permission) {
            $discord->send_message($command_channel_id, "Error: I do not appear to have the 'Manage Messages' permission in that channel's server.");
            $discord->delete_message($command_channel_id, $msg->{'id'});
            return;
        }

        # If all checks pass, start the bulk delete process by populating the queue.
        my $deletion_queue = $self->db->get('del.all') || {};
        $self->get_chan_msg($target_channel_id, $deletion_queue);
    }
    
    # Delete the user's original command message to keep the channel clean.
    $discord->delete_message($command_channel_id, $msg->{'id'});
}


sub get_chan_msg {
    my ($self, $channel, $deletion_queue) = @_;
    
    $self->discord->get_channel_messages($channel,
        sub {
            my $messages = shift;

            if (@$messages) {
                # Store message IDs in an array to preserve order (newest first).
                $deletion_queue->{$channel} = [ map { $_->{id} } @$messages ];
            } else {
                # No messages left, so we can remove this channel from the queue.
                delete $deletion_queue->{$channel};
            }

            $self->db->set('del.all', $deletion_queue);
        }
    );
}


sub _process_bulk_delete_batch {
    my ($self, $channel_id, $last_message_id_for_pagination, $total_deleted_so_far, $initial_command_channel_id, $initial_msg_id) = @_;

    my $batch_size_limit = 100;
    my $two_weeks_ago_epoch = time() - (14 * 24 * 60 * 60); # 14 days in seconds

    # Fetch up to 100 messages (Discord API limit), starting before $last_message_id_for_pagination (for pagination)
    $self->discord->get_channel_messages($channel_id, sub {
        my $messages_fetched = shift; # This is an arrayref of message objects
        my @message_ids_to_bulk_delete;
        my $new_last_message_id = undef; # To pass to the next recursive call for pagination
        my $messages_collected_in_batch = 0;

        # Iterate through fetched messages to build a batch for bulk deletion
        for my $message_obj (@$messages_fetched) {
            # Discord's bulk delete API has a limit of 100 messages per call.
            # We also ensure the batch size doesn't exceed this.
            last if $messages_collected_in_batch >= $batch_size_limit;

            my $message_timestamp_epoch = str2time($message_obj->{timestamp});

            # Only collect messages less than 14 days old for bulk deletion
            if ($message_timestamp_epoch > $two_weeks_ago_epoch) {
                push @message_ids_to_bulk_delete, $message_obj->{id};
                # This message_obj->{id} will be the oldest message ID in this current batch of fetched messages.
                # We use it for the 'before' parameter in the next get_channel_messages call for pagination.
                $new_last_message_id = $message_obj->{id}; 
                $messages_collected_in_batch++;
            } else {
                # If we encounter a message older than 14 days, no more messages
                # in this fetch (and subsequent fetches in this pagination chain)
                # will be eligible for bulk deletion. So, stop collecting.
                last; 
            }
        }

        my $num_eligible_for_batch = scalar @message_ids_to_bulk_delete;

        # Bulk delete requires a minimum of 2 messages.
        if ($num_eligible_for_batch >= 2) {
            debug("Sending bulk delete request for $num_eligible_for_batch messages from channel $channel_id.");
            $self->discord->bulk_delete_message($channel_id, \@message_ids_to_bulk_delete, sub {
                my $response = shift; # Success typically means undef or empty hash for 204 No Content

                if (ref $response eq 'HASH' && $response->{code}) { # Check for API errors
                    $self->discord->send_message($initial_command_channel_id, "Error during bulk delete batch: " . ($response->{message} || "Unknown API error"));
                    $self->bot->react_error($initial_command_channel_id, $initial_msg_id);
                    debug("Bulk delete batch failed: " . Data::Dumper::Dumper($response));
                    return; # Stop on error
                }

                $total_deleted_so_far += $num_eligible_for_batch;
                debug("Successfully deleted $num_eligible_for_batch messages. Total deleted: $total_deleted_so_far.");

                # Recursively call to get the next batch, if more messages were fetched than collected in current batch (meaning more are available after new_last_message_id)
                # Or if we hit the batch_size_limit, indicating more might be available.
                # Use a small timer (1 second) to respect API rate limits between batches.
                if (scalar @$messages_fetched >= $batch_size_limit && defined $new_last_message_id) {
                     Mojo::IOLoop->timer(1 => sub {
                        $self->_process_bulk_delete_batch($channel_id, $new_last_message_id, $total_deleted_so_far, $initial_command_channel_id, $initial_msg_id);
                    });
                } else {
                    # Base case: No more full batches found, or all remaining messages are too old.
                    #$self->discord->send_message($initial_command_channel_id, "Bulk deletion complete for recent messages. Total deleted: **$total_deleted_so_far** from <#$channel_id>.");
                    $self->bot->react_robot($initial_command_channel_id, $initial_msg_id);
                    debug("Bulk deletion process finished. Total: $total_deleted_so_far.");
                }
            });
        } else {
            # Base case: Less than 2 eligible messages found in this fetch, or all remaining were too old.
            # This means the bulk deletion for recent messages is complete.
            # Only send the completion message if this isn't the very first attempt resulting in 0 deletes
            # to avoid duplicate messages if _process_bulk_delete_batch is called multiple times without actual deletions.
            if ($total_deleted_so_far > 0 || (scalar @$messages_fetched > 0 && $messages_collected_in_batch == 0) ) { # If messages were fetched but none eligible, or if prior deletes occurred.
                #$self->discord->send_message($initial_command_channel_id, "Bulk deletion complete for recent messages. Total deleted: **$total_deleted_so_far** from <#$channel_id>.");
                $self->bot->react_robot($initial_command_channel_id, $initial_msg_id);
                debug("Bulk deletion process finished. Total: $total_deleted_so_far.");
            } else { # If total_deleted_so_far is 0 and no new eligible messages were found
                $self->discord->send_message($initial_command_channel_id, "No recent messages (less than 14 days old) found for bulk deletion in <#$channel_id>.");
                $self->bot->react_robot($initial_command_channel_id, $initial_msg_id);
            }
        }
    }, { before => $last_message_id_for_pagination, limit => $batch_size_limit }); # Fetch limit for get_channel_messages
}

1;
