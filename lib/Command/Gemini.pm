package Command::Gemini;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use JSON;
use Data::Dumper; # For detailed error logging
use Mojo::IOLoop; # For timer in retry logic

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_gemini);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );
has name                => ( is => 'ro', default => 'Gemini' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Have a conversation with Google\'s Gemini AI.' );
has pattern             => ( is => 'ro', default => '^gem(ini)? ?' );
has function            => ( is => 'ro', default => sub { \&cmd_gemini } );
has usage               => ( is => 'ro', default => <<~'EOF'
    **Gemini AI Command Help**

    Have an ongoing conversation with the Gemini AI model. The AI will remember the context of the chat in this channel.

    `!gemini <your message>`
    Sends your message to the AI and gets a response.

    `!gemini reset`
    Clears the conversation history for this channel, allowing you to start a new topic.
    EOF
);

# This on_message handler intercepts all messages to check for the dedicated channel.
has on_message => ( is => 'ro', default =>
    sub {
        my $self = shift;
        $self->discord->gw->on('MESSAGE_CREATE' =>
            sub {
                my ($gw, $msg) = @_;
                # Get the dedicated Gemini channel ID from the [google_gemini] config section.
                my $gemini_channel_id = $self->bot->config->{google_gemini}{channel};

                # Proceed only if the config is set, the message is in the right channel, and it's not from a bot.
                if ($gemini_channel_id && $msg->{channel_id} eq $gemini_channel_id && !(exists $msg->{author}{bot} and $msg->{author}{bot})) {

                    # Directly call the main command logic.
                    $self->cmd_gemini($msg);
                }
            }
        );
    }
);


my $debug = 0;
sub debug { my $msg = shift; say "[GEMINI DEBUG] $msg" if $debug }

# Helper function to make the API call with retry logic
sub _make_gemini_api_call {
    my ($self, $msg, $history, $retries) = @_;
    $retries //= 0; # Initialize retries to 0

    my $channel_id = $msg->{'channel_id'};
    my $api_key = $self->bot->config->{google_gemini}{api_key};
    my $model = 'gemini-2.5-flash';
    my $url = "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$api_key";
    my $payload = { contents => $history };

    debug("Attempting API POST request to $url (Retry: $retries) with payload: " . (ref $payload ? JSON->new->encode($payload) : $payload));

    # Return the promise chain from this function
    return $self->discord->rest->ua->post_p($url => json => $payload)->then(sub {
        my $tx = shift;

        debug("API POST request returned. Status: " . $tx->res->code . " " . $tx->res->message);
        debug("Response Body: " . ($tx->res->body // '[No Body]'));

        # Handle 'Too Many Requests' specifically
        if ($tx->res->code == 429) {
            my $retry_after = $tx->res->headers->header('Retry-After') || 1; # Default to 1 second if header is missing
            $retry_after = $retry_after * (2 ** $retries); # Exponential backoff
            $retry_after = 60 if $retry_after > 60; # Cap max retry delay

            debug("Received 429 Too Many Requests. Retrying in $retry_after seconds (Attempt: " . ($retries + 1) . ")");
            if ($retries < 3) { # Limit retries to prevent infinite loops
                # Schedule retry and return a new promise that resolves when the retry completes
                return Mojo::Promise->new->then(sub {
                    my $resolve_retry = shift;
                    Mojo::IOLoop->timer($retry_after => sub {
                        $self->_make_gemini_api_call($msg, $history, $retries + 1)->then(
                            sub { $resolve_retry->resolve(shift) }, # Propagate success
                            sub { $resolve_retry->reject(shift) } # Propagate failure
                        );
                    });
                });
            } else {
                return Mojo::Promise->reject("Too Many Requests: Maximum retries exceeded.");
            }
        }

        unless ($tx->res->is_success) {
            # Reject the promise with a specific error message
            return Mojo::Promise->reject("API_CONNECTION_ERROR: " . $tx->res->message);
        }

        my $json;
        eval {
            $json = $tx->res->json;
        };
        if ($@) {
            # Reject the promise if JSON decoding fails
            return Mojo::Promise->reject("MALFORMED_RESPONSE: $@");
        }

        if (my $error = $json->{error}) {
            # Reject the promise if Gemini API returns an error
            return Mojo::Promise->reject("GEMINI_API_ERROR: " . $error->{message});
        }

        my $response_text = "Sorry, I received an empty response."; # Default
        if (my $candidates = $json->{candidates}[0]) {
            if (my $content = $candidates->{content}) {
                if (my $parts = $content->{parts}[0]) {
                    $response_text = $parts->{text} if $parts->{text};
                }
            }
        }

        push @{$history}, {
            role => 'model',
            parts => [ { text => $response_text } ]
        };

        # Return the promise from send_long_message to chain it
        return $self->bot->send_long_message($channel_id, $response_text)->then(sub {
            # If message sent successfully, save history and resolve the main promise
            my $history_key = "gemini_conversation"; # Non-channel-specific key
            $self->db->set($history_key, $history);
            debug("Saved updated history after successful message send.");
            return 1; # Resolve this step successfully
        });

    })->catch(sub {
        my $err = shift;
        # Propagate the error up the chain by re-rejecting with the captured error
        return Mojo::Promise->reject($err);
    });
}


# This subroutine handles all interactions with the Gemini command.
sub cmd_gemini {
    my ($self, $msg) = @_;

    my $channel_id = $msg->{'channel_id'};
    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $prompt = $msg->{'content'};
    # The pattern will only match if the user uses !gemini.
    # For the dedicated channel, this won't match, so the full message is used as the prompt.
    $prompt =~ s/$pattern//i;

    # --- Subcommand Routing ---
    if (lc($prompt) eq 'reset') {
        $self->reset_conversation($channel_id, $msg);
        return;
    }

    unless (length $prompt > 0) {
        $self->bot->send_long_message($channel_id, $self->usage)->catch(sub {
            my $err = shift;
            $self->log->error("[Gemini.pm] Error sending usage message: $err");
        });
        return;
    }
    # --- End Routing ---

    # Get the Google AI API Key from config.ini
    my $api_key = $self->bot->config->{google_gemini}{api_key};
    unless ($api_key) {
        $self->log->error("[Gemini.pm] Google Gemini API key is not configured in config.ini.");
        $self->bot->send_long_message($channel_id, "Sorry, the Gemini command is not configured correctly by the bot owner.")->catch(sub {
            my $err = shift;
            $self->log->error("[Gemini.pm] Error sending config error message: $err");
        });
        return;
    }

    # Let the user know the bot is thinking...
    $discord->start_typing($channel_id);

    # --- Main Logic ---
    # Load the conversation history from the database (non-channel-specific)
    my $history_key = "gemini_conversation";
    my $history = $self->db->get($history_key) || [];
    debug("Loaded " . scalar(@$history) . " parts from history.");

    # Add the user's new prompt to the history
    push @$history, {
        role => 'user',
        parts => [ { text => $prompt } ]
    };

    # Call the helper function and handle its promise result
    $self->_make_gemini_api_call($msg, $history)->then(sub {
        # If _make_gemini_api_call resolves, everything went well (API call, message send, history save)
        debug("Gemini command fully executed successfully.");
    })->catch(sub {
        my $err = shift;
        $self->log->error("[Gemini.pm] Final error caught in cmd_gemini: $err");
        debug("[Gemini.pm] Raw final error object: " . (ref $err ? Data::Dumper->Dumper($err) : $err));
        # Send a user-friendly error message, including the specific error from the promise chain if available.
        my $user_error_message = "An unexpected error occurred while contacting the AI.";
        if (ref $err eq '') { # If the error is a simple string (e.g., from custom rejections)
            $user_error_message = "Sorry, " . $err;
            # Clean up specific error prefixes for user display
            $user_error_message =~ s/API_CONNECTION_ERROR: //;
            $user_error_message =~ s/MALFORMED_RESPONSE: //;
            $user_error_message =~ s/GEMINI_API_ERROR: //;
            $user_error_message =~ s/Too Many Requests: //;
        }

        $self->bot->send_long_message($channel_id, $user_error_message)->catch(sub {
            my $send_err = shift;
            $self->log->error("[Gemini.pm] Error sending final generic error message: $send_err");
        });
    });
}

# This helper subroutine clears the conversation history.
sub reset_conversation {
    my ($self, $channel_id, $msg) = @_;

    my $history_key = "gemini_conversation"; # Non-channel-specific key
    $self->db->del($history_key);

    debug("Conversation history reset.");

    $self->bot->send_long_message($channel_id, "AI conversation history has been reset.")->catch(sub {
        my $err = shift;
        $self->log->error("[Gemini.pm] Error sending reset confirmation message: $err");
    });
    $self->bot->react_robot($channel_id, $msg->{'id'});
}

1;