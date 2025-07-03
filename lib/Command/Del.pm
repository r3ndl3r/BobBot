package Command::Del;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;
use Component::DBI;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_del);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Delete' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Delete messages.' );
has pattern             => ( is => 'ro', default => '^del ?' );
has function            => ( is => 'ro', default => sub { \&cmd_del } );
has usage               => ( is => 'ro', default => '!delete [ids]' );


has timer_sub => ( is => 'ro', default =>
    sub { 
        my $self = shift;
        # This timer processes one message every 2 seconds.
        Mojo::IOLoop->recurring( 2 =>
            sub {
                my $db = Component::DBI->new();
                my $deletion_queue = $db->get('del.all') || {};

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
                    get_chan_msg($self->discord, $channel, $deletion_queue);
                }
                
                # Save the updated queue (with the one message removed) back to the database.
                $db->set('del.all', $deletion_queue);
            }
        ) 
    }
);


has on_message => ( is => 'ro', default =>
    sub {
        my $self   = shift;
        my $config = $self->{'bot'}{'config'}{'oz'};
        
        $self->discord->gw->on('INTERACTION_CREATE' =>     
            sub {
                my ($gw, $msg) = @_;
                
                my $id    = $msg->{'id'};
                my $token = $msg->{'token'};
                my $data  = $msg->{'data'};

                if ($data->{'custom_id'} eq 'delete.all' && $msg->{'channel_id'} eq $config->{'channel'}) {
                    $msg->{'content'} = 'all';
                    $self->discord->interaction_response($id, $token, $data->{'custom_id'}, "DELETING PLEASE WAIT...", sub { cmd_del($self, $msg) });
                }    
            }
        )
    }
);


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

    #================================#
    # 1. PARSE USER ARGUMENTS
    # Determines which action the user wants to perform.
    #================================#

    # !del all stop
    if ($args eq 'all stop') {
        my $db = Component::DBI->new();
        # To stop the process, we clear the deletion queue in the database.
        # The timer will find an empty queue on its next tick and do nothing.
        $db->set('del.all', {});
        $discord->send_message($command_channel_id, "The bulk deletion queue has been cleared.");
    
    # !del all <channel_id>
    } elsif ($args =~ /^all\s+(\d+)$/) {
        # The user wants to bulk delete a specific channel. Capture the ID.
        $target_channel_id = $1;
    
    # !del all (in the current channel)
    } elsif ($args eq 'all') {
        # The user wants to bulk delete the channel the command was sent in.
        $target_channel_id = $command_channel_id;

    # !del <message_id>
    } elsif ($args =~ /^\d+$/) {
        # This is a single message deletion. Handle it immediately and exit the sub early.
        $discord->delete_message($command_channel_id, $args);
        $discord->delete_message($command_channel_id, $msg->{'id'});
        return;
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
        my $db = Component::DBI->new();
        my $deletion_queue = $db->get('del.all') || {};
        get_chan_msg($discord, $target_channel_id, $deletion_queue);
    }
    
    # Delete the user's original command message to keep the channel clean.
    $discord->delete_message($command_channel_id, $msg->{'id'});
}


sub get_chan_msg {
    my ($discord, $channel, $deletion_queue) = @_;
    
    $discord->get_channel_messages($channel,
        sub {
            my $messages = shift;
            my $db = Component::DBI->new();

            if (@$messages) {
                # Store message IDs in an array to preserve order (newest first).
                $deletion_queue->{$channel} = [ map { $_->{id} } @$messages ];
            } else {
                # No messages left, so we can remove this channel from the queue.
                delete $deletion_queue->{$channel};
            }

            $db->set('del.all', $deletion_queue);
        }
    );
}

1;