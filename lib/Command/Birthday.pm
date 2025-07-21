package Command::Birthday;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use POSIX qw(strftime);
use Time::Piece;
use Time::Seconds;

has bot           => ( is => 'ro' );
has discord       => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log           => ( is => 'lazy', builder => sub { shift->bot->log } );
has db            => ( is => 'ro', required => 1 );
has name          => ( is => 'ro', default => 'Birthday' );
has access        => ( is => 'ro', default => 0 );
has description   => ( is => 'ro', default => 'A birthday reminder and announcement system.' );
has pattern       => ( is => 'ro', default => sub { qr/^birth(day)? ?/i } );
has function      => ( is => 'ro', default => sub { \&cmd_birthday_router } );
has timer_seconds => ( is => 'ro', default => 3600 ); # Check every hour
has usage         => ( is => 'ro', default => <<~'EOF'
    **Birthday Command Help**

    This command manages birthday announcements for the server.

    `!birthday set <Day-Month-Year>`
    Sets your full birthday. The bot will celebrate it and announce your new age!
    *Examples:* `!birthday set 25-Dec-1990`, `!birthday set 5 July 1995`

    `!birthday remove`
    Removes your birthday from the list.

    `!birthday list`
    Shows a list of all upcoming birthdays, how old users will be, and a countdown.

    ---
    **Admin Commands**
    `!birthday set <Day-Month-Year> <@user>`
    Sets the birthday for another user.

    `!birthday channel <#channel>`
    Sets the channel where birthday announcements will be posted.

    `!birthday message <message>`
    Customizes the announcement message. Use `<@user>` for the mention and `<age>` for their new age.
    *Example:* `!birthday message Everyone wish <@user> a happy <age>th birthday! 🎉`
    EOF
);


# This recurring timer checks for birthdays to announce.
has timer_sub => ( is => 'ro', default => sub {
    my $self = shift;
    Mojo::IOLoop->recurring($self->timer_seconds => sub { $self->_check_for_birthdays });
});


sub _get_birthday_data {
    my $self = shift;
    my $data = $self->db->get('birthdays') || {};
    return $data;
}


sub cmd_birthday_router {
    my ($self, $msg) = @_;
    my $pattern  = $self->pattern;
    my $args_str = lc $msg->{'content'};
       $args_str =~ s/$pattern//i;

    my @args       = split /\s+/, $args_str;
    my $subcommand = shift @args || '';
    my $params     = join ' ', @args;

    $self->debug("Routing subcommand: '$subcommand'");

    if ($subcommand eq 'set') {
        $self->_set_birthday($msg, $params);
    } elsif ($subcommand eq 'remove') {
        $self->_remove_birthday($msg);
    } elsif ($subcommand eq 'list') {
        $self->_list_birthdays($msg);
    } elsif ($subcommand eq 'channel') {
        $self->_config_channel($msg, $params);
    } elsif ($subcommand eq 'message') {
        $self->_config_message($msg, $params);
    } else {
        $self->discord->send_message($msg->{'channel_id'}, $self->usage);
    }
}


sub _set_birthday {
    my ($self, $msg, $params) = @_;
    my $guild_id = $msg->{'guild_id'};
    my $author_id = $msg->{'author'}{'id'};
    my $target_user_id = $author_id;
    my $date_str = $params;

    unless ($params) {
        $self->discord->send_message($msg->{'channel_id'}, "Please provide a date! Usage: `!birthday set <Day-Month-Year>`");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
        return;
    }

    if ($params =~ s/\s*<@!?(\d+)>//) {
        my $mentioned_id = $1;
        unless ($self->_is_admin($msg)) {
            $self->discord->send_message($msg->{'channel_id'}, "You don't have permission to set someone else's birthday.");
            $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
            return;
        }
        $target_user_id = $mentioned_id;
        $date_str = $params;
    }
    
    # --- MODIFIED: Date parsing now expects a year ---
    my $t;
    eval {
        $t = Time::Piece->strptime($date_str, '%d-%b-%Y', '%d %B %Y', '%d/%m/%Y');
    };
    if ($@ || !$t || $t->year > (localtime->year - 5)) { # Basic validation for a realistic year
        $self->discord->send_message($msg->{'channel_id'}, "Sorry, I couldn't understand that date format. Please use a format like `25-Dec-1990` or `5 July 1995`.");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
        return;
    }

    # --- MODIFIED: Store the full ISO 8601 date string for precision ---
    my $formatted_date = $t->ymd; # e.g., "1990-12-25"
    my $data = $self->_get_birthday_data();
    
    $data->{$guild_id}{users}{$target_user_id}{date} = $formatted_date;
    $data->{$guild_id}{users}{$target_user_id}{last_announced_year} = 0;

    $self->db->set('birthdays', $data);

    my $display_date = $t->strftime('%d-%b-%Y');
    my $confirmation_message = ($target_user_id eq $author_id)
        ? "✅ Your birthday has been saved as **$display_date**."
        : "✅ Birthday for <\@$target_user_id> has been saved as **$display_date**.";
    
    $self->discord->send_message($msg->{'channel_id'}, $confirmation_message);
    $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
}


sub _remove_birthday {
    my ($self, $msg) = @_;
    my $guild_id = $msg->{'guild_id'};
    my $author_id = $msg->{'author'}{'id'};
    my $data = $self->_get_birthday_data();

    if (delete $data->{$guild_id}{users}{$author_id}) {
        $self->db->set('birthdays', $data);
        $self->discord->send_message($msg->{'channel_id'}, "Your birthday has been removed.");
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
    } else {
        $self->discord->send_message($msg->{'channel_id'}, "You don't have a birthday set.");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
    }
}


sub _list_birthdays {
    my ($self, $msg) = @_;
    my $guild_id = $msg->{'guild_id'};
    my $data = $self->_get_birthday_data();

    my $users = $data->{$guild_id}{users} || {};
    unless (%$users) {
        $self->discord->send_message($msg->{'channel_id'}, "No birthdays have been set for this server yet.");
        return;
    }

    my $now = localtime;
    my @sorted_birthdays;
    for my $user_id (keys %$users) {
        my $dob_str = $users->{$user_id}{date};
        my $dob = Time::Piece->strptime($dob_str, '%Y-%m-%d');

        # Reconstruct the next birthday string using the current year and the stored month/day.
        my $next_bday_str = $now->year . "-" . $dob->strftime('%m-%d');
        my $next_bday = Time::Piece->strptime($next_bday_str, '%Y-%m-%d');
        
        # If the birthday has already passed this year, add a year to sort it correctly.
        $next_bday += ONE_YEAR if $next_bday < $now;
        
        # Calculate age they will be turning
        my $age = $next_bday->year - $dob->year;

        # Calculate countdown
        my $diff_seconds = $next_bday->epoch - $now->epoch;
        my $months_left = int($diff_seconds / (30.44 * 86400));
        my $days_left = int(($diff_seconds % (30.44 * 86400)) / 86400);
        # Handle the case where the birthday is today
        my $countdown_str = ($diff_seconds < 86400) ? "Today!" : (($months_left > 0 ? "$months_left months, " : "") . "$days_left days");
        
        push @sorted_birthdays, { 
            user_id => $user_id, 
            time => $next_bday, 
            date_str => $dob->strftime('%d-%b'),
            age => $age,
            countdown => $countdown_str,
        };
    }

    @sorted_birthdays = sort { $a->{time} <=> $b->{time} } @sorted_birthdays;
    
    my $description = "Here are the upcoming birthdays:\n\n";
    for my $bday (@sorted_birthdays) {
        $description .= "**" . $bday->{date_str} . "** - <@" . $bday->{user_id} . "> (turning **" . $bday->{age} . "** in " . $bday->{countdown} . ")\n";
    }

    my $embed = { embeds => [{ title => "🎂 Server Birthdays", color => 16762931, description => $description }] };
    $self->discord->send_message($msg->{'channel_id'}, $embed);
    $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
}


sub _check_for_birthdays {
    my $self = shift;
    $self->debug("Timer fired: Checking for birthdays...");
    
    my $now = localtime;
    my $today_date_md = $now->strftime('%m-%d'); # Compare month and day
    my $current_year = $now->year;
    my $data = $self->_get_birthday_data();

    for my $guild_id (keys %$data) {
        my $guild_data = $data->{$guild_id};
        my $channel_id = $guild_data->{config}{announcement_channel};
        my $users = $guild_data->{users} || {};

        next unless ($channel_id && %$users);
        
        for my $user_id (keys %$users) {
            my $user_bday = $users->{$user_id};
            my $dob = Time::Piece->strptime($user_bday->{date}, '%Y-%m-%d');
            
            # --- MODIFIED: Check against month-day and last announced year ---
            if ($dob->strftime('%m-%d') eq $today_date_md && $user_bday->{last_announced_year} != $current_year) {
                $self->debug("Found birthday for user $user_id in guild $guild_id.");
                
                # --- MODIFIED: Calculate age for the announcement ---
                my $age = $current_year - $dob->year;
                my $age_ordinal = ($age % 10 == 1 && $age % 100 != 11) ? 'st'
                                : ($age % 10 == 2 && $age % 100 != 12) ? 'nd'
                                : ($age % 10 == 3 && $age % 100 != 13) ? 'rd'
                                : 'th';

                # --- MODIFIED: Default message includes age ---
                my $message = $guild_data->{config}{announcement_message} || "Happy Birthday <\@user>! 🎉";
                $message =~ s/<\@user>/<\@$user_id>/g;
                $message =~ s/<age>/$age$age_ordinal/g; # Replace age placeholder
                
                $self->discord->send_message($channel_id, $message);

                $data->{$guild_id}{users}{$user_id}{last_announced_year} = $current_year;
                $self->db->set('birthdays', $data);
            }
        }
    }
}

sub _is_admin {
    my ($self, $msg) = @_;
    my $guild = $self->discord->get_guild($msg->{'guild_id'});
    return 1 if $msg->{'author'}{'id'} eq $self->bot->owner_id;
    return 1 if $guild && $msg->{'author'}{'id'} eq $guild->{'owner_id'};
    return 0;
}


sub _config_channel {
    my ($self, $msg, $params) = @_;
    unless ($self->_is_admin($msg)) {
        return $self->discord->send_message($msg->{'channel_id'}, "You don't have permission to use this command.");
    }
    
    if ($params && $params =~ /<#(\d+)>/) {
        my $channel_id = $1;
        my $data = $self->_get_birthday_data();
        $data->{$msg->{'guild_id'}}{config}{announcement_channel} = $channel_id;
        $self->db->set('birthdays', $data);
        $self->discord->send_message($msg->{'channel_id'}, "✅ Birthday announcements will now be sent to <#$channel_id>.");
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
    } else {
        $self->discord->send_message($msg->{'channel_id'}, "Usage: `!birthday channel <#channel>`");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
    }
}


sub _config_message {
    my ($self, $msg, $params) = @_;
    unless ($self->_is_admin($msg)) {
        return $self->discord->send_message($msg->{'channel_id'}, "You don't have permission to use this command.");
    }

    if ($params) {
        my $data = $self->_get_birthday_data();
        $data->{$msg->{'guild_id'}}{config}{announcement_message} = $params;
        $self->db->set('birthdays', $data);
        $self->discord->send_message($msg->{'channel_id'}, "✅ Birthday message updated.");
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
    } else {
        $self->discord->send_message($msg->{'channel_id'}, "Usage: `!birthday message <your custom message>`");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
    }
}


1;