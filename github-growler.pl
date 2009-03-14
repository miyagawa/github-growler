#!/usr/bin/perl
use strict;
use App::Cache;
use Mac::Growl;
use File::Copy;
use Getopt::Long;
use LWP::Simple;
use URI;
use XML::Feed;

my $AppName = "Github Growler";
my $event   = "New Activity";
Mac::Growl::RegisterNotifications($AppName, [ $event ], [ $event ]);

my $TempDir = "$ENV{HOME}/Library/Caches/com.github.Growler";
mkdir $TempDir, 0777 unless -e $TempDir;

my $AppIcon = "$TempDir/miyagawa.png";
copy "octocat.png", $AppIcon;

my(%UserCache, %Seen);

my %options = (interval => 300);
GetOptions(\%options, "interval=i");
my @args = @ARGV == 2 ? @ARGV : get_github_token();

while (1) {
    growl_feed(@args);
    sleep $options{interval};
}

sub get_github_token {
    chomp(my $user  = `git config github.user`);
    chomp(my $token = `git config github.token`);

    unless ($user && $token) {
        die "Can't find .gitconfig entries for github.user and github.token\n";
    }

    return ($user, $token);
}

sub growl_feed {
    my($user, $token) = @_;

    for my $uri ("http://github.com/$user.private.atom?token=$token",
                 "http://github.com/$user.private.actor.atom?token=$token") {
        my $feed = XML::Feed->parse(URI->new($uri));
        unless ($feed) {
            Mac::Growl::PostNotification($AppName, $event, $AppName, "Can't parse the feed $uri", 0, 0, $AppIcon);
            next;
        }

        for my $entry ($feed->entries) {
            next if $Seen{$entry->id};
            my $user = get_user($entry->author);
            Mac::Growl::PostNotification($AppName, $event, $user->{name}, $entry->title, 0, 0, "$user->{avatar}");
            $Seen{$entry->id}++;
        }
    }
}

sub get_user {
    my $name = shift;
    return $UserCache{$name} ||= do {
        use Web::Scraper;
        scraper {
            process "#profile_name", name => 'TEXT';
            process ".identity img", avatar => [ '@src', sub {
                my $path = "$TempDir/$name.jpg";
                LWP::Simple::mirror($_, $path)
                    unless -e $path && -s _;
                return $path;
            } ];
        }->scrape(URI->new("http://github.com/$name"));
    };
}


