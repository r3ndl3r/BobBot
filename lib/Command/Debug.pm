package Command::Debug;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_debug);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );

has name                => ( is => 'ro', default => 'Debug' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Toggles debug logging for specific modules.' );
has pattern             => ( is => 'ro', default => '^debug ?' );
has function            => ( is => 'ro', default => sub { \&cmd_debug } );
has usage               => ( is => 'ro', default => <<~'EOF'
    **Debug Command Help**

    `!debug <on|off> <ModuleName>`
    Enables or disables debug logging for a specific module.
    *Example:* `!debug on Twitch`

    `!debug list`
    Shows the current debug status for all available modules.
    EOF
);


sub cmd_debug {
    my ($self, $msg) = @_;
    my $pattern = $self->pattern;
    my $channel_id = $msg->{'channel_id'};
    my $args_str = $msg->{'content'};
       $args_str =~ s/$pattern//i;

    my @args = split /\s+/, $args_str;    
    my $subcommand = shift @args || '';
    my $module_name = join ' ', @args;

    my $debug_flags = $self->db->get('debug_flags') || {};

    if (($subcommand eq 'on' || $subcommand eq 'off') && length($module_name) > 0) {
        my $state = ($subcommand eq 'on') ? 1 : 0;
        $module_name =~ s/\.pm$//i;

        unless (exists $self->bot->commands->{$module_name}) {
            $self->discord->send_message($channel_id, "❌ Error: No module named **$module_name** found.");
            $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
            return;
        }

        $debug_flags->{$module_name} = $state;
        $self->db->set('debug_flags', $debug_flags);
        my $status_text = $state ? 'enabled' : 'disabled';
        $self->discord->send_message($channel_id, "✅ Debug mode for **$module_name** is now **$status_text**.");

    } elsif ($subcommand eq 'list' && length($module_name) == 0) {
        $self->list_statuses($msg, $debug_flags);

    } else {
        $self->discord->send_message($channel_id, $self->usage);
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
        return;
    }

    $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
}


# Helper sub to display the status of all modules.
sub list_statuses {
    my ($self, $msg, $debug_flags) = @_;
    my $channel_id = $msg->{'channel_id'};
    my @statuses;

    my $commands = $self->bot->get_commands;
    # Iterate through all loaded commands to show their status.
    foreach my $cmd_name (sort keys %$commands) {
        # Default to off (🔴) if a flag isn't explicitly set.
        my $status_icon = $debug_flags->{$cmd_name} ? '🟢' : '🔴';
        push @statuses, "$status_icon $cmd_name";
    }

    if (@statuses) {
        $self->discord->send_message($channel_id, "**Current Debug Statuses:**\n" . join("\n", @statuses));
    } else {
        $self->discord->send_message($channel_id, "No modules found to report status on.");
    }
}

1;
