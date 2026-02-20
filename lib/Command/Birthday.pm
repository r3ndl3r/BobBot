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
has timer_seconds => ( is => 'ro', default => 600 ); # Check every 10 minutes for timelier announcements
has usage         => ( is => 'ro', default => <<~'EOF'
    **Birthday Command Help**

    This command manages birthday announcements for the server.

    `!birthday set <Day-Month-Year>`
    Sets your full birthday. The bot will celebrate it and announce your new age!
    *Examples:* `!birthday set 25-Dec-1990`, `!birthday set 5 July 1995`, `!birthday set 15/03/1988`

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
    (Run without a message to see the current one).
    *Example:* `!birthday message Everyone wish <@user> a happy <age> birthday! 🎉`
    EOF
);

# This recurring timer checks for birthdays to announce.
has timer_sub => ( is => 'ro', default => sub {
    my $self = shift;
    Mojo::IOLoop->recurring($self->timer_seconds => sub { $self->_check_for_birthdays });
});

sub _get_birthday_data {
    my ($self, $guild_id) = @_;
    my $all_data = $self->db->get('birthdays') || {};

    # Ensure structure exists for this guild
    $all_data->{$guild_id} ||= {
        birthdays => {},
        config => {}
    };

    return $all_data;
}

sub _save_birthday_data {
    my ($self, $data) = @_;
    $self->db->set('birthdays', $data);
}

sub cmd_birthday_router {
    my ($self, $msg) = @_;

    # Reject DM messages - birthdays are server-specific
    unless ($msg->{'guild_id'}) {
        $self->discord->send_message($msg->{'channel_id'}, 
            "Birthday commands only work in servers, not in DMs.");
        return;
    }

    my $pattern  = $self->pattern;
    my $args_str = lc $msg->{'content'};
       $args_str =~ s/$pattern//i;

    my @args       = split /\s+/, $args_str;
    my $subcommand = shift @args || '';
    my $params     = join ' ', @args;

    $self->debug("Birthday command - Guild: $msg->{'guild_id'}, Subcommand: '$subcommand'");

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
        $self->discord->send_message($msg->{'channel_id'}, 
            "Please provide a date! Usage: `!birthday set <Day-Month-Year>`");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
        return;
    }

    # Check if setting someone else's birthday
    if ($params =~ s/\s*<@!?(\d+)>//) {
        my $mentioned_id = $1;
        unless ($self->_is_admin($msg)) {
            $self->discord->send_message($msg->{'channel_id'}, 
                "You don't have permission to set someone else's birthday.");
            $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
            return;
        }
        $target_user_id = $mentioned_id;
        $date_str = $params;
    }

    # Try multiple date formats
    my $t;
    my @formats = ('%d-%b-%Y', '%d %B %Y', '%d/%m/%Y', '%Y-%m-%d');

    for my $fmt (@formats) {
        eval {
            $t = Time::Piece->strptime($date_str, $fmt);
        };
        last if $t && !$@;
    }

    # Validate the parsed date
    my $current_year = localtime->year;
    if ($@ || !$t) {
        $self->discord->send_message($msg->{'channel_id'}, 
            "Sorry, I couldn't understand that date format. Please use formats like: `25-Dec-1990`, `5 July 1995`, or `15/03/1988`.");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
        return;
    }

    # Validate year is reasonable (between 1900 and current year - 1)
    if ($t->year < 1900 || $t->year >= $current_year) {
        $self->discord->send_message($msg->{'channel_id'}, 
            "Please provide a valid birth year between 1900 and " . ($current_year - 1) . ".");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
        return;
    }

    my $formatted_date = $t->ymd; # YYYY-MM-DD format
    my $data = $self->_get_birthday_data($guild_id);

    # Store under the new structure
    $data->{$guild_id}{birthdays}{$target_user_id} = {
        date => $formatted_date,
        last_announced_year => 0
    };

    $self->_save_birthday_data($data);

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
    my $data = $self->_get_birthday_data($guild_id);

    if (exists $data->{$guild_id}{birthdays}{$author_id}) {
        delete $data->{$guild_id}{birthdays}{$author_id};
        $self->_save_birthday_data($data);
        $self->discord->send_message($msg->{'channel_id'}, "✅ Your birthday has been removed.");
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
    } else {
        $self->discord->send_message($msg->{'channel_id'}, "You don't have a birthday set.");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
    }
}

sub _list_birthdays {
    my ($self, $msg) = @_;
    my $guild_id = $msg->{'guild_id'};
    my $data = $self->_get_birthday_data($guild_id);

    my $birthdays = $data->{$guild_id}{birthdays} || {};
    unless (%$birthdays) {
        $self->discord->send_message($msg->{'channel_id'}, 
            "No birthdays have been set for this server yet.");
        return;
    }

    my $now = localtime;
    my @sorted_birthdays;

    for my $user_id (keys %$birthdays) {
        my $dob_str = $birthdays->{$user_id}{date};
        my $dob = Time::Piece->strptime($dob_str, '%Y-%m-%d');

        # Calculate next birthday occurrence
        my $next_bday_str = $now->year . "-" . $dob->strftime('%m-%d');
        my $next_bday = Time::Piece->strptime($next_bday_str, '%Y-%m-%d');

        # If birthday has passed this year, move to next year
        if ($next_bday < $now) {
            $next_bday_str = ($now->year + 1) . "-" . $dob->strftime('%m-%d');
            $next_bday = Time::Piece->strptime($next_bday_str, '%Y-%m-%d');
        }

        # Calculate age they will turn
        my $age = $next_bday->year - $dob->year;

        # Calculate countdown
        my $diff_seconds = $next_bday->epoch - $now->epoch;
        my $days_left = int($diff_seconds / 86400);

        my $countdown_str;
        if ($days_left == 0) {
            $countdown_str = "Today! 🎉";
        } elsif ($days_left == 1) {
            $countdown_str = "Tomorrow!";
        } else {
            my $months_left = int($days_left / 30.44);
            my $remaining_days = $days_left % 30;
            if ($months_left > 0) {
                $countdown_str = "$months_left month" . ($months_left > 1 ? "s" : "") . 
                               ", $remaining_days day" . ($remaining_days != 1 ? "s" : "");
            } else {
                $countdown_str = "$days_left day" . ($days_left != 1 ? "s" : "");
            }
        }

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
        $description .= "**" . $bday->{date_str} . "** - <\@" . $bday->{user_id} . 
                       "> (turning **" . $bday->{age} . "** in " . $bday->{countdown} . ")\n";
    }

    my $embed = { 
        embeds => [{ 
            title => "🎂 Server Birthdays", 
            color => 16762931, 
            description => $description 
        }] 
    };

    $self->discord->send_message($msg->{'channel_id'}, $embed);
    $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
}

sub _check_for_birthdays {
    my $self = shift;
    $self->debug("Birthday timer: Checking for birthdays...");

    my $now = localtime;
    my $today_md = $now->strftime('%m-%d');
    my $current_year = $now->year;
    my $all_data = $self->db->get('birthdays') || {};

    for my $guild_id (keys %$all_data) {
        my $guild_data = $all_data->{$guild_id};
        my $channel_id = $guild_data->{config}{announce_channel};
        my $birthdays = $guild_data->{birthdays} || {};

        unless ($channel_id && %$birthdays) {
            $self->debug("Skipping guild $guild_id (no channel or birthdays)");
            next;
        }

        for my $user_id (keys %$birthdays) {
            my $user_data = $birthdays->{$user_id};
            my $dob = Time::Piece->strptime($user_data->{date}, '%Y-%m-%d');
            my $birth_md = $dob->strftime('%m-%d');

            # Handle leap year birthdays on non-leap years
            my $is_leap_birthday = ($birth_md eq '02-29');
            my $is_leap_year = ($current_year % 4 == 0 && 
                              ($current_year % 100 != 0 || $current_year % 400 == 0));

            # On non-leap years, celebrate Feb 29 birthdays on Feb 28
            my $celebration_date = $birth_md;
            if ($is_leap_birthday && !$is_leap_year) {
                $celebration_date = '02-28';
            }

            # Check if it's their birthday and we haven't announced this year
            if ($today_md eq $celebration_date && 
                $user_data->{last_announced_year} != $current_year) {

                $self->debug("Found birthday for user $user_id in guild $guild_id");

                my $age = $current_year - $dob->year;
                my $age_suffix = $self->_get_ordinal_suffix($age);

                my $message = $guild_data->{config}{announce_message} || 
                             "Happy Birthday <\@user>! 🎉 Hope you have an amazing <age> birthday!";

                # Replace placeholders - right side needs \@ for Perl interpolation
                $message =~ s/<\@user>/<\@$user_id>/g;
                $message =~ s/<age>/$age$age_suffix/g;

                # Try to send the message
                eval {
                    $self->discord->send_message($channel_id, $message);

                    # Only mark as announced if message sent successfully
                    $all_data->{$guild_id}{birthdays}{$user_id}{last_announced_year} = $current_year;
                    $self->_save_birthday_data($all_data);

                    $self->debug("Successfully announced birthday for user $user_id");
                };

                if ($@) {
                    $self->debug("Failed to announce birthday for user $user_id: $@");
                }
            }
        }
    }
}

sub _get_ordinal_suffix {
    my ($self, $num) = @_;
    return 'th' if ($num >= 11 && $num <= 13);
    my $last_digit = $num % 10;
    return 'st' if $last_digit == 1;
    return 'nd' if $last_digit == 2;
    return 'rd' if $last_digit == 3;
    return 'th';
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
        return $self->discord->send_message($msg->{'channel_id'}, 
            "You don't have permission to use this command.");
    }
    
    my $channel_id;
    
    # Match either <#123456> or raw ID 123456
    if ($params =~ /<#(\d+)>/) {
        # Discord mention format
        $channel_id = $1;
    } elsif ($params =~ /^(\d{17,20})$/) {
        # Raw channel ID (Discord snowflakes are 17-20 digits)
        $channel_id = $1;
    }
    
    if ($channel_id) {
        my $guild_id = $msg->{'guild_id'};
        my $data = $self->_get_birthday_data($guild_id);
        
        $data->{$guild_id}{config}{announce_channel} = $channel_id;
        $self->_save_birthday_data($data);
        
        $self->discord->send_message($msg->{'channel_id'}, 
            "✅ Birthday announcements will now be sent to <#$channel_id>.");
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
    } else {
        $self->discord->send_message($msg->{'channel_id'}, 
            "Usage: `!birthday channel <#channel>` or `!birthday channel <channelID>`");
        $self->bot->react_error($msg->{'channel_id'}, $msg->{'id'});
    }
}


sub _config_message {
    my ($self, $msg, $params) = @_;

    unless ($self->_is_admin($msg)) {
        return $self->discord->send_message($msg->{'channel_id'}, 
            "You don't have permission to use this command.");
    }

    my $guild_id = $msg->{'guild_id'};
    my $data = $self->_get_birthday_data($guild_id);

    if ($params) {
        $data->{$guild_id}{config}{announce_message} = $params;
        $self->_save_birthday_data($data);

        $self->discord->send_message($msg->{'channel_id'}, 
            "✅ Birthday message updated. Use `<\@user>` for mentions and `<age>` for age.");
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
    } else {
        my $current_message = $data->{$guild_id}{config}{announce_message} || 
                             "Happy Birthday <\@user>! 🎉 Hope you have an amazing <age> birthday!";
        my $response = "The current birthday message is:\n```\n$current_message\n```\n" .
                      "Use `<\@user>` for user mention and `<age>` for their age with ordinal (21st, 32nd, etc).";
        $self->discord->send_message($msg->{'channel_id'}, $response);
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
    }
}

1;
