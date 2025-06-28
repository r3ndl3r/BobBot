package Command::Giveaway;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use XML::Simple;
use LWP::UserAgent;
use Component::DBI;
use HTML::TreeBuilder;
use HTML::FormatText;
use Component::DBI;

use namespace::clean;

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'giveaway' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Free game giveaways' );
has pattern             => ( is => 'ro', default => '^g(iveaway)? ?' );
has function            => ( is => 'ro', default => sub { \&cmd_giveaway } );
has usage               => ( is => 'ro', default => 'Usage: `!giveaway on | off | list | update`' );
has timer_seconds       => ( is => 'ro', default => 600 );

has timer_sub => ( is => 'ro', default => sub {
    my $self = shift;
    Mojo::IOLoop->recurring($self->timer_seconds => sub { $self->giveaway });
});


sub cmd_giveaway {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;
    my $channel = $msg->{'channel_id'};
    my $author_id = $msg->{'author'}{'id'};
    my $message_id = $msg->{'id'};

    my $args = lc $msg->{'content'};
    $args =~ s/$pattern//i;
    my ($command) = split /\s+/, $args;

    if ($command eq 'on') {
        if ($args =~ /(\d+)$/ && $self->{access}) {
            $self->giveaway_on($channel, $1);
        } else {
            $self->giveaway_on($channel, $author_id);
        }

        $discord->create_reaction($channel, $message_id, "🤖");
        return;
    }

    if ($command eq 'off') {
        if ($args =~ /(\d+)$/ && $self->{access}) {
            $self->giveaway_on($channel, $1);
        } else {
            $self->giveaway_on($channel, $author_id);
        }
        $discord->create_reaction($channel, $message_id, "🤖");
        return;
    }

    if ($command eq 'list') {
        $self->giveaway_list($channel);
        $discord->create_reaction($channel, $message_id, "🤖");
        return;
    }

    if ($command eq 'update') {
        $self->giveaway;
        $discord->create_reaction($channel, $message_id, "🤖");
        return;
    }

    $discord->send_message($channel, "Usage: `!giveaway on | off | list | update`");
}


sub giveaway_on {
    my ($self, $channel, $user_id) = @_;

    my $db = Component::DBI->new();
    my $tags = $db->get('giveaway') || {};
    $tags->{$user_id} = 1;
    $db->set('giveaway', $tags);

    $self->discord->send_message($channel, "🎉 Giveaway tag enabled.");
}

sub giveaway_off {
    my ($self, $channel, $user_id) = @_;

    my $db = Component::DBI->new();
    my $tags = $db->get('giveaway') || {};
    delete $tags->{$user_id};
    $db->set('giveaway', $tags);

    $self->discord->send_message($channel, "🔕 Giveaway tag disabled.");
}


sub giveaway_list {
    my ($self, $channel) = @_;

    my $tags = Component::DBI->new()->get('giveaway') || {};

    my $reply = %$tags
        ? "🎯 Tagged users: " . join(', ', map { "<\@$_>" } keys %$tags)
        : "⚠️ No users have the giveaway tag enabled.";

    #$discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
    $self->discord->send_message($channel, $reply);
}


sub giveaway {
    my ($self) = @_;

    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'giveaway'};
    my $channel = $config->{'channel'};

    my $ua = LWP::UserAgent->new();
    $ua->agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3');

    my $res = $ua->get($config->{'url'});
    return unless $res->is_success;

    my $xml = XMLin($res->content);
    my @items = @{ $xml->{'channel'}{'item'} };

    my $db  = Component::DBI->new();
    my $dbh = $db->{'dbh'};

    my $tags = $db->get('giveaway') || {};

    for my $item (@items) {
        my $sth = $dbh->prepare("SELECT link FROM giveaway WHERE link = ?");
        $sth->execute($item->{'link'});

        # Skip if link already exists
        next if $sth->fetchrow_array();

        my $html = HTML::TreeBuilder->new();
        $html->parse($item->{'description'});

        my $formatter = HTML::FormatText->new(leftmargin => 0, rightmargin => 500);

        my $embed = {
            'embeds' => [
                {
                    'author' => {
                        'url'      => 'https://www.gamerpower.com/',
                        'icon_url' => 'https://www.gamerpower.com/assets/images/logo.png',
                    },
                    'title'       => $item->{'title'},
                    'description' => $formatter->format($html),
                    'url'         => $item->{'link'},
                    'thumbnail'   => {
                        'url' => $item->{'enclosure'}{'url'} || '',
                    },
                }
            ]
        };

        $html->delete;  # Clean up to prevent leaks

        my $insert = $dbh->prepare("INSERT INTO giveaway (link) VALUES(?)");
        $insert->execute($item->{'link'});

        $discord->send_message($channel, $embed);

        if ($tags) {
            # Send to all tagged users
            for my $user_id (keys %$tags) {
                $discord->send_dm($user_id, $embed);
            }

            my @tags = map { '<@' . $_ . '>' } keys %$tags;
            push @{ $embed->{'embeds'}[0]{'fields'} }, { 'name'  => 'Alerting:', 'value' => join ' ', @tags }; 
        }
    }
}

1;
