package Command::Chelsea;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use POSIX qw(strftime);
use Time::Piece;
use Mojo::IOLoop;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_chelsea);


# Required attributes for the command module initialization
has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );

# Command configuration attributes that define how the module behaves
has name                => ( is => 'ro', default => 'Chelsea' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Gets the current water temperature at Chelsea beach.' );
has pattern             => ( is => 'ro', default => '^chelsea ?' );
has function            => ( is => 'ro', default => sub { \&cmd_chelsea } );
has usage               => ( is => 'ro', default => 'Usage: !chelsea' );

# Sets up the recurring timer to check for the scheduled post time every minute
has timer_sub => ( is => 'ro', default => sub {
    my $self = shift;
    # Timer runs every 60 seconds to check for the 8 AM posting window
    # This ensures we don't miss the target time regardless of when the bot starts
    Mojo::IOLoop->recurring(60 => sub { $self->_scheduled_check() });
});


# Internal method to run the scheduled daily check at 8 AM Melbourne time
sub _scheduled_check {
    my ($self) = @_;

    # Set Melbourne timezone for this process
    local $ENV{TZ} = 'Australia/Melbourne';
    POSIX::tzset();
    my $now = localtime;

    my $current_hour   = $now->hour;
    my $current_minute = $now->min;
    my $today_date     = $now->ymd; # Format: YYYY-MM-DD
    my $last_run_date  = $self->db->get('chelsea_last_run') || '';
    $last_run_date     = $$last_run_date if $last_run_date;

    $self->debug(
        "_scheduled_check running. Melbourne Time: " . $now->hms . 
        ". Current Hour: $current_hour. Current Minute: $current_minute. " .
        "Today's Date: $today_date. Last Run Date: " . ($last_run_date || 'Never')
    );

    # Condition to post the daily temperature announcement:
    # 1. It is exactly 8 AM (hour 8)
    # 2. It is within the first minute of the hour (8:00 to 8:10)
    # 3. The check has not successfully run today yet
    if ($current_hour == 8 && $current_minute <= 10 && $today_date ne $last_run_date) {
        $self->debug("Time window and run condition met. Attempting to post temperature.");
        
        # Get the target channel from bot configuration or use default
        my $target_channel_id = $self->bot->config->{chelsea}{channel};
        
        # Attempt to fetch and post the temperature
        my $temperature = $self->_fetch_temperature();
        if ($temperature) {
            my $message = "Good morning! The current water temperature at Chelsea beach is **$temperature**.";
            $self->discord->send_message($target_channel_id, $message);
            
            # Update the last run date immediately upon successful post to prevent re-runs
            $self->db->set('chelsea_last_run', \$today_date);
            $self->debug("Successfully posted temperature and updated last run date to $today_date.");
        } else {
            $self->debug("Failed to fetch temperature. Will try again on the next timer tick.");
        }
    } else {
        $self->debug("Scheduled check conditions not met. Skipping post.");
    }
}


# Fetches the current water temperature from the Chelsea beach website
# Returns the temperature string on success, undef on failure
sub _fetch_temperature {
    my ($self) = @_;

    my $url = "https://seatemperature.info/australia/chelsea-water-temperature.html";
    $self->debug("_fetch_temperature: Fetching URL: $url");

    my $ua = LWP::UserAgent->new;
    $ua->timeout(30);
    $ua->agent('Mozilla/5.0 (compatible; DiscordBot/1.0;');
    
    my $res = $ua->get($url);

    if ($res->is_success) {
        my $content = $res->decoded_content;
        
        # Search for the temperature information in the HTML content
        if ($content =~ /<strong>Water temperature in Chelsea today is (.*?)\.<\/strong>/) {
            my $temperature = $1;
            # Convert HTML degree entity to proper Unicode degree symbol
            $temperature =~ s/&deg;/°/g;
            
            $self->debug("_fetch_temperature: Successfully found temperature: $temperature");
            return $temperature;
        } else {
            $self->debug("_fetch_temperature: Temperature information not found in page content.");
            # Log a portion of the content for debugging purposes
            my $content_preview = substr($content, 0, 200) . "...";
            $self->debug("Content preview: $content_preview");
            return undef;
        }
    } else {
        $self->debug("_fetch_temperature: Failed to fetch webpage: " . $res->status_line);
        return undef;
    }
}


# Main command function that handles user-initiated temperature checks
sub cmd_chelsea {
    my ($self, $msg) = @_;

    my $channel_id = $msg->{'channel_id'};
    my $discord    = $self->discord;

    $self->debug("cmd_chelsea: User requested temperature check from channel $channel_id");

    # Fetch the current temperature using the shared method
    my $temperature = $self->_fetch_temperature();

    if ($temperature) {
        # Successfully retrieved temperature - send response to user
        $discord->send_message($channel_id, "The current water temperature at Chelsea beach is **$temperature**.");
        $self->bot->react_robot($channel_id, $msg->{'id'}); # Confirm successful operation
        $self->debug("cmd_chelsea: Successfully responded with temperature: $temperature");
    } else {
        # Failed to retrieve temperature - inform user of the error
        $discord->send_message($channel_id, "Sorry, I couldn't retrieve the current water temperature. Please try again later.");
        $self->bot->react_error($channel_id, $msg->{'id'}); # Indicate operation failed
        $self->debug("cmd_chelsea: Failed to retrieve temperature for user request");
    }
}


1;