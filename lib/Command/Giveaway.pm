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

use namespace::clean;

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'giveaway' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Free game giveaways' );
has pattern             => ( is => 'ro', default => '^giveaway ?' );
has function            => ( is => 'ro', default => sub { \&cmd_giveaway } );
has usage               => ( is => 'ro', default => '' );
has timer_seconds       => ( is => 'ro', default => 600 );

has timer_sub => ( is => 'ro', default => sub {
    my $self = shift;
    Mojo::IOLoop->recurring($self->timer_seconds => sub { $self->cmd_giveaway });
});

sub cmd_giveaway {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'giveaway'};
    my $channel = $config->{'channel'};

    my $ua = LWP::UserAgent->new();
       $ua->agent('Mozilla/5.0');

    my $res = $ua->get($config->{'url'});
    return unless $res->is_success;

    my $xml = XMLin($res->content);
    my @items = @{ $xml->{'channel'}{'item'} };

    my $db  = Component::DBI->new();
    my $dbh = $db->{'dbh'};

    for my $item (@items) {
        my $sql = "SELECT link FROM giveaway WHERE link = ?";
        my $sth = $dbh->prepare($sql);
        $sth->execute($item->{'link'});

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

        $discord->send_message($channel, $embed, sub {
            my $id = shift->{'id'};
            my $insert = $dbh->prepare("INSERT INTO giveaway (link) VALUES(?)");
            $insert->execute($item->{'link'});
        });
    }
}

1;
