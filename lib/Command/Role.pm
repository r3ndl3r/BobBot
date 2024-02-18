package Command::Role;
use feature 'say';

use Moo;
use strictures 2;

use namespace::clean;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_role);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

has name                => ( is => 'ro', default => 'Role' );
has access              => ( is => 'ro', default => 1 );
has description         => ( is => 'ro', default => 'Role' );
has pattern             => ( is => 'ro', default => '^role ?' );
has function            => ( is => 'ro', default => sub { \&cmd_role } );
has usage               => ( is => 'ro', default => <<EOF
###
EOF
);

sub cmd_role {
    my ($self, $msg) = @_;

    my $discord = $self->discord;
    my $pattern = $self->pattern;
    $msg->{'guild_id'} = 880820123257172009;
    my $guild   = $discord->get_guild($msg->{'guild_id'});

    my $channel = $msg->{'channel_id'};
    my $author  = $msg->{'author'};
    my $args    = $msg->{'content'};
       $args    =~ s/$pattern//i;

    if ($args =~ /^h(?:elp)?/i) {
        my $help_message = <<EOF;
Available commands:
- !role list: List all roles on the server.
- !role add <name>: Add a new role to the server.
- !role delete <name>: Delete an existing role from the server.
- !role assign <user> <role>: Assign a role to a user.
EOF
        $discord->send_message($channel, $help_message);
    }
    
    if ($args =~ /^l(ist)?/i) {
        my $roles = $guild->roles;
        my @roles = map { $roles->{$_}->{'name'} } keys %{ $roles };
        
        print Data::Dumper::Dumper(\@roles);
        #$discord->send_dm($author, join ', ', sort @roles);
    }

    if (my ($add) = $args =~ /^a(?:dd)\s+(.*)/i) {
        my @options = split /,/, $add;
        my $options;

        for my $opt (@options) {
            $opt =~ s/^\s+//;
            $opt =~ s/\s+$//;
            my ($x, $y) = split / => /, $opt;

            $options->{$x} = $y;
        }

        print Data::Dumper::Dumper(\$options);

        $discord->create_guild_role($msg->{'guild_id'}, $options, sub{print Data::Dumper::Dumper(\@_);});

    }

    if (my ($del) = $args =~ /^d(:?elete)?\s+(.*)/i) {
        my $roles = $guild->roles;
        print "Moo - $del\n";

        for my $role (keys %{ $roles }) { 
            
            if ($del eq $roles->{$role}->{'name'}) {
                print "$del - $roles->{$role}->{'name'} - $roles->{$role}->{'id'}\n";
                $discord->delete_guild_role($msg->{'guild_id'}, $roles->{$role}->{'id'}, sub {print Data::Dumper::Dumper(\@_);});
            }
        }
    }
    
    if (my ($user, $name) = $args =~ /^ass(?:ign)?\s+(\S+)\s+(.*)/i) {

        my $roles = $guild->roles;
           $user  =~ s/\D//g;

        for my $role (keys %{ $roles }) {   

            if ($name eq $roles->{$role}->{'name'}) {

                $discord->add_guild_member_role($msg->{'guild_id'}, $user, $roles->{$role}->{'id'}, sub{print Data::Dumper::Dumper(\@_);});
            }
        }
    }

    $discord->delete_message($msg->{'channel_id'}, $msg->{'id'});
}

1;
