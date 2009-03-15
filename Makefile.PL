use inc::Module::Install;

name "github-growler";
all_from "github-growler.pl";
install_script "github-growler.pl";

requires 'App::Cache';
requires 'Mac::Growl';
requires 'LWP::Simple';
requires 'URI';
requires 'XML::Feed';
requires 'Web::Scraper';

WriteAll;

write_launchd_plist();

sub write_launchd_plist {
    my $bin;
    open my $fh, "<", "Makefile";
    while (<$fh>) {
        /INSTALL_BASE = (.*)$/ and do { $bin = "$1/bin"; last };
    }

    if ($bin) {
        open my $in, "<", "etc/github-growler.plist.tmpl";
        open my $out, ">", "etc/github-growler.plist";
        while (<$in>) {
            s/\[% BIN %\]/$bin/;
            print $out $_;
        }

        print <<EOF;

Once you run make install, copy etc/github-growler.plist to ~/Library/LaunchAgents/ and run

  launchctl load -w ~/Library/LaunchAgents/github-growler.plist

EOF
    }
}
