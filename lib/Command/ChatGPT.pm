package Command::ChatGPT;

use Moo;
use strictures 2;
use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_chatgpt);

use LWP::UserAgent;
use JSON;
use Data::Dumper;
use Component::DBI;

has bot           => ( is => 'ro' );
has discord       => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log           => ( is => 'lazy', builder => sub { shift->bot->log } );
has name          => ( is => 'ro',   default => 'ChatGPT' );
has access        => ( is => 'ro',   default => 0 );
has description   => ( is => 'ro',   default => 'Chat with an AI using ChatGPT.' );
has pattern       => ( is => 'ro',   default => '^gpt ?' );
has function      => ( is => 'ro',   default => sub { \&cmd_chatgpt } );
has usage         => ( is => 'ro',   default => 'https://bob.rendler.org/en/commands/chatgpt' );

sub cmd_chatgpt {
    my ($self, $msg) = @_;
    my $discord = $self->discord;
    my $channel = $msg->{'channel_id'};
    my $config  = $self->{'bot'}{'config'}{'gpt'};
    my $args    = $msg->{'content'};
    my $pattern = $self->pattern;

    $args =~ s/$pattern//i;

    my $url = 'https://api.openai.com/v1/chat/completions';
    my $ua = LWP::UserAgent->new;
    my $res = $ua->post($url,
        'Content-Type'  => 'application/json',
        'Authorization' => "Bearer " . $config->{'secret'},
        Content         => to_json({
            "model" => "gpt-3.5-turbo",
            "messages" => [
                    {
                        "role" => "user",
                        "content" => $args,
                    },
                ],
        }),
    );

    if ($res->is_success) {

        my $response = from_json($res->content);
        if ($response->{'choices'} && $response->{'choices'}[0]{'message'}{'content'}) {

            $discord->send_message($channel, $response->{'choices'}[0]{'message'}{'content'});
            $discord->create_reaction($channel, $msg->{'id'}, "🤖");
        } else {
            $discord->send_message($channel, "Sorry, I couldn't generate a response.");
        }
    } else {
        $discord->send_message($channel, "Failed to generate response: " . $res->status_line);
    }
}


1;
