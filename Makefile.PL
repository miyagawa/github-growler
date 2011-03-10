use inc::Module::Install;

name "github-growler";
all_from "github-growler.pl";
install_script "github-growler.pl";

bundle_platypus(
    extlib => 'extlib',
    script => 'github-growler.pl',
    app    => "Github Growler",
    author => "Tatsuhiko Miyagawa",
    icon   => "appIcon.icns",
);

requires 'Config::IniFiles';
requires 'Cocoa::Growl';
requires 'LWP::Simple';
requires 'URI';
requires 'Web::Scraper';
requires 'XML::LibXML';
requires 'Mozilla::CA';

WriteAll;
