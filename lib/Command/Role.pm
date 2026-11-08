package Command::Role;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use Data::Dumper;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_role);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'Role' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Role' );
has pattern             => ( is => 'ro', default => '^role ?' );
has function            => ( is => 'ro', default => sub { \&cmd_role } );
has usage               => ( is => 'ro', default => <<EOF
###
EOF
);

sub cmd_role {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;
    my $guild_id = $msg->{'guild_id'};
    my $guild   = $discord->get_guild($guild_id);

    if (!defined $guild) {
        $self->log->error("Could not find guild with ID $guild_id");
        return;
    }

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

    if ($args =~ /^h(?:elp)?/i) {
        my $help_message = <<EOF;
Available commands:
- !role list: List all roles on the server with their IDs.
- !role add <name>: Add a new role to the server.
- !role delete <role_id>: Delete an existing role from the server using its ID.
- !role assign <user1> [user2...] <role_id>: Assign a role to one or more users.
- !role join <role_id>: Assign a role to yourself.
- !role leave <role_id>: Remove a role from yourself.
EOF
        $discord->send_message($channel, $help_message);
    }

    $self->bot->react_robot($channel, $msg->{'id'});
    
    if ($args =~ /^l(ist)?/i) {
        my $roles = $guild->roles;
        my @role_list;
        
        # Sort by position (descending like Discord UI)
        for my $id (sort { $roles->{$b}->position <=> $roles->{$a}->position } keys %{ $roles }) {
            push @role_list, sprintf("**%s**: `%s`", $roles->{$id}->name, $id);
        }
        
        my $output = "Roles on this server (Name: ID):\n" . join("\n", @role_list);
        $discord->send_message($channel, $output);
    }

    if (my ($add) = $args =~ /^a(?:dd)\s+(.*)/i) {
        my $options = {};
        $add =~ s/^\s+|\s+$//g; # Trim
        $add =~ s/^"|"$//g;     # Trim quotes
        
        if ($add =~ /=>/) {
            my @options = split /,/, $add;
            for my $opt (@options) {
                $opt =~ s/^\s+//;
                $opt =~ s/\s+$//;
                my ($x, $y) = split / => /, $opt;
                $options->{$x} = $y;
            }
        } else {
            $options->{'name'} = $add;
        }

        $discord->create_guild_role($guild_id, $options, sub {
            my $role = shift;
            if ($role && $role->{'id'}) {
                $self->log->info("[Role.pm] User $author->{username} ($author->{id}) created role: $role->{name} ($role->{id})");
                $discord->send_message($channel, "Created role: **" . $role->{'name'} . "** (`" . $role->{'id'} . "`)");
            } else {
                $self->bot->react_error($channel, $msg->{'id'});
                $discord->send_message($channel, "Failed to create role.");
            }
        });
    }

    if (my ($del_id) = $args =~ /^d(?:elete)?\s+(\d+)/i) {
        my $roles = $guild->roles;

        if (exists $roles->{$del_id}) {
            my $name = $roles->{$del_id}->name;
            $discord->delete_guild_role($guild_id, $del_id, sub {
                $self->log->info("[Role.pm] User $author->{username} ($author->{id}) deleted role: $name ($del_id)");
                $discord->send_message($channel, "Deleted role: **$name** (`$del_id`)");
            });
        } else {
            $self->bot->react_error($channel, $msg->{'id'});
            $discord->send_message($channel, "Role ID not found: `$del_id` (Use `!role list` to find IDs)");
        }
    }
    
    if (my ($users_input, $role_id) = $args =~ /^ass(?:ign)?\s+(.+)\s+(\d+)/i) {
        my $roles = $guild->roles;
        my @user_refs = split /\s+/, $users_input;
        
        if (exists $roles->{$role_id}) {
            my $role_name = $roles->{$role_id}->name;
            my @success_users;

            for my $u_ref (@user_refs) {
                my $u_id = $u_ref;
                $u_id =~ s/\D//g;
                next unless $u_id;

                $discord->add_guild_member_role($guild_id, $u_id, $role_id, sub {
                    push @success_users, "<@$u_id>";
                    if (@success_users == @user_refs) {
                        $self->log->info("[Role.pm] User $author->{username} ($author->{id}) assigned role $role_name ($role_id) to: " . join(', ', @user_refs));
                        $discord->send_message($channel, "Assigned role **$role_name** to " . join(', ', @success_users));
                    }
                });
            }
        } else {
            $self->bot->react_error($channel, $msg->{'id'});
            $discord->send_message($channel, "Role ID not found: `$role_id` (Use `!role list` to find IDs)");
        }
    }

    if (my ($role_id) = $args =~ /^join\s+(\d+)/i) {
        my $roles = $guild->roles;
        if (exists $roles->{$role_id}) {
            my $role_name = $roles->{$role_id}->name;
            $discord->add_guild_member_role($guild_id, $author->{'id'}, $role_id, sub {
                $self->log->info("[Role.pm] User $author->{username} ($author->{id}) joined role: $role_name ($role_id)");
                $discord->send_message($channel, "You have joined role **$role_name**");
            });
        } else {
            $discord->send_message($channel, "Role ID not found: `$role_id` (Use `!role list` to find IDs)");
        }
    }

    if (my ($role_id) = $args =~ /^leave\s+(\d+)/i) {
        my $roles = $guild->roles;
        if (exists $roles->{$role_id}) {
            my $role_name = $roles->{$role_id}->name;
            $discord->remove_guild_member_role($guild_id, $author->{'id'}, $role_id, sub {
                $self->log->info("[Role.pm] User $author->{username} ($author->{id}) left role: $role_name ($role_id)");
                $discord->send_message($channel, "You have left role **$role_name**");
            });
        } else {
            $discord->send_message($channel, "Role ID not found: `$role_id` (Use `!role list` to find IDs)");
        }
    }
}

1;
