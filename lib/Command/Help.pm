package Command::Help;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_help);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Help' );
has access              => ( is => 'ro', default => 0 ); # 0 = Public, 1 = Bot-Owner Only, 2 = Server-Owner Only
has description         => ( is => 'ro', default => 'List all commands currently available to the bot, or detailed information about a specific command' );
has pattern             => ( is => 'ro', default => '^help ?' );
has function            => ( is => 'ro', default => sub { \&cmd_help } );
has usage               => ( is => 'ro', default => <<EOF
Basic Usage: `!help`

Advanced Usage: `!help <Command>`
Eg: `!help uptime`
EOF
);

# Set to 1 for verbose output, 0 to disable.
my $debug = 1;
sub debug { my $msg = shift; say "[Help DEBUG] $msg" if $debug }

sub cmd_help {
    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};

    my $pattern = $self->pattern;
    # Remove the command trigger from the arguments string
    $args =~ s/$pattern//i;

    my $discord = $self->discord;
    my $bot     = $self->bot;

    my $commands = $bot->get_commands;
    my $trigger  = $bot->trigger;

    # Check if a specific command was requested (i.e., $args is not empty)
    if ( defined $args and length $args > 0 )
    {
        debug("User requested help for a specific command: '$args'");
        my $command = undef;
        # Iterate through all registered command patterns to find a match
        foreach my $cmd_pattern (keys %{$bot->patterns})
        {
            if ( $args =~ /$cmd_pattern/i )
            {
                # Found a matching pattern, get the command object
                $command = $bot->get_command_by_pattern($cmd_pattern);
                last; # Exit loop once a match is found
            }
        }

        # If a command was found, send its detailed help to the channel as an embed
        if ( defined $command )
        {
            debug("Found command: " . $command->{'name'});
            my $embed = {
                embeds => [{
                    title       => "__**" . $command->{'name'} . "**__",
                    description => "`" . $command->{'description'} . "`",
                    color       => 3447003, # A nice blue color for embeds
                    fields      => [
                        {
                            name    => "__**Usage:**__",
                            value   => $command->{'usage'} || "No specific usage provided.",
                            inline  => 0,
                        }
                    ],
                }]
            };
            # Send the embed to the channel
            $discord->send_message($channel, $embed);
            # React to the original message to acknowledge it
            $self->bot->react_robot($channel, $msg->{'id'});
            debug("Sent detailed help for '" . $command->{'name'} . "' to channel: $channel.");
        }
        else
        {
            # Command not found, send an error message to the channel
            debug("Command '$args' not found.");
            $discord->send_message($channel, "Sorry, no command exists by that name. Use `!help` to list all available commands.");
        }
    }
    else # No arguments provided, display a list of all commands using an embed
    {
        debug("User requested a list of all commands.");
        my @public;
        my @botowner;
        my @serverowner;

        # Populate command lists by access level
        foreach my $key (sort keys %{$commands})
        {
            my $command = $bot->get_command_by_name($key);
            my $access = $command->{'access'};
            # Assign commands to respective lists based on their access level
            if ( defined $access )
            {
                push @public, $key if $access == 0;
                push @botowner, $key if $access == 1;
                push @serverowner, $key if $access == 2;
            }
        }

        my @fields;

        # Add fields to the embed for each category that has commands
        if (@public) {
            push @fields, { name => "Public Commands", value => "```\n" . (join "\n", @public) . "```", inline => 0 };
        }
        if (@botowner) {
            push @fields, { name => "Restricted to Bot Owner", value => "```\n" . (join "\n", @botowner) . "```", inline => 0 };
        }
        if (@serverowner) {
            push @fields, { name => "Restricted to Server Owner", value => "```\n" . (join "\n", @serverowner) . "```", inline => 0 };
        }

        my $embed_description = "Use `" . $trigger . "help <command>` to see more about a specific command.";

        # If no commands are available at all, update the description
        unless (@fields) {
            $embed_description = "There are no commands available at this time.";
            debug("No commands found to list.");
        }

        my $embed = {
            embeds => [{
                title       => "Available Bot Commands",
                description => $embed_description,
                color       => 3447003, # A nice blue color
                fields      => \@fields,
            }]
        };

        # Send the embed to the channel
        $discord->send_message($channel, $embed);
        # React to the original message to acknowledge it
        $self->bot->react_robot($channel, $msg->{'id'});
        debug("Sent overall help list to channel: $channel.");
    }
}

1;