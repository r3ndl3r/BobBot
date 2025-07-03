package Command::Tasks;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use Component::DBI;
use Time::Duration;
use Data::Dumper;
use POSIX qw(strftime);

has bot           => ( is => 'ro' );
has discord       => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log           => ( is => 'lazy', builder => sub { shift->bot->log } );
has name          => ( is => 'ro', default => 'Tasks' );
has access        => ( is => 'ro', default => 0 );
has description   => ( is => 'ro', default => 'A task assignment system.' );
has usage         => ( is => 'ro', default => 'Usage: !tasks help' );
has pattern       => ( is => 'ro', default => sub { qr/^tasks?\b/i } );
has function      => ( is => 'ro', default => sub { \&cmd_tasks } );
has timer_sub     => ( is => 'ro', default => sub { 
        my $self = shift;
        Mojo::IOLoop->recurring( 600 => sub { $self->send_reminders } );
    }
);

# Set to 1 for verbose output, 0 to disable.
my $debug = 1;
sub debug { my $msg = shift; say "[Tasks DEBUG] $msg" if $debug }

# Helper function to safely load and initialize the data structure.
sub get_task_data {
    my $db = Component::DBI->new();
    my $data = $db->get('tasks') || {};
    #debug("Loading data from DB: " . Dumper($data));

    # Ensure all top-level keys are initialized correctly.
    $data->{kids} //= {};
    $data->{active_tasks} //= {};
    $data->{next_task_id} //= 1;

    return $data;
}

# Main command router.

sub cmd_tasks {
    my ($self, $msg) = @_;
    my $args_str = $msg->{'content'};
    debug("Received command string: '$args_str'");
    $args_str =~ s/^tasks?\s*//i;
    my @args = split /\s+/, $args_str, 2;
    
    my $subcommand = lc shift @args;
    debug("Parsed subcommand: '$subcommand'");

    my $argument = $args[0];

    if ($subcommand =~ /^ka(dd)?$/i) {
        my ($id, $nickname) = split /\s+/, $argument, 2;
        $self->kadd($msg, $id, $nickname);
    } elsif ($subcommand =~ /^kd(el)?$/i) {
        $self->kdel($msg, $argument);
    } elsif ($subcommand =~ /^a(dd)?$/i) {
        my ($nickname, $task_desc) = split /\s+/, $argument, 2;
        $self->task_add($msg, $nickname, $task_desc);
    } elsif ($subcommand =~ /^d(el)?$/i) {
        $self->task_del($msg, $argument);
    } elsif ($subcommand =~ /^c(omplete)?$/i) {
        $self->task_complete($msg, $argument);
    } elsif ($subcommand =~ /^l(ist)?$/i) {
        $self->task_list($msg);
    } elsif ($subcommand =~ /^r(emind)?$/i) {
        # ADDED: New command to manually trigger reminders.
        $self->discord->send_message($msg->{'channel_id'}, "Manually sending reminders for all active tasks...");
        $self->send_reminders();
    } elsif ($subcommand =~ /^h(elp)?$/i) {
        $self->task_help($msg);
    } else {
        debug("Unknown subcommand received.");
        $self->discord->send_message($msg->{'channel_id'}, "Unknown command. Use `!tasks help` for a list of commands.");
    }
}

# --- Kid Management ---

sub kadd {
    my ($self, $msg, $id, $nickname) = @_;
    debug("Attempting to add kid. ID: '$id', Nickname: '$nickname'");
    unless ($id && $nickname && $id =~ /^\d+$/) {
        debug("-> Failure: Invalid arguments provided.");
        return $self->discord->send_message($msg->{'channel_id'}, "Usage: `!tasks kadd <Discord_ID> <nickname>`");
    }
    my $db = Component::DBI->new();
    my $data = get_task_data();
    $data->{kids}{lc($nickname)} = $id;
    $db->set('tasks', $data);
    debug("-> Success: Added '$nickname' to database.");
    $self->discord->send_message($msg->{'channel_id'}, "Added kid **$nickname**.");
}

sub kdel {
    my ($self, $msg, $nickname) = @_;
    debug("Attempting to delete kid: '$nickname'");
    unless ($nickname) {
        debug("-> Failure: No nickname provided.");
        return $self->discord->send_message($msg->{'channel_id'}, "Usage: `!tasks kdel <nickname>`");
    }
    my $db = Component::DBI->new();
    my $data = get_task_data();
    if (delete $data->{kids}{lc($nickname)}) {
        delete $data->{active_tasks}{lc($nickname)};
        $db->set('tasks', $data);
        debug("-> Success: Removed '$nickname' from database.");
        $self->discord->send_message($msg->{'channel_id'}, "Removed kid **$nickname**.");
    } else {
        debug("-> Failure: Nickname '$nickname' not found.");
        $self->discord->send_message($msg->{'channel_id'}, "Could not find kid with nickname **$nickname**.");
    }
}

# --- Task Management ---

sub task_add {
    my ($self, $msg, $nickname, $task_desc) = @_;
    debug("Attempting to assign task. Nickname: '$nickname', Task: '$task_desc'");
    unless ($nickname && $task_desc) {
        return $self->discord->send_message($msg->{'channel_id'}, "Usage: `!tasks add <nickname> <task description>`");
    }
    my $db = Component::DBI->new();
    my $data = get_task_data();
    $nickname = lc($nickname);
    
    unless (exists $data->{kids}{$nickname}) {
        debug("-> Failure: Kid '$nickname' not found.");
        return $self->discord->send_message($msg->{'channel_id'}, "Kid '**$nickname**' not found.");
    }
    
    # --- MODIFIED: ID Recycling Logic ---

    # 1. Collect all currently used task ID numbers.
    my %used_ids;
    foreach my $kid_name (keys %{ $data->{active_tasks} }) {
        if (ref $data->{active_tasks}{$kid_name} eq 'ARRAY') {
            foreach my $task (@{ $data->{active_tasks}{$kid_name} }) {
                # Store the number part of the ID (e.g., 1 from T1)
                if ($task->{id} =~ /^T(\d+)$/) {
                    $used_ids{$1} = 1;
                }
            }
        }
    }

    # 2. Find the lowest available integer for the new ID.
    my $next_id_num = 1;
    while (exists $used_ids{$next_id_num}) {
        $next_id_num++;
    }

    my $new_task_id = "T$next_id_num";
    # The old 'next_task_id' counter is no longer used by this system.

    # --- End ID Recycling Logic ---
    
    push @{ $data->{active_tasks}{$nickname} }, {
        id          => $new_task_id,
        description => $task_desc,
        assigner_id => $msg->{author}{id},
        assigned_at => time(),
    };
    $db->set('tasks', $data);
    debug("-> Success: Assigned task $new_task_id to '$nickname'.");
    
    my $kid_id = $data->{kids}{$nickname};
    my $dm_message = "Hi! You've been assigned a new task:\n**$new_task_id: $task_desc**\n\n"
                   . "To complete it, type: `!tasks complete $new_task_id`";
    $self->discord->send_dm($kid_id, $dm_message);
    debug("-> Sent DM notification to kid ID '$kid_id'.");
    
    $self->discord->send_message($msg->{'channel_id'}, "Task **$new_task_id** assigned to **$nickname**.");
}


sub task_del {
    my ($self, $msg, $task_id_to_remove) = @_;
    debug("Attempting to remove task ID '$task_id_to_remove'.");
    unless ($task_id_to_remove) {
        return $self->discord->send_message($msg->{'channel_id'}, "Usage: `!tasks del <Task_ID>` (e.g., T1)");
    }

    my $db = Component::DBI->new();
    my $data = get_task_data();
    my $task_found = 0;

    KID_LOOP: foreach my $nickname (keys %{ $data->{active_tasks} }) {
        for (my $i = 0; $i < @{ $data->{active_tasks}{$nickname} }; $i++) {
            if (lc($data->{active_tasks}{$nickname}[$i]{id}) eq lc($task_id_to_remove)) {
                debug("-> Found task '$task_id_to_remove' for '$nickname'. Removing it.");
                splice(@{ $data->{active_tasks}{$nickname} }, $i, 1);
                $task_found = 1;
                last KID_LOOP;
            }
        }
    }

    if ($task_found) {
        $db->set('tasks', $data);
        $self->discord->send_message($msg->{'channel_id'}, "Removed task **$task_id_to_remove**.");
    } else {
        debug("-> Failure: Task ID '$task_id_to_remove' not found.");
        $self->discord->send_message($msg->{'channel_id'}, "Could not find task with ID **$task_id_to_remove**.");
    }
}

sub task_complete {
    my ($self, $msg, $task_id_to_complete) = @_;
    debug("Attempting to complete task ID '$task_id_to_complete'.");
    unless ($task_id_to_complete) {
        return $self->discord->send_message($msg->{'channel_id'}, "Usage: `!tasks complete <Task_ID>` (e.g., T1)");
    }
    
    my $db = Component::DBI->new();
    my $data = get_task_data();
    my $completer_id = $msg->{author}{id};
    debug("-> Completer Discord ID: '$completer_id'");
    
    my ($nickname) = grep { $data->{kids}{$_} eq $completer_id } keys %{ $data->{kids} };
    
    unless ($nickname) {
        debug("-> Failure: User '$completer_id' is not a registered kid.");
        return $self->discord->send_message($msg->{'channel_id'}, "You are not registered as a kid who can complete tasks.");
    }
    debug("-> Found matching nickname for completer: '$nickname'");

    my $task_found = 0;
    my $task_index = -1;
    for (my $i = 0; $i < @{ $data->{active_tasks}{$nickname} || [] }; $i++) {
        if (lc($data->{active_tasks}{$nickname}[$i]{id}) eq lc($task_id_to_complete)) {
            $task_index = $i;
            $task_found = 1;
            last;
        }
    }

    if ($task_found) {
        my $completed_task = splice(@{ $data->{active_tasks}{$nickname} }, $task_index, 1);
        my $assigner_id = $completed_task->{assigner_id};
        debug("-> Found matching task for '$nickname'. Assigner ID: '$assigner_id'");
        $db->set('tasks', $data);

        $self->discord->send_message($msg->{'channel_id'}, "Great job! Task **$completed_task->{id}** marked as complete.");
        
        my $assigner_notification = "✅ Task Complete! **$nickname** has completed the task: **$completed_task->{description}**";
        $self->discord->send_dm($assigner_id, $assigner_notification);
        debug("-> Sent completion DM to assigner ID '$assigner_id'.");
    } else {
        debug("-> Failure: Task '$task_id_to_complete' not found for user '$nickname'.");
        $self->discord->send_message($msg->{'channel_id'}, "Could not find active task **$task_id_to_complete** assigned to you.");
    }
}


sub task_list {
    my ($self, $msg) = @_;
    my $author_id = $msg->{author}{id};
    debug("Generating active task list for user $author_id");
    my $data = get_task_data();
    
    # --- Determine which tasks to show ---
    my ($kid_nickname) = grep { $data->{kids}{$_} eq $author_id } keys %{ $data->{kids} };

    my @nicknames_to_list;
    if ($kid_nickname) {
        # User is a registered kid, only prepare their nickname for listing.
        debug("-> User is kid '$kid_nickname'. Showing their tasks only.");
        push @nicknames_to_list, $kid_nickname;
    } else {
        # User is not a kid, show all tasks (admin/public view).
        debug("-> User is not a registered kid. Showing all tasks.");
        @nicknames_to_list = sort keys %{ $data->{active_tasks} };
    }
    # --- End determination ---

    my @fields;
    # Loop through the determined list of nicknames (either one or all).
    foreach my $nickname (@nicknames_to_list) {
        my @kid_tasks;
        my $tasks_for_kid = $data->{active_tasks}{$nickname};
        if (ref $tasks_for_kid eq 'ARRAY') {
            foreach my $task (@$tasks_for_kid) {
                my $task_age = duration_exact(time() - $task->{assigned_at});
                push @kid_tasks, "**$task->{id}:** $task->{description} *(assigned $task_age ago)*";
            }
        }
        if (@kid_tasks) {
            push @fields, { name => "Tasks for `$nickname`", value => join("\n", @kid_tasks) };
        }
    }
    
    unless (@fields) {
        # Tailor the "no tasks" message based on who ran the comm and.
        my $response = $kid_nickname
            ? "You have no active tasks. Great job!"
            : "There are no active tasks for anyone.";
        debug("-> No active tasks found to display.");
        return $self->discord->send_message($msg->{'channel_id'}, $response);
    }

    my $embed = { embeds => [{ title => "Active Task List", color => 15844367, fields => \@fields, timestamp => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime) }] };
    #debug("-> Sending task list embed. " . Dumper($embed));
    $self->discord->send_message($msg->{'channel_id'}, $embed);
}


sub task_help {
    my ($self, $msg) = @_;
    debug("Displaying help message.");
    my $help_text = << "HELP";
**Task Manager Help**
`!tasks kadd (ka) <Discord_ID> <nickname>` - Adds a user.
`!tasks kdel (kd) <nickname>` - Removes a user.
`!tasks add (a) <nickname> <description>` - Assigns a new task.
`!tasks del (d) <Task_ID>` - Removes an active task by its unique ID.
`!tasks complete (c) <Task_ID>` - Mark one of your own tasks as complete by its ID.
`!tasks list (l)` - Shows all current, incomplete tasks.
`!tasks remind (r)` - Manually sends reminders for all active tasks.
`!tasks help (h)` - Shows this help message.
HELP
    $self->discord->send_message($msg->{'channel_id'}, $help_text);
}

# --- Timer for Reminders ---

# In lib/Command/Tasks.pm

sub send_reminders {
    my $self = shift;
    debug("Reminder timer fired.");
    my $data = get_task_data();
    
    return unless %{ $data->{active_tasks} };
    debug("Found active tasks. Processing reminders...");
    
    foreach my $nickname (keys %{ $data->{active_tasks} }) {
        my $kid_id = $data->{kids}{$nickname};
        if (ref $data->{active_tasks}{$nickname} eq 'ARRAY') {
            foreach my $task (@{ $data->{active_tasks}{$nickname} }) {
                # UPDATED: The reminder message now includes the command to complete the task.
                my $dm_reminder = "Friendly reminder! You still have a task to complete:\n"
                                . "**$task->{id}: $task->{description}**\n\n"
                                . "To complete it, type: `!tasks complete $task->{id}`";

                $self->discord->send_dm($kid_id, $dm_reminder);
                debug("-> Sent reminder to '$nickname' (ID: $kid_id) for task '$task->{id}'.");
            }
        }
    }
    debug("Reminder processing complete.");
}

1;