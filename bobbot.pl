#!/usr/bin/env perl
use v5.10;
use strict;
use warnings;
use utf8;

use FindBin 1.51 qw( $RealBin );
use lib "$RealBin/lib";
use Bot::Bobbot;
use Config::Tiny;
use Term::ANSIColor;
use File::Find;
use Cwd 'abs_path';

binmode STDOUT, ":utf8";

my $dir = abs_path('./lib/Command');
print "\n" . localtime . color('green') . " STARTING MOFO\n" . color('reset');
# Fallback to "config.ini" if the user does not pass in a config file.
my $config_file = $ARGV[0] // 'config.ini';
my $config = Config::Tiny->read($config_file, 'utf8');
say localtime(time) . " Loaded Config: $config_file";

# Initialize the bot
my $bot = Bot::Bobbot->new('config' => $config);

find(sub {
    if (-d $_ && $_ eq 'old') {
        $File::Find::prune = 1; # Tells File::Find to skip this directory
        return;
    }
    return unless /\.pm$/;
    require "$File::Find::dir/$_";

    my $module = $_;
       $module =~ s/\.pm$//;
    
    print "use Command::$module\n";
    eval "use Command::$module";

    my $class = "Command::$module";
    
    eval "use $class;";
    
    if ($@) {
        warn "Failed to load module $module: $@";
    } else {
        $bot->add_command( $class->new( 'bot' => $bot ) );
    }

}, $dir);

# Start the bot
$bot->start();
