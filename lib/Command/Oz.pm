package Command::Oz;
use feature 'say';

use Moo;
use strictures 2;
use XML::Simple;
use LWP::UserAgent;
use Component::DBI;
use HTML::TreeBuilder;
use HTML::FormatText;

use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_oz);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'oz' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'oz' );
has pattern             => ( is => 'ro', default => '^oz ?' );
has function            => ( is => 'ro', default => sub { \&cmd_oz } );
has usage               => ( is => 'ro', default => '' );
has timer_seconds       => ( is => 'ro', default => 600 );

has timer_sub => ( is => 'ro', default => sub 
    { 
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->cmd_oz } ) 
    }
);


sub cmd_oz {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i if $args;

    my $config = $self->{'bot'}{'config'}{'oz'};

    my ($sql, $sth);
    my $db  = Component::DBI->new();
    my $dbh = $db->{'dbh'};
    
    my $ua = LWP::UserAgent->new();
       $ua->agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.54 Safari/537.36');

    my $res = $ua->get($config->{'url'});
    my $xml = XMLin($res->content);

    my @items = @{ $xml->{'channel'}{'item'} };

    for my $item (@items) {
        $sql = "SELECT link FROM oz WHERE link = ?";
        $sth = $dbh->prepare($sql);
        $sth->execute($item->{'link'});

        if ($sth->fetchrow_array()) {
            next;
        }

    my $html = HTML::TreeBuilder->new();
    $html->parse($item->{'description'});
    my $formatter = HTML::FormatText->new(leftmargin => 0, rightmargin => 500);

    my $embed = {   
                    'embeds' => [ 
                        {   
                            'author' => {
                                'name'     => 'OzBargains',
                                'url'      => 'https://www.ozbargain.com.au/',
                                'icon_url' => 'https://files.delvu.com/images/ozbargain/logo/Square%20Flat.png',
                            },
                            'thumbnail' => {
                                'url'   => $item->{'media:thumbnail'}{'url'},
                            },
                            'title'       => $item->{'title'},
                            'description' => $formatter->format($html),
                            'url'         => $item->{'link'},

                            'fields' => [
                                {
                                    'name'  => 'Link:',
                                    'value' => $item->{'ozb:meta'}{'url'},
                                },
                            ],
                        } 
                    ]
                };

        $discord->send_message($config->{'channel'}, $embed,
            sub {
                my $id = shift->{'id'};
                my $sql = "INSERT INTO oz (link) VALUES(?)";
                my $sth = $dbh->prepare($sql);

                $sth->execute($item->{'link'});
            }        
        );

    }
}    

1;